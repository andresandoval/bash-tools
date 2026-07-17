#!/usr/bin/env bash
#
# Tab-completion for the `add-notes` command. The PATH argument is completed as a
# multi-level directory path under the current directory (the active notes repo),
# so you can drill through your structure with Tab. Works in any directory.

_add_notes_complete() {
	local cur prev
	cur="${COMP_WORDS[COMP_CWORD]}"
	prev="${COMP_WORDS[COMP_CWORD - 1]}"
	COMPREPLY=()

	# After --from, complete a source file path (default file completion).
	if [ "$prev" = "--from" ]; then
		COMPREPLY=($(compgen -f -- "$cur"))
		return 0
	fi

	# After --title, the value is free text — nothing to complete.
	if [ "$prev" = "--title" ]; then
		return 0
	fi

	# After --delete, complete note (.md) files under the cwd, drilling through
	# directories like the PATH completion (skipping the repo's own .git/.web).
	if [ "$prev" = "--delete" ]; then
		local f matches=()
		while IFS= read -r f; do
			case "$f" in .git | .git/* | .web | .web/*) continue ;; esac
			if [ -d "$f" ]; then
				matches+=("$f/")
			else
				case "$f" in *.md) matches+=("$f") ;; esac
			fi
		done < <(compgen -f -- "$cur")
		COMPREPLY=("${matches[@]}")
		if [ "${#COMPREPLY[@]}" -gt 0 ]; then
			compopt -o nospace 2>/dev/null || true
		fi
		return 0
	fi

	# Flags.
	if [[ "$cur" == -* ]]; then
		COMPREPLY=($(compgen -W "--title --from --from-clipboard --delete --rebuild --no-push --version --help" -- "$cur"))
		return 0
	fi

	# Has a positional PATH already been given? If so, nothing more to complete.
	local i w have_path=0
	for ((i = 1; i < COMP_CWORD; i++)); do
		w="${COMP_WORDS[i]}"
		case "$w" in
		--from | --title | --delete) ((i++)); continue ;; # skip their values
		-*) continue ;;
		*) have_path=1 ;;
		esac
	done
	[ "$have_path" -eq 1 ] && return 0

	# Complete the PATH as directories under the cwd (multi-level), skipping the
	# repo's own .git/.web. Trailing slash + nospace lets you keep drilling down.
	local d matches=()
	while IFS= read -r d; do
		case "$d" in .git | .git/* | .web | .web/*) continue ;; esac
		matches+=("$d/")
	done < <(compgen -d -- "$cur")
	COMPREPLY=("${matches[@]}")
	if [ "${#COMPREPLY[@]}" -gt 0 ]; then
		compopt -o nospace 2>/dev/null || true
	fi
	return 0
}

complete -o default -F _add_notes_complete add-notes
