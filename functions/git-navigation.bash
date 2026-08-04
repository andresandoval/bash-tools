#!/usr/bin/env bash
#
# Git navigation helpers. Every command here changes the caller's directory, so they
# have to be shell functions — a script in tools/ would only cd inside its own process.
#
#   goto-git-root      cd to the root of the working tree you are in (a linked
#                      worktree's own root, when you are inside one)
#   goto-git-main      cd to the main repository root, from anywhere in the repo
#   goto-git-worktree  cd to any worktree of the current repo, by name or from a menu
#
# All of them work in both worktree layouts: a normal clone with linked worktrees
# added alongside it, and a bare repository whose worktrees are siblings of it.

# ---------------------------------------------------------------------------
# Internals — prefixed `_git_nav_`, not meant to be called directly.
# ---------------------------------------------------------------------------

# Resolve a (possibly relative) directory path to an absolute one. Git prints some
# paths relative to the cwd, and `realpath` is not available everywhere.
_git_nav_abs_dir() {
    [ -n "${1:-}" ] || return 1
    (cd "$1" 2>/dev/null && pwd -P)
}

# Succeed when the cwd is inside a *linked* worktree rather than the main one.
# Linked worktrees keep their own git dir under the main repo's `worktrees/`, so
# --git-dir and --git-common-dir differ there and match everywhere else.
_git_nav_in_linked_worktree() {
    local git_dir common_dir

    git_dir="$(_git_nav_abs_dir "$(git rev-parse --git-dir 2>/dev/null)")" || return 1
    common_dir="$(_git_nav_abs_dir "$(git rev-parse --git-common-dir 2>/dev/null)")" || return 1

    [ -n "$git_dir" ] && [ "$git_dir" != "$common_dir" ]
}

# Print one TAB-separated record per worktree of the current repository:
#
#     <path><TAB><label><TAB><marker>
#
# `label` is the checked-out branch, or "(bare)" / "(detached)"; `marker` is "*" for
# the worktree the caller is currently inside and empty otherwise. `git worktree list`
# always reports the main worktree first — bare or not — so the first record is it.
# Prints nothing (and fails) outside a repository.
_git_nav_worktrees() {
    local current path label marker line

    # Empty inside a bare repo, which only means no record gets the current marker.
    current="$(git rev-parse --show-toplevel 2>/dev/null)" || current=""

    path=""
    label=""

    while IFS= read -r line; do
        case "$line" in
            "worktree "*)
                path="${line#worktree }"
                label=""
                ;;
            "branch "*)
                label="${line#branch }"
                label="${label#refs/heads/}"
                ;;
            "bare")
                label="(bare)"
                ;;
            "detached")
                label="(detached)"
                ;;
            "")
                # Blank line ends a record — emit it.
                if [ -n "$path" ]; then
                    marker=""
                    [ "$path" = "$current" ] && marker="*"
                    printf '%s\t%s\t%s\n' "$path" "$label" "$marker"
                fi
                path=""
                ;;
        esac
    done < <(
        git worktree list --porcelain 2>/dev/null
        # Sentinel, in case the last record is not blank-line terminated.
        printf '\n'
    )
}

# Render a numbered menu of the worktree records passed as arguments and echo the
# chosen path on stdout. The menu and prompt go to stderr so the caller can capture
# the result. Returns 1 on invalid input and 2 when the user cancels.
_git_nav_select() {
    local -a records=("$@")
    local index=1 record path label marker current_tag reply

    for record in "${records[@]}"; do
        IFS=$'\t' read -r path label marker <<<"$record"
        current_tag=""
        [ -n "$marker" ] && current_tag=" (current)"
        printf '  %2d) %-28s %s%s\n' "$index" "${path##*/}" "$label" "$current_tag" >&2
        index=$((index + 1))
    done

    printf 'Select worktree [1-%d] (Enter to cancel): ' "${#records[@]}" >&2
    read -r reply || return 2
    [ -z "$reply" ] && return 2

    case "$reply" in
        *[!0-9]*)
            printf 'Error: not a number: %s\n' "$reply" >&2
            return 1
            ;;
    esac
    if [ "$reply" -lt 1 ] || [ "$reply" -gt "${#records[@]}" ]; then
        printf 'Error: out of range: %s\n' "$reply" >&2
        return 1
    fi

    IFS=$'\t' read -r path label marker <<<"${records[$((reply - 1))]}"
    printf '%s\n' "$path"
}

# ---------------------------------------------------------------------------
# Commands.
# ---------------------------------------------------------------------------

# Move to the root directory of the current Git working tree. Inside a linked
# worktree that is the worktree's own root, not the main repository's.
goto-git-root() {
    local git_root branch

    git_root="$(git rev-parse --show-toplevel 2>/dev/null)" || git_root=""

    if [ -z "$git_root" ]; then
        # No working tree to enter: either a bare repository, or a .git directory.
        if git rev-parse --git-dir >/dev/null 2>&1; then
            echo "Error: no working tree here." >&2
            echo "Use goto-git-main for the main repository, or goto-git-worktree to pick one." >&2
        else
            echo "Error: not inside a Git repository." >&2
        fi
        return 1
    fi

    cd "$git_root" || return 1

    # Several worktrees of one repo look alike once you are in them, so name the one
    # you landed in. Ordinary single-checkout repos stay silent.
    if _git_nav_in_linked_worktree; then
        branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" || branch=""
        [ -z "$branch" ] && branch="(detached)"
        printf 'worktree: %s  branch: %s\n' "${git_root##*/}" "$branch"
    fi
}

# Move to the main repository root, even from inside a linked worktree.
goto-git-main() {
    local record path label marker

    record="$(_git_nav_worktrees | head -n 1)"
    if [ -z "$record" ]; then
        echo "Error: not inside a Git repository." >&2
        return 1
    fi

    IFS=$'\t' read -r path label marker <<<"$record"

    cd "$path" || return 1

    # A bare main repository has no files to look at, but it is still the repository
    # itself — where `git fetch` and `git worktree add` belong. Say so rather than
    # leaving you wondering where the checkout went.
    if [ "$label" = "(bare)" ]; then
        echo "main repository (bare) — use goto-git-worktree to reach a checkout"
    fi
}

# Move to a worktree of the current repository. With NAME, matches it against the
# worktree directory names and branch names (exact first, then substring); without
# one, offers a numbered menu.
goto-git-worktree() {
    local name="${1:-}" record path label marker target status
    local -a records=() matches=()

    while IFS= read -r record; do
        records+=("$record")
    done < <(_git_nav_worktrees)

    if [ "${#records[@]}" -eq 0 ]; then
        echo "Error: not inside a Git repository." >&2
        return 1
    fi

    if [ -n "$name" ]; then
        # Exact match on the directory name or the branch...
        for record in "${records[@]}"; do
            IFS=$'\t' read -r path label marker <<<"$record"
            if [ "${path##*/}" = "$name" ] || [ "$label" = "$name" ]; then
                matches+=("$record")
            fi
        done
        # ...and only if nothing matched exactly, a substring of either.
        if [ "${#matches[@]}" -eq 0 ]; then
            for record in "${records[@]}"; do
                IFS=$'\t' read -r path label marker <<<"$record"
                case "${path##*/}" in
                    *"$name"*)
                        matches+=("$record")
                        continue
                        ;;
                esac
                case "$label" in
                    *"$name"*) matches+=("$record") ;;
                esac
            done
        fi
        if [ "${#matches[@]}" -eq 0 ]; then
            printf "Error: no worktree matching '%s'.\n" "$name" >&2
            return 1
        fi
    else
        matches=("${records[@]}")
    fi

    if [ "${#matches[@]}" -eq 1 ]; then
        IFS=$'\t' read -r target label marker <<<"${matches[0]}"
        # Nothing was there to choose from: mention it so the silent cd is not read
        # as a menu that failed to show up.
        if [ -z "$name" ]; then
            printf 'only one worktree: %s\n' "${target##*/}"
        fi
    else
        # An ambiguous NAME narrows the menu to the candidates instead of failing.
        if [ -n "$name" ]; then
            printf "Worktrees matching '%s':\n" "$name" >&2
        else
            echo "Worktrees:" >&2
        fi
        target="$(_git_nav_select "${matches[@]}")"
        status=$?
        case "$status" in
            0) ;;
            2) return 0 ;; # cancelled
            *) return 1 ;;
        esac
    fi

    cd "$target" || return 1
}

# ---------------------------------------------------------------------------
# Tab-completion for `goto-git-worktree`: worktree directory names and branch
# names of the current repository. Offers nothing outside a repository.
# ---------------------------------------------------------------------------

_goto_git_worktree_complete() {
    local cur record path label marker candidates=""

    cur="${COMP_WORDS[COMP_CWORD]}"
    COMPREPLY=()

    while IFS= read -r record; do
        IFS=$'\t' read -r path label marker <<<"$record"
        candidates="$candidates ${path##*/}"
        # Skip the "(bare)" / "(detached)" pseudo-labels — they are not names.
        case "$label" in
            "" | "("*) ;;
            *) candidates="$candidates $label" ;;
        esac
    done < <(_git_nav_worktrees)

    COMPREPLY=($(compgen -W "$candidates" -- "$cur"))
}

complete -F _goto_git_worktree_complete goto-git-worktree
