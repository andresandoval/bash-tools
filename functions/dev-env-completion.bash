#!/usr/bin/env bash
#
# Tab-completion for the `dev-env` command. The first word is the command
# (apply, status, diff, pull, remove, adopt); the second is always the store,
# completed from the names under $DEV_ENV_HOME as well as from real paths.
# After that, what completes depends on the command: manifest destinations for
# `diff` and `pull`, target paths for `adopt`, and each command's own flags.

# Store names under $DEV_ENV_HOME: directories that hold a .manifest.
_dev_env_stores() {
	local root="${DEV_ENV_HOME:-$HOME/Dev/environments}" d
	for d in "$root"/*/; do
		if [ -f "$d.manifest" ]; then
			d="${d%/}"
			printf '%s\n' "${d##*/}"
		fi
	done
}

# Directory paths, handling spaces with the read pattern and trailing slashes
# so tab drilling continues.
_dev_env_target_dirs() {
	local d matches=()
	while IFS= read -r d; do
		matches+=("$d/")
	done < <(compgen -d -- "$1")
	COMPREPLY=("${matches[@]}")
	if [ "${#COMPREPLY[@]}" -gt 0 ]; then
		compopt -o nospace 2>/dev/null || true
	fi
}

# File paths for adopt, handling spaces with the read pattern and adding
# trailing slashes for directories so tab drilling continues.
_dev_env_adopt_files() {
	local f matches=()
	while IFS= read -r f; do
		if [ -d "$f" ]; then
			matches+=("$f/")
		else
			matches+=("$f")
		fi
	done < <(compgen -f -- "$1")
	COMPREPLY=("${matches[@]}")
	if [ "${#COMPREPLY[@]}" -gt 0 ]; then
		compopt -o nospace 2>/dev/null || true
	fi
}

# The dest values of a store's manifest, so diff/pull can complete an entry.
_dev_env_dests() {
	local arg="$1" path manifest
	case "$arg" in
	*/* | /* | .* | "~"*) path="$arg" ;;
	*) path="${DEV_ENV_HOME:-$HOME/Dev/environments}/$arg" ;;
	esac
	case "$path" in
	"~/"*) path="$HOME/${path#\~/}" ;;
	esac
	if [ -d "$path" ]; then manifest="$path/.manifest"; else manifest="$path"; fi
	if [ ! -f "$manifest" ]; then return 0; fi
	awk -F= '/^[[:space:]]*dest[[:space:]]*=/ {
		v = $2
		gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
		print v
	}' "$manifest"
}

_dev_env_complete() {
	local cur prev cmd flags i positionals=0 store_word
	cur="${COMP_WORDS[COMP_CWORD]}"
	prev="${COMP_WORDS[COMP_CWORD - 1]}"
	COMPREPLY=()

	# Word 1 is always the command.
	if [ "$COMP_CWORD" -le 1 ]; then
		COMPREPLY=($(compgen -W "apply status diff pull remove adopt --version --help" -- "$cur"))
		return 0
	fi
	cmd="${COMP_WORDS[1]}"

	# Option values first: they are not positional arguments.
	case "$prev" in
	--target)
		_dev_env_target_dirs "$cur"
		return 0
		;;
	--mode)
		COMPREPLY=($(compgen -W "link copy" -- "$cur"))
		return 0
		;;
	--as)
		return 0
		;;
	esac

	# Per-command flags, with shared tail factored.
	local tail="--target --help --version"
	case "$cmd" in
	apply) flags="--force-dir --dry-run --force $tail" ;;
	status) flags="$tail" ;;
	diff) flags="$tail" ;;
	pull) flags="--yes $tail" ;;
	remove) flags="--restore --force $tail" ;;
	adopt) flags="--as --mode $tail" ;;
	*) flags="--help" ;;
	esac

	if [ "${cur:0:1}" = "-" ]; then
		COMPREPLY=($(compgen -W "$flags" -- "$cur"))
		return 0
	fi

	# Count the positional words before the cursor, and record the store word.
	# The store is the first non-option word after the command, regardless of
	# where options appear in the command line.
	for ((i = 2; i < COMP_CWORD; i++)); do
		case "${COMP_WORDS[i]}" in
		-*) ;;
		*)
			case "${COMP_WORDS[i - 1]}" in
			--target | --as | --mode) ;;
			*)
				if [ -z "$store_word" ]; then
					store_word="${COMP_WORDS[i]}"
				fi
				positionals=$((positionals + 1))
				;;
			esac
			;;
		esac
	done

	if [ "$positionals" -eq 0 ]; then
		# Complete store names and directory paths, handling spaces in paths.
		COMPREPLY=($(compgen -W "$(_dev_env_stores)" -- "$cur"))
		local d
		while IFS= read -r d; do
			COMPREPLY+=("$d/")
		done < <(compgen -d -- "$cur")
		if [ "${#COMPREPLY[@]}" -gt 0 ]; then
			compopt -o nospace 2>/dev/null || true
		fi
		return 0
	fi

	case "$cmd" in
	diff | pull)
		COMPREPLY=($(compgen -W "$(_dev_env_dests "$store_word")" -- "$cur"))
		;;
	adopt)
		_dev_env_adopt_files "$cur"
		;;
	*)
		COMPREPLY=($(compgen -W "$flags" -- "$cur"))
		;;
	esac
	return 0
}

complete -F _dev_env_complete dev-env
