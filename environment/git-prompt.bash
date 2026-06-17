# Git-aware Bash prompt (Catppuccin Macchiato style, ASCII glyphs)
# Source this file from ~/.bashrc
#
# Layout (two lines):
#
#   ╭─ user@host [~/path/to/dir] (branch symbols)
#   ╰─❯ $ <your command starts here>      (# instead of $ when root)
#
# A left-side connector (╭─ / ╰─❯) joins the two lines so they read as one unit
# and the arrow points at where you type, ending in the standard $ / # privilege
# marker. The directory is wrapped in []
# and the git branch in (). The info line uses Catppuccin Macchiato colors as
# foreground text (no background fills), tuned for a dark terminal. The command
# input lives on its own line so a long folder or branch name never pushes the
# cursor far to the right. Apart from the connector box-drawing characters
# (standard Unicode, supported by ordinary monospace fonts), only ASCII is used.
#
# A terminal with 24-bit (truecolor) support, e.g. Windows Terminal, is
# recommended for the palette to display correctly.
#
# Git symbols (rendered in the green git block):
#
#   *  branch is ahead of upstream
#   >  renamed files
#   +  new staged files
#   ?  untracked files
#   x  deleted files
#   !  modified files

# Only configure the prompt for interactive Bash shells.
[[ $- != *i* ]] && return

# Catppuccin Macchiato palette as 24-bit "R;G;B" triplets, used as foreground
# (text) colors on a dark terminal background.
__ctp_mauve='198;160;246'   # user@host
__ctp_peach='245;169;127'   # path
__ctp_green='166;218;149'   # git branch + status
__ctp_blue='138;173;244'    # connector and the prompt arrow

# Left-side connector that joins the info line to the input line. The bottom arm
# is followed by \$ (added in __ctp_build_prompt), which Bash renders as $ for a
# normal user and # for root.
__ctp_top='╭─'      # first line: top corner
__ctp_arm='╰─❯'     # second line: bottom corner + input arrow

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

# Display path: collapse $HOME to ~ and, when deeper than three components,
# shorten to .../<second-last>/<last> so the info line stays compact.
__ctp_path() {
    local p="${PWD/#$HOME/\~}"
    local IFS='/'
    local -a parts=($p)

    if (( ${#parts[@]} > 3 )); then
        printf '.../%s/%s' "${parts[-2]}" "${parts[-1]}"
    else
        printf '%s' "$p"
    fi
}

# Git block contents: "branch symbols", or nothing outside a repo.
# Long branch names are truncated to keep the block from wrapping.
__ctp_git_segment() {
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

    local branch
    branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null \
        || git rev-parse --short HEAD 2>/dev/null)" || return 0

    if (( ${#branch} > 30 )); then
        branch="${branch:0:27}..."
    fi

    printf '%s%s' "$branch" "$(parse_git_dirty)"
}

# Build PS1 fresh on every prompt. A function (rather than a static PS1) is
# required because whether the git block is present depends on the directory.
#
# The dynamic path and branch are passed by *reference* (\${__ctp_pathval}),
# not inlined as text. Bash expands those variables when it displays the prompt
# but does not re-scan the result for command substitution, so a directory
# named like $(...) or `...` is shown literally and never executed. This keeps
# the prompt safe without globally disabling promptvars (doing so would break
# other prompt integrations, e.g. systemd's $(__systemd_osc_context_ps0)).
__ctp_build_prompt() {
    local R="\[\e[0m\]"   # reset all attributes

    # Globals, evaluated by the prompt at display time via the references below.
    __ctp_pathval="$(__ctp_path)"
    __ctp_gitval="$(__ctp_git_segment)"

    local arm="\[\e[38;2;${__ctp_blue}m\]"   # connector color
    local ps=""

    # First line: top connector, then user@host (mauve text).
    ps+="${arm}${__ctp_top}${R} \[\e[38;2;${__ctp_mauve}m\]\u@\h${R}"

    # path (peach text), wrapped in [].
    ps+=" \[\e[38;2;${__ctp_peach}m\][\${__ctp_pathval}]${R}"

    # git (green text), wrapped in (), only inside a repository.
    if [[ -n "$__ctp_gitval" ]]; then
        ps+=" \[\e[38;2;${__ctp_green}m\](\${__ctp_gitval})${R}"
    fi

    # Second line: bottom connector + arrow, then the privilege-aware prompt
    # symbol (\$ -> $ for a normal user, # for root). The \\\$ keeps a literal
    # \$ in PS1 so Bash decodes it at display time.
    ps+="\n${arm}${__ctp_arm} \\\$${R} "

    # Do not export PS1. Exporting it can make sudo shells inherit a prompt
    # that references functions not loaded in the target shell.
    PS1="$ps"
}

# Rebuild the prompt before each display, preserving any existing
# PROMPT_COMMAND rather than clobbering it.
PROMPT_COMMAND="__ctp_build_prompt${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
