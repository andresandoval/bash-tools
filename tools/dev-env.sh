#!/usr/bin/env bash
#
# dev-env — apply a central store of environment files (.env files, local config
# folders, seed scripts) to any checkout, git worktree, or plain directory.
#
# The store lives outside every project (e.g. ~/Dev/environments/my-project) and
# holds a .manifest that says where each file belongs. The store is named on every
# run: nothing is inferred from the repository, because two projects may share a
# name and a target may not be a repository at all.
#
# Every invocation names one command: apply, status, diff, pull, remove, or adopt.
#
set -euo pipefail

# --- Resolve our own location (works through the bash-tools symlink) --------
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
TOOLS_DIR="$(dirname "$SELF")"
TOOL_REPO="$(dirname "$TOOLS_DIR")" # bash-tools repo root (for --version)

# --- Constants --------------------------------------------------------------
DEV_ENV_HOME="${DEV_ENV_HOME:-$HOME/Dev/environments}"
MANIFEST_NAME=".manifest"
BAK_SUFFIX=".dev-env.bak"
MANIFEST_VERSION=1

# --- Globals ----------------------------------------------------------------
# Parsed manifest entries: one index per entry, in manifest order.
E_MODE=()
E_SOURCE=()
E_DEST=()
E_OPTIONAL=()
E_LINE=()

STORE_ROOT=""
MANIFEST=""
TARGET_ROOT=""
CMD=""
ARGS=()

OPT_TARGET=""
OPT_FORCE_DIR=0
OPT_DRY_RUN=0
OPT_FORCE=0
OPT_RESTORE=0
OPT_YES=0
OPT_AS=""
OPT_MODE="link"

# --- Errors -----------------------------------------------------------------
die() {
	printf 'dev-env: %s\n' "$1" >&2
	exit 1
}

tool_version() {
	if git -C "$TOOL_REPO" rev-parse --git-dir >/dev/null 2>&1; then
		git -C "$TOOL_REPO" describe --tags --always --dirty 2>/dev/null \
			|| git -C "$TOOL_REPO" rev-parse --short HEAD
	else
		echo "unknown"
	fi
}

# --- Help -------------------------------------------------------------------
usage_overview() {
	cat <<'EOF'
Usage: dev-env <command> STORE [arguments] [options]

Apply a central store of environment files (.env files, config folders, seed
scripts) to the current checkout, git worktree, or plain directory, through the
store's manifest.

Commands:
  apply  STORE       Create every link and copy the manifest describes.
  status STORE       Report what is linked, missing, drifted, or foreign.
  diff   STORE       Show how copied files differ from the store.
  pull   STORE       Copy changed files back into the store.
  remove STORE       Remove what this store owns from the target.
  adopt  STORE PATH  Move a file into the store and link it back.

A command is required, and comes first: everything after it belongs to that
command. Run 'dev-env <command> --help' for a command's arguments and options.

STORE is the store directory, or its manifest file. A bare name (no slash) is
looked up under DEV_ENV_HOME.

Options (every command):
  --target DIR       Apply to DIR instead of the detected target root.
  --version          Print the tool version and exit.
  -h, --help         Show this help.

The target root is the git worktree root when you are inside one, and the
current directory otherwise, so the tool also works on a plain folder.

Tab completion is installed automatically via bash-tools (functions/).
EOF
	printf '\nDEV_ENV_HOME=%s\n' "$DEV_ENV_HOME"
}

# Help for a single command, so no block is longer than a screen.
usage_command() {
	case "$1" in
	apply)
		cat <<'EOF'
Usage: dev-env apply STORE [--force-dir] [--dry-run] [--force] [--target DIR]

Create every link and copy the manifest describes. The run is all or nothing:
the manifest, every source, and the target's directory structure are checked
first, and nothing is written when a check fails.

Options:
  --force-dir        Create missing parent directories in the target instead of
                     failing. Use it to seed an empty directory.
  --dry-run          Print the plan and write nothing.
  --force            Overwrite a copied file that differs from the store (the
                     target version is backed up first).
  --target DIR       Apply to DIR instead of the detected target root.

A path already in the way is moved to <name>.dev-env.bak and then linked. A
copied file that differs from the store is left alone and reported as drift.

Examples:
  dev-env apply ~/Dev/environments/my-project
  dev-env apply my-project --force-dir
EOF
		;;
	status)
		cat <<'EOF'
Usage: dev-env status STORE [--target DIR]

Report one line per manifest entry, and list the applied paths that git does not
ignore. Read-only: it writes nothing.

  ok            the link resolves to the store, or the copy is identical
  missing       the target path does not exist
  drift         a copied file differs from the store
  foreign       the path exists but this store does not own it
  stale-source  the source is gone from the store
  no-parent     the parent directory does not exist in the target

Exits 0 when every entry is ok or skipped, 1 otherwise.
EOF
		;;
	diff)
		cat <<'EOF'
Usage: dev-env diff STORE [PATH...] [--target DIR]

Show how copied files differ from the store: store version on the left, target
version on the right. Link entries are not shown; both sides are one file.

PATH selects entries by destination (with or without the leading /) or by store
source. With no PATH every copy entry is compared.

Exits 0 when there is no difference, 1 when there is one, 2 on an error.

Examples:
  dev-env diff my-project
  dev-env diff my-project /scripts/seed.sh
EOF
		;;
	pull)
		cat <<'EOF'
Usage: dev-env pull STORE [PATH...] [--yes] [--target DIR]

Copy changed files back into the store — the merge-back direction. Only copy
entries qualify; a link entry is already the same file on both sides. The store
version is kept as <name>.dev-env.bak.

Options:
  --yes              Do not ask for confirmation (also DEV_ENV_PULL=yes).
  --target DIR       Read from DIR instead of the detected target root.

Examples:
  dev-env diff my-project && echo "no changes"
  dev-env pull my-project /scripts/seed.sh
EOF
		;;
	remove)
		cat <<'EOF'
Usage: dev-env remove STORE [--restore] [--force] [--target DIR]

Remove what this store owns in the target: links that resolve into the store,
and copies identical to it. Anything else is kept and reported.

Options:
  --restore          Move each <name>.dev-env.bak back into place afterwards.
  --force            Also remove a copied file that differs from the store.
                     Those changes are lost — run 'dev-env diff' first.
  --target DIR       Act on DIR instead of the detected target root.
EOF
		;;
	adopt)
		cat <<'EOF'
Usage: dev-env adopt STORE PATH... [--as NAME] [--mode copy] [--target DIR]

Move files that are already in the target into the store, add manifest entries,
and link them back. This is how a store is built the first time. The store
directory and its manifest are created when they do not exist.

PATH is relative to the target root (a leading / is optional).

Options:
  --as NAME          Store the file under NAME instead of mirroring the path.
                     Only with exactly one PATH.
  --mode copy        Record a copy entry: the file is copied into the store and
                     the original stays where it is. Default is link (move).
  --target DIR       Read from DIR instead of the detected target root.

Examples:
  dev-env adopt my-project .env auth/.env
  dev-env adopt my-project auth/.env --as auth-service.env
EOF
		;;
	*)
		usage_overview
		;;
	esac
}

# --- Option parsing ---------------------------------------------------------

# Reject an option on a command that does not take it, so every command reports
# a wrong flag the same way.
opt_for() {
	local cmd="$1" allowed="$2" flag="$3"
	case " $allowed " in
	*" $cmd "*) return 0 ;;
	esac
	die "$flag is not an option of '$cmd' (run 'dev-env $cmd --help')"
}

# Split a command's words into positionals (ARGS) and options (the OPT_*
# globals). One parser for all six commands keeps the error wording identical.
parse_options() {
	local cmd="$1"
	shift
	ARGS=()
	while [ $# -gt 0 ]; do
		case "$1" in
		-h | --help)
			usage_command "$cmd"
			exit 0
			;;
		--version)
			tool_version
			exit 0
			;;
		--target)
			if [ $# -lt 2 ]; then die "--target needs a directory"; fi
			OPT_TARGET="$2"
			shift
			;;
		--target=*) OPT_TARGET="${1#--target=}" ;;
		--force-dir)
			opt_for "$cmd" "apply" "$1"
			OPT_FORCE_DIR=1
			;;
		--dry-run)
			opt_for "$cmd" "apply" "$1"
			OPT_DRY_RUN=1
			;;
		--force)
			opt_for "$cmd" "apply remove" "$1"
			OPT_FORCE=1
			;;
		--restore)
			opt_for "$cmd" "remove" "$1"
			OPT_RESTORE=1
			;;
		--yes)
			opt_for "$cmd" "pull" "$1"
			OPT_YES=1
			;;
		--as)
			opt_for "$cmd" "adopt" "$1"
			if [ $# -lt 2 ]; then die "--as needs a name"; fi
			OPT_AS="$2"
			shift
			;;
		--as=*)
			opt_for "$cmd" "adopt" "$1"
			OPT_AS="${1#--as=}"
			;;
		--mode)
			opt_for "$cmd" "adopt" "$1"
			if [ $# -lt 2 ]; then die "--mode needs link or copy"; fi
			OPT_MODE="$2"
			shift
			;;
		--mode=*)
			opt_for "$cmd" "adopt" "$1"
			OPT_MODE="${1#--mode=}"
			;;
		--)
			shift
			while [ $# -gt 0 ]; do
				ARGS+=("$1")
				shift
			done
			break
			;;
		-*) die "unknown option: $1 (run 'dev-env $cmd --help')" ;;
		*) ARGS+=("$1") ;;
		esac
		shift
	done
}

# Every command takes exactly one STORE, except adopt which also takes paths.
require_store() {
	if [ "${#ARGS[@]}" -eq 0 ]; then
		die "a store is required (usage: dev-env $CMD STORE — run 'dev-env $CMD --help')"
	fi
}

# --- Path helpers -----------------------------------------------------------

# Strip leading and trailing whitespace.
trim() {
	local s="$1"
	s="${s#"${s%%[![:space:]]*}"}"
	s="${s%"${s##*[![:space:]]}"}"
	printf '%s' "$s"
}

# Collapse repeated slashes and "./" segments, then drop a trailing slash. This
# is string work only: the path does not have to exist.
norm_path() {
	local p="$1"
	while [ "$p" != "${p//\/\//\/}" ]; do p="${p//\/\//\/}"; done
	while [ "$p" != "${p//\/.\//\/}" ]; do p="${p//\/.\//\/}"; done
	p="${p%/.}"
	if [ -z "$p" ]; then p="/"; fi
	if [ "${#p}" -gt 1 ]; then p="${p%/}"; fi
	printf '%s' "$p"
}

# True when any segment of the path is "..". Checked as a segment, so a file
# named "..env" is still allowed.
path_has_dotdot() {
	case "/$1/" in
	*/../*) return 0 ;;
	esac
	return 1
}

# --- Store resolution -------------------------------------------------------

# Turn the STORE argument into a filesystem path. A bare name (no slash, no
# leading dot or tilde) is looked up under DEV_ENV_HOME; anything else is a path.
store_path_for() {
	local arg="$1" path
	case "$arg" in
	"") die "a store is required (run 'dev-env --help')" ;;
	*/* | /* | .* | "~"*) path="$arg" ;;
	*) path="$DEV_ENV_HOME/$arg" ;;
	esac
	case "$path" in
	"~/"*) path="$HOME/${path#\~/}" ;;
	esac
	printf '%s' "$path"
}

# Set STORE_ROOT and MANIFEST. A directory means "<dir>/.manifest"; a file is
# the manifest itself, so a store can hold more than one.
resolve_store() {
	local path
	path="$(store_path_for "$1")"
	if [ -d "$path" ]; then
		STORE_ROOT="$(cd "$path" && pwd -P)"
		MANIFEST="$STORE_ROOT/$MANIFEST_NAME"
	elif [ -f "$path" ]; then
		MANIFEST="$(readlink -f -- "$path")"
		STORE_ROOT="$(dirname "$MANIFEST")"
	else
		die "store not found: $path"
	fi
	if [ ! -f "$MANIFEST" ]; then die "no $MANIFEST_NAME in $STORE_ROOT"; fi
	if [ ! -r "$MANIFEST" ]; then die "manifest is not readable: $MANIFEST"; fi
}

# --- Manifest parser --------------------------------------------------------
#
# The format is deliberately small: "version = 1", then one [link] or [copy]
# section per entry with source/dest/optional keys. Every problem is reported
# with its line number, and an unknown key is an error rather than a warning —
# a silently ignored "optonal = true" is a file that never appears.

PARSE_ERRORS=0
VERSION_SEEN=0
CUR_SECTION=""
CUR_SOURCE=""
CUR_DEST=""
CUR_OPTIONAL=""
CUR_LINE=0

manifest_err() {
	printf '%s:%s: %s\n' "$MANIFEST" "$1" "$2" >&2
	PARSE_ERRORS=$((PARSE_ERRORS + 1))
}

# Close the section that just ended and append it as an entry.
flush_entry() {
	if [ -z "$CUR_SECTION" ]; then return 0; fi
	if [ -z "$CUR_SOURCE" ]; then manifest_err "$CUR_LINE" "[$CUR_SECTION] has no 'source'"; fi
	if [ -z "$CUR_DEST" ]; then manifest_err "$CUR_LINE" "[$CUR_SECTION] has no 'dest'"; fi
	if [ -n "$CUR_SOURCE" ] && [ -n "$CUR_DEST" ]; then
		E_MODE+=("$CUR_SECTION")
		E_SOURCE+=("$CUR_SOURCE")
		E_DEST+=("$CUR_DEST")
		E_OPTIONAL+=("${CUR_OPTIONAL:-false}")
		E_LINE+=("$CUR_LINE")
	fi
	CUR_SECTION=""
	CUR_SOURCE=""
	CUR_DEST=""
	CUR_OPTIONAL=""
	return 0
}

# A key before the first section. Only 'version' belongs there, and it is what
# makes a future format change detectable instead of silently misread.
parse_preamble_key() {
	local lineno="$1" key="$2" val="$3"
	if [ "$key" != version ]; then
		manifest_err "$lineno" "'$key' is outside a section (expected [link] or [copy] first)"
		return 0
	fi
	if [ "$VERSION_SEEN" = 1 ]; then
		manifest_err "$lineno" "duplicate 'version'"
		return 0
	fi
	VERSION_SEEN=1
	if [ "$val" != "$MANIFEST_VERSION" ]; then
		manifest_err "$lineno" "manifest version '$val' is not supported (this tool supports version $MANIFEST_VERSION)"
	fi
	return 0
}

# A key inside a [link] or [copy] section.
parse_entry_key() {
	local lineno="$1" key="$2" val="$3"
	case "$key" in
	source)
		if [ -n "$CUR_SOURCE" ]; then
			manifest_err "$lineno" "duplicate 'source' in this section"
			return 0
		fi
		if [ -z "$val" ]; then
			manifest_err "$lineno" "'source' is empty"
			return 0
		fi
		case "$val" in
		/*)
			manifest_err "$lineno" "'source' must be relative to the store root: $val"
			return 0
			;;
		esac
		if path_has_dotdot "$val"; then
			manifest_err "$lineno" "'source' must not contain '..': $val"
			return 0
		fi
		CUR_SOURCE="$(norm_path "$val")"
		;;
	dest)
		if [ -n "$CUR_DEST" ]; then
			manifest_err "$lineno" "duplicate 'dest' in this section"
			return 0
		fi
		case "$val" in
		/*) ;;
		*)
			manifest_err "$lineno" "'dest' must start with '/' (the target root): $val"
			return 0
			;;
		esac
		if path_has_dotdot "$val"; then
			manifest_err "$lineno" "'dest' must not contain '..': $val"
			return 0
		fi
		val="$(norm_path "$val")"
		if [ "$val" = "/" ]; then
			manifest_err "$lineno" "'dest' must name a path inside the target root"
			return 0
		fi
		CUR_DEST="$val"
		;;
	optional)
		if [ -n "$CUR_OPTIONAL" ]; then
			manifest_err "$lineno" "duplicate 'optional' in this section"
			return 0
		fi
		case "$val" in
		true | false) CUR_OPTIONAL="$val" ;;
		*) manifest_err "$lineno" "'optional' must be true or false, not '$val'" ;;
		esac
		;;
	version)
		manifest_err "$lineno" "'version' must appear before the first section"
		;;
	*)
		manifest_err "$lineno" "unknown key: $key (expected source, dest, or optional)"
		;;
	esac
	return 0
}

# Two entries may share a source — one store file can feed two places — but never
# a destination, and no destination may sit inside another one: linking a
# directory and something under it has no defined result.
check_entry_conflicts() {
	local i j
	for i in "${!E_DEST[@]}"; do
		for j in "${!E_DEST[@]}"; do
			if [ "$j" -le "$i" ]; then continue; fi
			if [ "${E_DEST[$i]}" = "${E_DEST[$j]}" ]; then
				manifest_err "${E_LINE[$j]}" "duplicate dest '${E_DEST[$j]}' (also at line ${E_LINE[$i]})"
				continue
			fi
			case "${E_DEST[$j]}" in
			"${E_DEST[$i]}"/*) manifest_err "${E_LINE[$j]}" "dest '${E_DEST[$j]}' is inside '${E_DEST[$i]}' (line ${E_LINE[$i]})" ;;
			esac
			case "${E_DEST[$i]}" in
			"${E_DEST[$j]}"/*) manifest_err "${E_LINE[$i]}" "dest '${E_DEST[$i]}' is inside '${E_DEST[$j]}' (line ${E_LINE[$j]})" ;;
			esac
		done
	done
	return 0
}

# Read MANIFEST into the E_* arrays. Every problem is printed; the run stops
# only at the end, so one pass shows the whole list.
parse_manifest() {
	local line key val sec lineno=0 skip_section=0
	E_MODE=()
	E_SOURCE=()
	E_DEST=()
	E_OPTIONAL=()
	E_LINE=()
	PARSE_ERRORS=0
	VERSION_SEEN=0
	CUR_SECTION=""
	CUR_SOURCE=""
	CUR_DEST=""
	CUR_OPTIONAL=""
	CUR_LINE=0

	while IFS= read -r line || [ -n "$line" ]; do
		lineno=$((lineno + 1))
		line="$(trim "$line")"
		if [ -z "$line" ]; then continue; fi
		case "$line" in
		'#'*) continue ;;
		'['*']')
			flush_entry
			skip_section=0
			sec="$(trim "${line#\[}")"
			sec="$(trim "${sec%\]}")"
			case "$sec" in
			link | copy)
				CUR_SECTION="$sec"
				CUR_LINE="$lineno"
				;;
			*)
				manifest_err "$lineno" "unknown directive: [$sec] (expected [link] or [copy])"
				skip_section=1
				;;
			esac
			;;
		*'='*)
			if [ "$skip_section" = 1 ]; then continue; fi
			key="$(trim "${line%%=*}")"
			val="$(trim "${line#*=}")"
			if [ -z "$CUR_SECTION" ]; then
				parse_preamble_key "$lineno" "$key" "$val"
			else
				parse_entry_key "$lineno" "$key" "$val"
			fi
			;;
		*)
			manifest_err "$lineno" "not a comment, a section, or a 'key = value' line"
			;;
		esac
	done <"$MANIFEST"
	flush_entry

	if [ "$VERSION_SEEN" = 0 ]; then
		manifest_err 1 "missing 'version = $MANIFEST_VERSION' before the first section"
	fi
	check_entry_conflicts

	if [ "$PARSE_ERRORS" -gt 0 ]; then
		die "$PARSE_ERRORS problem(s) in the manifest; nothing was changed"
	fi
	return 0
}

# --- Target resolution ------------------------------------------------------

# Where the links go: --target when given, else the git worktree root (so the
# tool works from a subdirectory of a checkout), else the current directory —
# the target does not have to be a repository at all.
resolve_target() {
	local top
	if [ -n "$OPT_TARGET" ]; then
		if [ ! -d "$OPT_TARGET" ]; then die "target directory not found: $OPT_TARGET"; fi
		TARGET_ROOT="$(cd "$OPT_TARGET" && pwd -P)"
	elif top="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$top" ]; then
		TARGET_ROOT="$(cd "$top" && pwd -P)"
	else
		TARGET_ROOT="$(pwd -P)"
	fi
	return 0
}

# --- Entry helpers ----------------------------------------------------------

entry_source() { printf '%s/%s' "$STORE_ROOT" "${E_SOURCE[$1]}"; }
entry_dest() { printf '%s%s' "$TARGET_ROOT" "${E_DEST[$1]}"; }
entry_rel() { printf '%s' "${E_DEST[$1]#/}"; }

# True when DEST is a symlink that resolves to SRC — the only way the tool knows
# a path is its own, since it keeps no state file.
is_store_link() {
	local dest="$1" src="$2"
	if [ ! -L "$dest" ]; then return 1; fi
	[ "$(readlink -f -- "$dest" 2>/dev/null)" = "$(readlink -f -- "$src" 2>/dev/null)" ]
}

# True when the store version and the target version hold the same bytes.
same_content() {
	local src="$1" dest="$2"
	if [ -d "$src" ]; then
		if [ ! -d "$dest" ]; then return 1; fi
		diff -rq -- "$src" "$dest" >/dev/null 2>&1
	else
		if [ ! -f "$dest" ]; then return 1; fi
		cmp -s -- "$src" "$dest"
	fi
}

# True when nothing occupies the backup path yet. A second backup would hide a
# leftover from an earlier run, so the tool refuses instead.
backup_free() {
	if [ -e "$1$BAK_SUFFIX" ] || [ -L "$1$BAK_SUFFIX" ]; then return 1; fi
	return 0
}

report() { printf '  %-9s %s%s\n' "$1" "$2" "${3:+  ($3)}"; }

# --- apply ------------------------------------------------------------------
#
# Planning is separate from writing so the run is all or nothing: every blocker
# is collected first and printed together, and the target is untouched when one
# is found. --dry-run is then just "print the plan and stop".

PLAN=()
MKDIRS=()

plan_apply() {
	local i src dest parent problems=()
	PLAN=()
	MKDIRS=()

	case "${OSTYPE:-}" in
	msys* | cygwin*)
		for i in "${!E_MODE[@]}"; do
			if [ "${E_MODE[$i]}" = link ]; then
				problems+=("'ln -s' is unreliable in this shell (MSYS/Cygwin); use 'mode = copy' entries there")
				break
			fi
		done
		;;
	esac

	for i in "${!E_MODE[@]}"; do
		src="$(entry_source "$i")"
		dest="$(entry_dest "$i")"

		if [ ! -e "$src" ] && [ ! -L "$src" ]; then
			if [ "${E_OPTIONAL[$i]}" = true ]; then
				PLAN+=("skip")
			else
				problems+=("missing in the store: ${E_SOURCE[$i]} (line ${E_LINE[$i]})")
				PLAN+=("skip")
			fi
			continue
		fi

		parent="$(dirname "${E_DEST[$i]}")"
		if [ ! -d "$TARGET_ROOT$parent" ]; then
			if [ "$OPT_FORCE_DIR" = 1 ]; then
				MKDIRS+=("$parent")
			else
				problems+=("no such directory in the target: $parent (needed by ${E_DEST[$i]}) — pass --force-dir to create it")
				PLAN+=("skip")
				continue
			fi
		fi

		case "${E_MODE[$i]}" in
		link)
			if is_store_link "$dest" "$src"; then
				PLAN+=("ok")
			elif [ -e "$dest" ] || [ -L "$dest" ]; then
				if backup_free "$dest"; then
					PLAN+=("backup+link")
				else
					problems+=("backup path already taken: ${E_DEST[$i]}$BAK_SUFFIX — move or delete it first")
					PLAN+=("skip")
				fi
			else
				PLAN+=("link")
			fi
			;;
		copy)
			if [ -L "$dest" ]; then
				# A symlink is never a managed copy, so treat it as an obstacle.
				if backup_free "$dest"; then
					PLAN+=("backup+copy")
				else
					problems+=("backup path already taken: ${E_DEST[$i]}$BAK_SUFFIX — move or delete it first")
					PLAN+=("skip")
				fi
			elif [ ! -e "$dest" ]; then
				PLAN+=("copy")
			elif same_content "$src" "$dest"; then
				PLAN+=("ok")
			elif [ "$OPT_FORCE" = 1 ]; then
				if backup_free "$dest"; then
					PLAN+=("backup+copy")
				else
					problems+=("backup path already taken: ${E_DEST[$i]}$BAK_SUFFIX — move or delete it first")
					PLAN+=("skip")
				fi
			else
				PLAN+=("drift")
			fi
			;;
		esac
	done

	if [ "${#problems[@]}" -gt 0 ]; then
		printf '\ndev-env: cannot apply this store\n' >&2
		printf '  - %s\n' "${problems[@]}" >&2
		printf '\nNothing was changed.\n' >&2
		exit 1
	fi
	return 0
}

# Execute PLAN. Returns 1 when an entry was left unapplied, so the caller can
# exit non-zero: the target does not match the store when that happens.
run_plan() {
	local i src dest rel action status=0 d seen=""
	if [ "${#MKDIRS[@]}" -gt 0 ]; then
		for d in "${MKDIRS[@]}"; do
			# Two entries may need the same parent; report it once.
			case "$seen" in
			*"|$d|"*) continue ;;
			esac
			seen="$seen|$d|"
			if [ "$OPT_DRY_RUN" != 1 ]; then mkdir -p -- "$TARGET_ROOT$d"; fi
			report mkdir "$d"
		done
	fi

	for i in "${!PLAN[@]}"; do
		action="${PLAN[$i]}"
		src="$(entry_source "$i")"
		dest="$(entry_dest "$i")"
		rel="${E_DEST[$i]}"
		case "$action" in
		ok)
			report ok "$rel"
			;;
		skip)
			report skipped "$rel" "optional source missing: ${E_SOURCE[$i]}"
			;;
		drift)
			report drift "$rel" "differs from the store; run 'dev-env diff', 'dev-env pull', or apply --force"
			status=1
			;;
		*)
			if [ "$OPT_DRY_RUN" = 1 ]; then
				report "${action}" "$rel"
				continue
			fi
			case "$action" in
			backup+*)
				mv -- "$dest" "$dest$BAK_SUFFIX"
				report backup "$rel" "kept as $(basename "$rel")$BAK_SUFFIX"
				;;
			esac
			case "$action" in
			*link)
				ln -s -- "$src" "$dest"
				report linked "$rel"
				;;
			*copy)
				cp -R -p -- "$src" "$dest"
				report copied "$rel"
				;;
			esac
			;;
		esac
	done
	return "$status"
}

# --- git ignore report -------------------------------------------------------
#
# Applied files are untracked by design, so they clutter "git status" until they
# are ignored. The tool reports them and prints the command to fix it, but never
# edits .gitignore (a tracked file) or the exclude file itself: that is git state
# the user did not ask it to change.
git_ignore_report() {
	local i rel common q list rels=()
	if ! git -C "$TARGET_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		return 0
	fi
	for i in "${!E_DEST[@]}"; do
		rel="$(entry_rel "$i")"
		if [ ! -e "$TARGET_ROOT/$rel" ] && [ ! -L "$TARGET_ROOT/$rel" ]; then continue; fi
		if git -C "$TARGET_ROOT" check-ignore -q -- "$rel"; then continue; fi
		rels+=("$rel")
	done
	if [ "${#rels[@]}" -eq 0 ]; then return 0; fi

	common="$(git -C "$TARGET_ROOT" rev-parse --git-common-dir)"
	case "$common" in
	/*) ;;
	*) common="$TARGET_ROOT/$common" ;;
	esac

	# Build the fix line with the paths already quoted, so it can be pasted as is.
	q="'"
	list=""
	for rel in "${rels[@]}"; do list="$list $q/$rel$q"; done

	printf '\nNot ignored by git:\n'
	printf '  %s\n' "${rels[@]}"
	printf '\nAdd them locally (not committed):\n'
	printf '  printf %s%%s\\n%s%s >> %s/info/exclude\n' "$q" "$q" "$list" "$common"
	return 0
}

# --- status -----------------------------------------------------------------

# One word for what the target holds for entry I. The tool keeps no state, so
# ownership is decided by looking at the path itself.
classify_entry() {
	local i="$1" src dest
	src="$(entry_source "$i")"
	dest="$(entry_dest "$i")"

	if [ ! -e "$src" ] && [ ! -L "$src" ]; then
		if [ "${E_OPTIONAL[$i]}" = true ]; then printf 'skipped'; else printf 'stale-source'; fi
		return 0
	fi
	if [ ! -d "$(dirname "$dest")" ]; then
		printf 'no-parent'
		return 0
	fi
	case "${E_MODE[$i]}" in
	link)
		if is_store_link "$dest" "$src"; then
			printf 'ok'
		elif [ -e "$dest" ] || [ -L "$dest" ]; then
			printf 'foreign'
		else
			printf 'missing'
		fi
		;;
	copy)
		if [ -L "$dest" ]; then
			printf 'foreign'
		elif [ ! -e "$dest" ]; then
			printf 'missing'
		elif same_content "$src" "$dest"; then
			printf 'ok'
		else
			printf 'drift'
		fi
		;;
	esac
	return 0
}

# --- Commands (filled in by later tasks) ------------------------------------
cmd_apply() {
	parse_options apply "$@"
	require_store
	if [ "${#ARGS[@]}" -gt 1 ]; then die "unexpected argument: ${ARGS[1]}"; fi
	resolve_store "${ARGS[0]}"
	resolve_target
	parse_manifest

	printf 'Store:  %s\n' "$STORE_ROOT"
	printf 'Target: %s\n' "$TARGET_ROOT"
	if [ "${#E_MODE[@]}" -eq 0 ]; then
		printf 'The manifest has no entries; nothing to do.\n'
		exit 2
	fi
	if [ ! -w "$TARGET_ROOT" ]; then die "target is not writable: $TARGET_ROOT"; fi

	plan_apply
	if [ "$OPT_DRY_RUN" = 1 ]; then printf '\ndry run — nothing will be changed\n'; fi
	printf '\n'

	local rc=0
	run_plan || rc=$?
	git_ignore_report
	exit "$rc"
}

cmd_status() {
	parse_options status "$@"
	require_store
	if [ "${#ARGS[@]}" -gt 1 ]; then die "unexpected argument: ${ARGS[1]}"; fi
	resolve_store "${ARGS[0]}"
	resolve_target
	parse_manifest

	printf 'Store:  %s\n' "$STORE_ROOT"
	printf 'Target: %s\n' "$TARGET_ROOT"
	if [ "${#E_MODE[@]}" -eq 0 ]; then
		printf 'The manifest has no entries.\n'
		exit 0
	fi
	printf '\n'

	local i state dest note rc=0
	for i in "${!E_MODE[@]}"; do
		state="$(classify_entry "$i")"
		dest="$(entry_dest "$i")"
		note=""
		if [ -e "$dest$BAK_SUFFIX" ] || [ -L "$dest$BAK_SUFFIX" ]; then note="backup present"; fi
		report "$state" "${E_DEST[$i]}" "$note"
		case "$state" in
		ok | skipped) ;;
		*) rc=1 ;;
		esac
	done

	git_ignore_report
	exit "$rc"
}

cmd_diff() {
	parse_options diff "$@"
	require_store
	die "not implemented yet"
}

cmd_pull() {
	parse_options pull "$@"
	require_store
	die "not implemented yet"
}

cmd_remove() {
	parse_options remove "$@"
	require_store
	die "not implemented yet"
}

cmd_adopt() {
	parse_options adopt "$@"
	require_store
	die "not implemented yet"
}

# --- Dispatch ---------------------------------------------------------------
main() {
	if [ $# -eq 0 ]; then
		printf 'a command is required (apply, status, diff, pull, remove, or adopt).\n\n' >&2
		usage_overview >&2
		exit 1
	fi
	case "$1" in
	-h | --help)
		usage_overview
		exit 0
		;;
	--version)
		tool_version
		exit 0
		;;
	apply | status | diff | pull | remove | adopt)
		CMD="$1"
		shift
		"cmd_$CMD" "$@"
		;;
	*)
		printf 'unknown command: %s (expected apply, status, diff, pull, remove, or adopt)\n' "$1" >&2
		printf "Run 'dev-env --help' to see all commands.\n" >&2
		exit 1
		;;
	esac
}

# Run only when executed, so a test harness can source this file and call single
# functions without the dispatch firing.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	main "$@"
fi
