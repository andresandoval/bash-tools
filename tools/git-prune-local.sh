#!/usr/bin/env bash

set -euo pipefail

FORCE_DELETE=false

if [[ "${1:-}" == "--force" || "${1:-}" == "-f" ]]; then
  FORCE_DELETE=true
fi

printf "Git pruning helper\n\n"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf "Error: current directory is not inside a Git repository.\n\n"
  exit 1
fi

printf "(1/3) Fetching remotes and pruning stale remote-tracking branches...\n"
git fetch --all --prune

printf "(2/3) Finding local branches whose upstream branch no longer exists...\n"

current_branch="$(git branch --show-current)"

stale_branches=()

while IFS=$'\t' read -r branch upstream; do
  [[ -z "$upstream" ]] && continue
  [[ "$branch" == "$current_branch" ]] && continue

  if ! git show-ref --verify --quiet "refs/remotes/$upstream"; then
    stale_branches+=("$branch")
  fi
done < <(
  git for-each-ref \
    --format='%(refname:short)%09%(upstream:short)' \
    refs/heads
)

if (( ${#stale_branches[@]} == 0 )); then
  printf "\nNo stale local branches found.\n\n"
  exit 0
fi

printf "\nThe following local branches have deleted upstream branches:\n\n"

for branch in "${stale_branches[@]}"; do
  printf "  - %s\n" "$branch"
done

printf "\n"

read -r -p "Delete these branches? [y/N] " answer

case "$answer" in
  [yY]|[yY][eE][sS]|[sS]|[sS][iI])
    ;;
  *)
    printf "\nPruning canceled.\n\n"
    exit 0
    ;;
esac

printf "\n(3/3) Deleting stale local branches...\n\n"

delete_flag="-d"

if [[ "$FORCE_DELETE" == true ]]; then
  delete_flag="-D"
fi

failed_branches=()

for branch in "${stale_branches[@]}"; do
  if git branch "$delete_flag" "$branch"; then
    continue
  fi

  failed_branches+=("$branch")
done

if (( ${#failed_branches[@]} > 0 )); then
  printf "\nSome branches could not be deleted safely:\n\n"

  for branch in "${failed_branches[@]}"; do
    printf "  - %s\n" "$branch"
  done

  printf "\nThey may contain unmerged changes.\n"
  printf "Run this script with --force or -f to delete them with git branch -D.\n\n"
  exit 1
fi

printf "\nRepository pruned successfully.\n\n"