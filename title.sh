#Ref: https://learn.microsoft.com/en-us/windows/terminal/tutorials/new-tab-same-directory
#PROMPT_COMMAND=${PROMPT_COMMAND:+"$PROMPT_COMMAND; "}'printf "\e]9;9;%s\e\\" "$(wslpath -w "$PWD")"'

#__wt_update_prompt_metadata() {
#    local display_dir="${PWD/#"$HOME"/\~}"

    # Tab title: user@hostname: ~/current/path
    # printf '\e]0;%s@%s: %s\a' \
    #    "$USER" "${HOSTNAME%%.*}" "$display_dir"

#    printf '\e]0;Ubuntu | %s\a' "$display_dir"

    # Tell Windows Terminal the current WSL working directory
#    printf '\e]9;9;%s\e\\' "$(wslpath -w "$PWD")"
#}
#
__wt_update_title() {
    local dir_name

    if [[ "$PWD" == "$HOME" ]]; then
        dir_name="~"
    elif [[ "$PWD" == "/" ]]; then
        dir_name="/"
    else
        dir_name="${PWD##*/}"
    fi
    printf '\e]0;Ubuntu — %s\a' "$dir_name"
}


#PROMPT_COMMAND="__wt_update_prompt_metadata${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
PROMPT_COMMAND="__wt_update_title${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
