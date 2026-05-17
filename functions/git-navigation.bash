#!/usr/bin/env bash

# Move to the root directory of the current Git repository.
goto-git-root() {
    local git_root

    git_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
        echo "Error: not inside a Git repository." >&2
        return 1
    }

    cd "$git_root" || return 1
}