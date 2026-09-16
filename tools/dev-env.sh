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

# --- Commands (filled in by later tasks) ------------------------------------
cmd_apply() {
	parse_options apply "$@"
	require_store
	die "not implemented yet"
}

cmd_status() {
	parse_options status "$@"
	require_store
	die "not implemented yet"
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
