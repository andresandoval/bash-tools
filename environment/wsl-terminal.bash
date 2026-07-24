# Windows Terminal integration for Bash running under WSL
# Source this file from ~/.bashrc
#
# Two behaviors, both refreshed on every prompt via PROMPT_COMMAND:
#
#   1. Working-directory inheritance: emits the OSC 9;9 sequence carrying the
#      Windows path of $PWD, so duplicating a tab or splitting a pane in
#      Windows Terminal opens in the current directory.
#      Ref: https://learn.microsoft.com/en-us/windows/terminal/tutorials/new-tab-same-directory
#
#   2. Dynamic tab title: sets the title to "<distro> — <dirname>" (for
#      example "Ubuntu — bash-tools") via the standard OSC 0 sequence. The
#      distro name comes from $WSL_DISTRO_NAME, so the same file works on any
#      WSL distribution.
#
# Outside WSL (plain Linux, macOS, Git Bash) sourcing this file is a silent
# no-op thanks to the guards below.

# Only configure the terminal for interactive Bash shells.
[[ $- != *i* ]] && return

# Only run under WSL: wslpath and the OSC 9;9 sequence mean nothing elsewhere.
[[ -z ${WSL_DISTRO_NAME:-} ]] && return

__wt_update_title() {
    # Short display name for the tab title: ~ at $HOME, / at the filesystem
    # root, otherwise the basename of the current directory.
    local dir_name
    if [[ "$PWD" == "$HOME" ]]; then
        dir_name="~"
    elif [[ "$PWD" == "/" ]]; then
        dir_name="/"
    else
        dir_name="${PWD##*/}"
    fi

    # Tab title: "<distro> — <dirname>".
    printf '\e]0;%s — %s\a' "$WSL_DISTRO_NAME" "$dir_name"

    # Tell Windows Terminal the current working directory (as a Windows path)
    # so tabs/panes duplicated from this one start here.
    printf '\e]9;9;%s\e\\' "$(wslpath -w "$PWD")"
}

# Run before every prompt. Prepend to any existing PROMPT_COMMAND rather than
# clobbering it, so this coexists with other hooks (e.g. git-prompt.bash).
PROMPT_COMMAND="__wt_update_title${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
