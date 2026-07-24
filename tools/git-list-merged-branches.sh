#!/usr/bin/env bash
#
# list-merged-branches — read-only report of git branches that are safe to delete.
#
# A branch is "safe to delete" when all of its work is already contained in the
# default branch:
#
#   [merged]  ancestry — the branch tip is an ancestor of origin/<base>
#             (regular merge or fast-forward), so nothing was committed after
#             the merge.
#   [squash]  patch-equivalence — every commit unique to the branch has a
#             patch-equivalent commit in the default branch (squash merge,
#             rebase-merge, cherry-pick), detected with `git cherry`.
#
# Branches that were squash-merged but received new commits afterwards are
# reported separately as NOT safe to delete. Branches with no overlap at all
# (never merged) are not listed.
#
# Each listed branch is annotated with its author (the author of the branch
# tip commit), the merge target, the commit in the base branch that merged
# it (the merge commit, the squash commit, or the branch tip for
# fast-forwards), and that commit's date.
#
# The tool never deletes, checks out, pulls, or writes anything. Its only
# side effect is `git fetch --prune origin` (skippable with --no-fetch).

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME

# Branch names never listed, in addition to the resolved base branch and the
# currently checked-out branch.
readonly PROTECTED_BRANCHES=(HEAD master main develop dev staging production)

BASE_BRANCH=""   # -b/--base override (bare name, no "origin/" prefix)
DO_FETCH=true    # --no-fetch sets this to false

BASE_NAME=""     # resolved default branch, e.g. "main"
BASE_REF=""      # ref compared against, e.g. "origin/main"
CURRENT_BRANCH=""

# Filled by scan_scope(), read by print_scope().
SAFE_MERGED=()
SAFE_SQUASH=()
NEW_COMMITS=()

SAFE_TOTAL=0

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

show_help() {
  cat <<EOF
Usage:
  $SCRIPT_NAME [options]

Description:
  List local and remote (origin/*) branches whose work is already fully
  contained in the default branch, so they are safe to delete:

    [merged]  the branch tip is an ancestor of origin/<base>
              (regular merge or fast-forward)
    [squash]  every commit unique to the branch is patch-equivalent to a
              commit in the default branch (squash merge, rebase, cherry-pick)

  Branches that were squash-merged but got NEW commits afterwards are shown
  separately as NOT safe. Never-merged branches are not listed.

  Each listed branch shows its author (last commit author), the merge
  target, the base-branch commit that merged it (merge commit, squash
  commit, or branch tip for fast-forwards), and that commit's date.

  The report is read-only: nothing is deleted, checked out, or pulled. The
  only side effect is "git fetch --prune origin" (see --no-fetch).

Options:
  -b, --base <branch>
      Base branch to compare against (bare name, e.g. "main").
      Auto-detected from origin/HEAD, falling back to origin/main, then
      origin/master.

  --no-fetch
      Skip "git fetch --prune origin". Faster, but remote-tracking
      branches may be stale.

  -h, --help
      Show this help message.

Caveats:
  - A branch merged with a merge commit and then extended with new commits
    is indistinguishable from an unmerged branch and is not listed.
  - Patch-equivalence is content-based: an identical diff that reached the
    default branch some other way counts as merged.

Examples:
  $SCRIPT_NAME
  $SCRIPT_NAME -b develop
  $SCRIPT_NAME --no-fetch
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -b|--base)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        BASE_BRANCH="${2#origin/}"
        [[ -n "$BASE_BRANCH" ]] || die "Invalid value for $1: \"$2\""
        shift 2
        ;;
      --no-fetch)
        DO_FETCH=false
        shift
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        die "Unknown option: $1"
        ;;
      *)
        die "$SCRIPT_NAME takes no positional arguments (got: $1)"
        ;;
    esac
  done

  [[ $# -eq 0 ]] || die "$SCRIPT_NAME takes no positional arguments (got: $1)"
}

# --------------------------------------------------------------------------
# Environment checks and base-branch resolution
# --------------------------------------------------------------------------

require_git_repo() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "current directory is not inside a Git repository."

  git remote get-url origin >/dev/null 2>&1 \
    || die "no \"origin\" remote found."
}

ref_exists() {
  git show-ref --verify --quiet "$1"
}

# Resolve the default branch: explicit -b/--base first, then the origin/HEAD
# symref, then origin/main, then origin/master.
resolve_base_branch() {
  if [[ -n "$BASE_BRANCH" ]]; then
    ref_exists "refs/remotes/origin/$BASE_BRANCH" \
      || die "origin/$BASE_BRANCH not found."
    BASE_NAME="$BASE_BRANCH"
  else
    local symref
    if symref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"; then
      BASE_NAME="${symref#origin/}"
    elif ref_exists refs/remotes/origin/main; then
      BASE_NAME="main"
    elif ref_exists refs/remotes/origin/master; then
      BASE_NAME="master"
    else
      die "could not detect the default branch; pass -b/--base <branch>."
    fi
  fi

  BASE_REF="origin/$BASE_NAME"
}

is_protected() {
  local name="$1" protected

  [[ "$name" == "$BASE_NAME" ]] && return 0

  for protected in "${PROTECTED_BRANCHES[@]}"; do
    [[ "$name" == "$protected" ]] && return 0
  done

  return 1
}

# --------------------------------------------------------------------------
# Classification
# --------------------------------------------------------------------------

# Locate the commit in the base branch that merged the given ref (ancestry
# case): the oldest merge commit lying between the branch tip and the base
# tip, or the tip itself for fast-forward merges. Echoes "<short-sha> <date>".
ancestry_merge_commit() {
  local ref="$1" merge_commit

  merge_commit="$(git rev-list --ancestry-path --merges "$ref..$BASE_REF" | tail -n 1)"
  [[ -n "$merge_commit" ]] || merge_commit="$ref"

  git log -1 --format='%h %cs' "$merge_commit"
}

# Locate the newest commit in the base branch whose patch is equivalent to
# one of the given ref's unique commits (the squash/rebase commit). Echoes
# "<short-sha> <date>", or nothing if no equivalent commit is found.
squash_merge_commit() {
  local ref="$1" merge_base branch_patch_ids patch_id sha

  merge_base="$(git merge-base "$ref" "$BASE_REF" 2>/dev/null || true)"
  [[ -n "$merge_base" ]] || return 0

  branch_patch_ids="$(git log -p --no-color "$merge_base..$ref" \
    | git patch-id --stable | awk '{print $1}')"
  [[ -n "$branch_patch_ids" ]] || return 0

  while read -r patch_id sha; do
    if grep -qxF "$patch_id" <<<"$branch_patch_ids"; then
      git log -1 --format='%h %cs' "$sha"
      return 0
    fi
  done < <(git log -p --no-color "$merge_base..$BASE_REF" | git patch-id --stable)

  return 0
}

# Classify one ref against $BASE_REF. Echoes one of:
#   merged       tip is an ancestor of the base branch
#   squash       all unique commits are patch-equivalent to base commits
#   new-commits  partially patch-equivalent: squash-merged, then extended
#   unmerged     no overlap with the base branch
classify_branch() {
  local ref="$1"

  # Cheap ancestry check first; it also covers branches with no commits of
  # their own.
  if git merge-base --is-ancestor "$ref" "$BASE_REF" 2>/dev/null; then
    printf 'merged'
    return
  fi

  # `git cherry` lists the commits in $ref that are not in $BASE_REF by
  # ancestry: "-" = a patch-equivalent commit exists in the base branch,
  # "+" = genuinely unique work.
  local cherry
  cherry="$(git cherry "$BASE_REF" "$ref")"

  if [[ -z "$cherry" ]]; then
    printf 'merged'   # defensive: no unique commits at all
  elif ! grep -q '^+' <<<"$cherry"; then
    printf 'squash'
  elif grep -q '^-' <<<"$cherry"; then
    printf 'new-commits'
  else
    printf 'unmerged'
  fi
}

# List candidate branch names for a scope ("local" or "remote"), one per
# line, as bare names without any refs/ or origin/ prefix.
list_branch_names() {
  local scope="$1"

  if [[ "$scope" == "local" ]]; then
    git for-each-ref --format='%(refname)' refs/heads \
      | sed 's|^refs/heads/||'
  else
    git for-each-ref --format='%(refname)' refs/remotes/origin \
      | sed 's|^refs/remotes/origin/||'
  fi
}

# Classify every candidate branch in a scope into the SAFE_MERGED /
# SAFE_SQUASH / NEW_COMMITS arrays.
scan_scope() {
  local scope="$1"
  local name ref state author

  SAFE_MERGED=()
  SAFE_SQUASH=()
  NEW_COMMITS=()

  while IFS= read -r name; do
    is_protected "$name" && continue

    if [[ "$scope" == "local" ]]; then
      [[ "$name" == "$CURRENT_BRANCH" ]] && continue
      ref="$name"
    else
      ref="origin/$name"
    fi

    state="$(classify_branch "$ref")"
    author="$(git log -1 --format='%an' "$ref")"

    # Entries are "<name><TAB><author><TAB><short-sha> <date>"; the merge
    # info in the last field may be empty.
    case "$state" in
      merged)      SAFE_MERGED+=("$ref"$'\t'"$author"$'\t'"$(ancestry_merge_commit "$ref")") ;;
      squash)      SAFE_SQUASH+=("$ref"$'\t'"$author"$'\t'"$(squash_merge_commit "$ref")") ;;
      new-commits) NEW_COMMITS+=("$ref"$'\t'"$author"$'\t'"$(squash_merge_commit "$ref")") ;;
    esac
  done < <(list_branch_names "$scope")
}

# --------------------------------------------------------------------------
# Report
# --------------------------------------------------------------------------

# Print one branch entry ("<name><TAB><author><TAB><short-sha> <date>") with
# its tag, the branch author (last commit author), and, when available, the
# merge target / commit / date.
print_entry() {
  local tag="$1" entry="$2"
  local name author info sha date

  name="${entry%%$'\t'*}"
  entry="${entry#*$'\t'}"
  author="${entry%%$'\t'*}"
  info="${entry#*$'\t'}"

  if [[ -n "$info" ]]; then
    sha="${info%% *}"
    date="${info#* }"
    printf '  %s  %s  (by %s, merged into %s at %s on %s)\n' \
      "$tag" "$name" "$author" "$BASE_NAME" "$sha" "$date"
  else
    printf '  %s  %s  (by %s)\n' "$tag" "$name" "$author"
  fi
}

print_scope() {
  local header="$1"
  local entry

  printf '== %s ==\n\n' "$header"
  printf 'Safe to delete:\n'

  if (( ${#SAFE_MERGED[@]} + ${#SAFE_SQUASH[@]} == 0 )); then
    printf '  (none)\n'
  else
    for entry in ${SAFE_MERGED[@]+"${SAFE_MERGED[@]}"}; do
      print_entry '[merged]' "$entry"
    done
    for entry in ${SAFE_SQUASH[@]+"${SAFE_SQUASH[@]}"}; do
      print_entry '[squash]' "$entry"
    done
  fi

  printf '\n'

  if (( ${#NEW_COMMITS[@]} > 0 )); then
    printf 'Merged, but has NEW commits since (not safe):\n'
    for entry in "${NEW_COMMITS[@]}"; do
      print_entry '-' "$entry"
    done
    printf '\n'
  fi
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

main() {
  parse_args "$@"
  require_git_repo

  if [[ "$DO_FETCH" == true ]]; then
    printf 'Fetching origin (git fetch --prune origin)...\n'
    git fetch --prune origin
  else
    printf 'Skipping fetch (--no-fetch); remote-tracking branches may be stale.\n'
  fi

  resolve_base_branch
  CURRENT_BRANCH="$(git branch --show-current)"

  printf '\nDefault branch: %s (%s)\n\n' "$BASE_NAME" "$BASE_REF"

  scan_scope local
  print_scope "Local branches"
  SAFE_TOTAL=$(( SAFE_TOTAL + ${#SAFE_MERGED[@]} + ${#SAFE_SQUASH[@]} ))

  scan_scope remote
  print_scope "Remote branches (origin/*)"
  SAFE_TOTAL=$(( SAFE_TOTAL + ${#SAFE_MERGED[@]} + ${#SAFE_SQUASH[@]} ))

  if (( SAFE_TOTAL == 0 )); then
    printf 'No branches are safe to delete.\n'
    return
  fi

  printf 'To delete:\n'
  printf '  git branch -d <name>              # local ("-D" if git refuses a squash-merged branch)\n'
  printf '  git push origin --delete <name>   # remote, without the "origin/" prefix\n'
}

main "$@"
