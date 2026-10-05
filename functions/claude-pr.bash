#!/usr/bin/env bash
#
# claude-pr — start a Claude Code session for one pull request, in its own git
# worktree.
#
#   claude-pr 345                 claude --worktree "#345" --name "PR #345"
#   claude-pr 345 --model opus    the same, with extra arguments for claude
#
# It is a shell function rather than an alias because the PR number goes in the
# middle of the command, twice. An alias can only add arguments at the end.

# ---------------------------------------------------------------------------
# Internals — prefixed `_claude_pr_`, not meant to be called directly.
# ---------------------------------------------------------------------------

# Print usage. Callers send it to stdout on --help, to stderr on a usage error.
_claude_pr_help() {
    cat <<'EOF'
Usage:
  claude-pr NUMBER [CLAUDE_ARG...]
  claude-pr [-h|--help]

Description:
  Start a Claude Code session for one pull request, in its own git worktree.
  Shorthand for:

    claude --worktree "#NUMBER" --name "PR #NUMBER" [CLAUDE_ARG...]

  NUMBER is the PR number, with or without a leading "#" (345 or '#345').
  Quote the "#" form: an unquoted "#" starts a comment in the shell.

  CLAUDE_ARG... goes to claude unchanged, after the defaults.

Examples:
  claude-pr 345                 session "PR #345" in worktree "#345"
  claude-pr 345 --model opus    the same, with a different model
EOF
}

# ---------------------------------------------------------------------------
# claude-pr — the command.
# ---------------------------------------------------------------------------

claude-pr() {
    local number

    case "${1-}" in
        -h | --help)
            _claude_pr_help
            return 0
            ;;
    esac

    # One leading "#" is optional, so both 345 and '#345' work.
    number="${1-}"
    number="${number#\#}"

    if [ -z "$number" ]; then
        echo "claude-pr: no PR number given" >&2
        _claude_pr_help >&2
        return 1
    fi

    # The number has to come first. Without this, `claude-pr --model opus 345`
    # would start a session for PR "--model".
    case "$number" in
        -*)
            printf 'claude-pr: the first argument is the PR number, not an option (got %s)\n' "$1" >&2
            printf 'Usage: claude-pr NUMBER [CLAUDE_ARG...]\n' >&2
            return 1
            ;;
        *[!0-9]*)
            printf 'claude-pr: not a PR number: %s\n' "$1" >&2
            printf 'Usage: claude-pr NUMBER [CLAUDE_ARG...]\n' >&2
            return 1
            ;;
    esac

    shift

    # `command` skips any `claude` alias or function, so this always runs the
    # real binary and can never call itself.
    local -a cmd
    cmd=(claude --worktree "#$number" --name "PR #$number" "$@")

    # Echo the command, so the worktree and session names are never a surprise.
    printf '+'
    printf ' %q' "${cmd[@]}"
    printf '\n'

    command "${cmd[@]}"
}
