# Git-aware Bash prompt
# Source this file from ~/.bashrc

# Only configure PS1 for interactive Bash shells.
[[ $- != *i* ]] && return

parse_git_branch() {
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

    local branch
    branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null \
        || git rev-parse --short HEAD 2>/dev/null)" || return 0

    local status
    status="$(parse_git_dirty)"

    printf '(%s%s)' "$branch" "$status"
}

parse_git_dirty() {
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

    local status
    status="$(git status --porcelain=v1 --branch 2>/dev/null)" || return 0

    local bits=""

    # Ahead of upstream
    # Symbol: *
    # Meaning: local branch is ahead of the remote/upstream branch.
    if grep -q '^## .*ahead' <<< "$status"; then
        bits="*${bits}"
    fi

    # Renamed files
    # Symbol: >
    # Meaning: one or more files were renamed.
    if grep -q '^R' <<< "$status"; then
        bits=">${bits}"
    fi

    # New staged files
    # Symbol: +
    # Meaning: one or more new files are staged.
    if grep -q '^A' <<< "$status"; then
        bits="+${bits}"
    fi

    # Untracked files
    # Symbol: ?
    # Meaning: one or more untracked files exist.
    if grep -q '^??' <<< "$status"; then
        bits="?${bits}"
    fi

    # Deleted files
    # Symbol: x
    # Meaning: one or more files were deleted.
    if grep -q '^[ MARC][D]' <<< "$status" || grep -q '^D' <<< "$status"; then
        bits="x${bits}"
    fi

    # Modified files
    # Symbol: !
    # Meaning: one or more files were modified.
    if grep -q '^[ MARC]M' <<< "$status" || grep -q '^M' <<< "$status"; then
        bits="!${bits}"
    fi

    [[ -n "$bits" ]] && printf ' %s' "$bits"
}

# Prompt format:
#
#   [user@host current-folder](branch symbols)$
#
# Git symbols:
#
#   *  branch is ahead of upstream
#   >  renamed files
#   +  new staged files
#   ?  untracked files
#   x  deleted files
#   !  modified files
#
# Example:
#
#   [andres@pc my-project](main !?)$
#
# Do not export PS1. Exporting it can make sudo shells inherit a prompt
# that references functions not loaded in the target shell.
PS1='[\u@\h \[\e[35m\]\W\[\e[0m\]]\[\e[32m\]$(parse_git_branch)\[\e[0m\]\$ '