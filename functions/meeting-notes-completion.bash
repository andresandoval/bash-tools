#!/usr/bin/env bash
#
# Tab-completion for the `meeting-notes` command. The first word is the command
# (add, delete, rename, retitle, rebuild); what completes after it depends on
# which command it is — a directory path for `add`, a note file for `delete`,
# `rename` and `retitle`. Paths are completed under the current directory (the
# active notes repo), so you can drill through your structure with Tab. Works in
# any directory.

# Note (.md) files under the cwd, drilling through directories; skips the notes
# repo's own .git/.web.
_meeting_notes_notes() {
	local f matches=()
	while IFS= read -r f; do
		case "$f" in .git | .git/* | .web | .web/*) continue ;; esac
		if [ -d "$f" ]; then
			matches+=("$f/")
		else
			case "$f" in *.md) matches+=("$f") ;; esac
		fi
	done < <(compgen -f -- "$1")
	COMPREPLY=("${matches[@]}")
	if [ "${#COMPREPLY[@]}" -gt 0 ]; then
		compopt -o nospace 2>/dev/null || true
	fi
}

# Directory paths under the cwd (multi-level), skipping .git/.web. The trailing
# slash + nospace lets you keep drilling down.
_meeting_notes_dirs() {
	local d matches=()
	while IFS= read -r d; do
		case "$d" in .git | .git/* | .web | .web/*) continue ;; esac
		matches+=("$d/")
	done < <(compgen -d -- "$1")
	COMPREPLY=("${matches[@]}")
	if [ "${#COMPREPLY[@]}" -gt 0 ]; then
		compopt -o nospace 2>/dev/null || true
	fi
}

_meeting_notes_complete() {
	local cur prev cmd
	cur="${COMP_WORDS[COMP_CWORD]}"
	prev="${COMP_WORDS[COMP_CWORD - 1]}"
	COMPREPLY=()

	# Word 1 is always the command.
	if [ "$COMP_CWORD" -le 1 ]; then
		COMPREPLY=($(compgen -W "add delete rename retitle rebuild --version --help" -- "$cur"))
		return 0
	fi

	cmd="${COMP_WORDS[1]}"

	# Option values, handled before the positional count below — they are not
	# positional arguments.
	case "$prev" in
	--from)
		COMPREPLY=($(compgen -f -- "$cur"))
		return 0
		;;
	--title)
		# Free text — nothing to complete.
		return 0
		;;
	esac

	# Which positional slot is being typed? Options (and their values) do not
	# count, so `add --no-push <TAB>` still completes the PATH.
	local i=2 slot=1 w
	while [ "$i" -lt "$COMP_CWORD" ]; do
		w="${COMP_WORDS[i]}"
		case "$w" in
		--from | --title)
			i=$((i + 2))
			continue
			;;
		-*)
			i=$((i + 1))
			continue
			;;
		esac
		slot=$((slot + 1))
		i=$((i + 1))
	done

	# Options, narrowed to the ones this command accepts.
	if [[ "$cur" == -* ]]; then
		local flags="--no-push --version --help"
		case "$cmd" in
		add) flags="--title --from --from-clipboard --no-preview $flags" ;;
		delete) flags="--no-preview $flags" ;;
		esac
		COMPREPLY=($(compgen -W "$flags" -- "$cur"))
		return 0
	fi

	# Positional arguments. Anything not listed (retitle's free-text TEXT,
	# rebuild, a slot past the command's last argument) completes nothing.
	case "$cmd:$slot" in
	add:1 | rename:2) _meeting_notes_dirs "$cur" ;;
	delete:1 | rename:1 | retitle:1) _meeting_notes_notes "$cur" ;;
	esac
	return 0
}

complete -o default -F _meeting_notes_complete meeting-notes
