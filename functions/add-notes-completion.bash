#!/usr/bin/env bash
#
# Tab-completion for the `add-notes` command. Completion is cwd-aware: projects
# and meetings are completed from the current directory (the active notes repo),
# so it works in any directory you take notes in.

_add_notes_slug() {
	echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

_add_notes_dirs() {
	# Subdirectories of $1, one per line. The */ glob already skips hidden dirs
	# like .git and .web.
	(cd "$1" 2>/dev/null || return 0
	 for d in */; do
		[ -d "$d" ] || continue
		echo "${d%/}"
	 done)
}

_add_notes_complete() {
	local cur="${COMP_WORDS[COMP_CWORD]}"
	COMPREPLY=()

	if [[ "$cur" == -* ]]; then
		COMPREPLY=($(compgen -W "--no-push --version --help" -- "$cur"))
		return 0
	fi

	# Count positional args before the current word; capture the project (1st).
	local i w pos=0 proj=""
	for ((i = 1; i < COMP_CWORD; i++)); do
		w="${COMP_WORDS[i]}"
		[[ "$w" == -* ]] && continue
		[ "$pos" -eq 0 ] && proj="$w"
		pos=$((pos + 1))
	done

	case "$pos" in
	0) # PROJECT — directories in the current notes repo
		COMPREPLY=($(compgen -W "$(_add_notes_dirs "$PWD")" -- "$cur"))
		;;
	1) # MEETING — subdirectories of the chosen project
		local pslug
		pslug="$(_add_notes_slug "$proj")"
		COMPREPLY=($(compgen -W "$(_add_notes_dirs "$PWD/$pslug")" -- "$cur"))
		;;
	*) # PATH — fall back to filename completion (via -o default)
		COMPREPLY=()
		;;
	esac
	return 0
}

complete -o default -F _add_notes_complete add-notes
