#!/usr/bin/env bash
#
# add-notes — store AI meeting notes as clean Markdown in the current directory,
# then commit (and push if a remote exists). The directory you run this in is the
# notes repository: it is git-initialized on demand and gets a self-contained
# `.web/` search UI deployed into it.
#
# You choose the structure: PATH is a freeform, multi-level path (e.g.
# project/team/standup). Notes are saved to <PATH>/<date>.md, or to an exact file
# when PATH ends in .md (e.g. project/standup/recap-26-02-12.md, for past meetings).
# Formatted (HTML) clipboard content is converted to Markdown automatically.
#
set -euo pipefail

# --- Resolve our own location (works through the bash-tools symlink) --------
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
TOOLS_DIR="$(dirname "$SELF")"            # .../bash-tools/tools
ASSET_DIR="$TOOLS_DIR/add-notes"          # support assets (lib/, web/)
LIB="$ASSET_DIR/lib"
WEB_TEMPLATE="$ASSET_DIR/web"
TOOL_REPO="$(dirname "$TOOLS_DIR")"       # bash-tools repo root (for versioning)

NOTES_ROOT="$(pwd)"

usage() {
	cat <<'EOF'
Usage: add-notes PATH [--from FILE | --from-clipboard] [--no-push]

Store meeting notes as clean Markdown at PATH inside the current directory's notes
repository, then commit (and push if a remote is configured).

Arguments:
  PATH   Destination path describing your own (multi-level) structure:
           project/team/standup        -> project/team/standup/<date>.md
           project/standup/recap.md     a .md ending sets the exact filename,
                                         handy for backfilling past meetings
         Each folder segment is slugified (lowercase, hyphenated); the original
         text is kept in the note's frontmatter title.

Options:
  --from FILE        Read the raw notes from FILE.
  --from-clipboard   Read the raw notes from the clipboard (the default if no
                     source flag is given). Formatted (HTML) clipboard content is
                     converted to Markdown automatically; otherwise plain text.
  --no-push          Commit but do not push (also via ADD_NOTES_NO_PUSH=1).
  --version          Print the tool version and exit.
  -h, --help         Show this help.

Behavior:
  - The current directory is the notes repo and must be the git repository root
    (running from a subdirectory exits with an error). If it is not a git repo you
    are asked to initialize one (skip with ADD_NOTES_INIT=yes|no); if it already is,
    the working tree must be clean.
  - A self-contained search UI is deployed/refreshed in ./.web (open index.html).
  - If the target note already exists you are asked to override, append, or cancel
    (override non-interactively with ADD_NOTES_ON_EXISTING=override|append|cancel).

Examples:
  add-notes garagehub/daily-standup
  add-notes garagehub/auth/design-review --from ./notes.md
  add-notes garagehub/daily-standup/jun-12-2026.md   # backfill a past note

Tab completion is installed automatically via bash-tools (functions/).
EOF
}

tool_version() {
	if git -C "$TOOL_REPO" rev-parse --git-dir >/dev/null 2>&1; then
		git -C "$TOOL_REPO" describe --tags --always --dirty 2>/dev/null \
			|| git -C "$TOOL_REPO" rev-parse --short HEAD
	elif [ -f "$ASSET_DIR/VERSION" ]; then
		cat "$ASSET_DIR/VERSION"
	else
		echo "unknown"
	fi
}

# --- Preflight: required tools must exist before we touch anything ----------
check_deps() {
	local missing=()
	command -v python3 >/dev/null 2>&1 || missing+=("python3 — install Python 3")
	command -v git >/dev/null 2>&1 || missing+=("git — install Git")
	if [ "${#missing[@]}" -gt 0 ]; then
		echo "Error: missing required dependencies:" >&2
		printf '  - %s\n' "${missing[@]}" >&2
		exit 1
	fi
}

# --- Clipboard helpers (only used in clipboard mode) ------------------------
# powershell.exe writes stdout in the legacy console code page, which corrupts
# non-ASCII text (nbsp, em dashes, curly quotes). Forcing UTF-8 output fixes it.
PS_UTF8='[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; '

read_clipboard_text() {
	if command -v powershell.exe >/dev/null 2>&1; then
		powershell.exe -NoProfile -Command "${PS_UTF8}Get-Clipboard" 2>/dev/null
	elif command -v pbpaste >/dev/null 2>&1; then
		pbpaste
	elif command -v wl-paste >/dev/null 2>&1; then
		wl-paste
	elif command -v xclip >/dev/null 2>&1; then
		xclip -selection clipboard -o
	elif command -v xsel >/dev/null 2>&1; then
		xsel -b
	else
		return 1
	fi
}

read_clipboard_html() {
	if command -v powershell.exe >/dev/null 2>&1; then
		powershell.exe -NoProfile -Command "${PS_UTF8}Get-Clipboard -TextFormatType Html" 2>/dev/null
	elif command -v wl-paste >/dev/null 2>&1; then
		wl-paste -t text/html 2>/dev/null
	elif command -v xclip >/dev/null 2>&1; then
		xclip -selection clipboard -t text/html -o 2>/dev/null
	fi
}

not_blank() { [ -n "$(printf '%s' "$1" | tr -d '[:space:]')" ]; }

slugify() {
	echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

# --- Git seeding: ensure the cwd is a clean notes repo at its root ----------
ensure_notes_repo() {
	if git -C "$NOTES_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		# Must be run from the repository root, not a subdirectory.
		local toplevel here
		toplevel="$(git -C "$NOTES_ROOT" rev-parse --show-toplevel)"
		here="$(cd "$NOTES_ROOT" && pwd -P)"
		if [ "$here" != "$toplevel" ]; then
			echo "Error: add-notes must be run from the root of the git repository." >&2
			echo "       Repository root: $toplevel" >&2
			echo "       Current dir:     $here" >&2
			echo "       cd to the repository root and try again." >&2
			exit 1
		fi
		if [ -n "$(git -C "$NOTES_ROOT" status --porcelain)" ]; then
			echo "Error: git working tree is not clean — commit or stash first." >&2
			echo "       (add-notes commits each note on its own, so the tree must start clean.)" >&2
			exit 1
		fi
	else
		local ans="${ADD_NOTES_INIT:-}"
		if [ -z "$ans" ]; then
			echo "This directory is not a git repository: $NOTES_ROOT"
			printf "Initialize one here? [y/N] "
			if [ -r /dev/tty ]; then read -r ans </dev/tty || ans="n"; else read -r ans || ans="n"; fi
		fi
		case "$ans" in
		y | Y | yes) git -C "$NOTES_ROOT" init -q && echo "Initialized empty git repository." ;;
		*)
			echo "Aborted. A git repo is required (git is the source of truth)."
			exit 1
			;;
		esac
	fi
}

# --- Ensure a usable git identity (config or env), fail clean if missing ----
check_git_identity() {
	if ! git -C "$NOTES_ROOT" var GIT_AUTHOR_IDENT >/dev/null 2>&1; then
		echo "Error: git identity is not configured, so the note could not be committed." >&2
		echo "Set one for this repo:" >&2
		echo "  git -C \"$NOTES_ROOT\" config user.name  \"Your Name\"" >&2
		echo "  git -C \"$NOTES_ROOT\" config user.email \"you@example.com\"" >&2
		echo "(or configure a global identity with: git config --global user.name …)" >&2
		exit 1
	fi
}

# --- Deploy/refresh the .web UI from the tool template ----------------------
deploy_web_if_stale() {
	local current marker
	current="$(tool_version)"
	marker="$NOTES_ROOT/.web/.tool-version"
	if [ ! -f "$marker" ] || [ "$(cat "$marker" 2>/dev/null)" != "$current" ]; then
		mkdir -p "$NOTES_ROOT/.web"
		cp -R "$WEB_TEMPLATE/." "$NOTES_ROOT/.web/"
		printf '%s\n' "$current" >"$marker"
		echo "Deployed/updated .web (tool version $current)."
	fi
}

# --- Parse arguments --------------------------------------------------------
if [ "$#" -eq 0 ]; then
	usage
	exit 0
fi

NO_PUSH=0
[ -n "${ADD_NOTES_NO_PUSH:-}" ] && NO_PUSH=1
DEST_PATH=""
SOURCE_FILE=""
SOURCE_MODE="" # "" (default→clipboard) | file | clipboard

conflict() {
	echo "Error: --from and --from-clipboard are mutually exclusive." >&2
	exit 1
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	-h | --help)
		usage
		exit 0
		;;
	--version)
		tool_version
		exit 0
		;;
	--no-push) NO_PUSH=1 ;;
	--from-clipboard)
		[ "$SOURCE_MODE" = "file" ] && conflict
		SOURCE_MODE="clipboard"
		;;
	--from)
		[ "$SOURCE_MODE" = "clipboard" ] && conflict
		shift
		SOURCE_FILE="${1:-}"
		[ -z "$SOURCE_FILE" ] && {
			echo "Error: --from requires a FILE argument." >&2
			exit 1
		}
		SOURCE_MODE="file"
		;;
	--from=*)
		[ "$SOURCE_MODE" = "clipboard" ] && conflict
		SOURCE_FILE="${1#--from=}"
		SOURCE_MODE="file"
		;;
	-*)
		echo "Error: unknown option: $1" >&2
		exit 1
		;;
	*)
		if [ -z "$DEST_PATH" ]; then
			DEST_PATH="$1"
		else
			echo "Error: unexpected argument: $1 (PATH is a single argument; use --from for a file)" >&2
			exit 1
		fi
		;;
	esac
	shift
done

if [ -z "$DEST_PATH" ]; then
	echo "Error: PATH is required." >&2
	echo >&2
	usage >&2
	exit 1
fi
[ -z "$SOURCE_MODE" ] && SOURCE_MODE="clipboard"

# --- Validate and parse the destination path --------------------------------
case "$DEST_PATH" in
/*)
	echo "Error: PATH must be relative (no leading '/')." >&2
	exit 1
	;;
esac
DEST_PATH="${DEST_PATH%/}"
case "/$DEST_PATH/" in
*/../*)
	echo "Error: PATH must not contain '..' segments." >&2
	exit 1
	;;
esac

IFS='/' read -ra RAW_SEGS <<<"$DEST_PATH"
DATE="$(date +%b-%d-%Y | tr '[:upper:]' '[:lower:]')"
CREATED="$(date +%Y-%m-%dT%H:%M:%S)"
TIME="$(date +%H:%M)"

# A trailing ".md" segment is an explicit filename; otherwise append <date>.md.
last_index=$((${#RAW_SEGS[@]} - 1))
last="${RAW_SEGS[$last_index]}"
dir_segs=()
if [[ "$last" == *.md ]]; then
	custom_stem="${last%.md}"
	for ((i = 0; i < last_index; i++)); do dir_segs+=("${RAW_SEGS[$i]}"); done
	stem_slug="$(slugify "$custom_stem")"
	[ -z "$stem_slug" ] && {
		echo "Error: invalid .md filename in PATH." >&2
		exit 1
	}
	FNAME="$stem_slug.md"
	DATE_FIELD="$stem_slug"
else
	dir_segs=("${RAW_SEGS[@]}")
	FNAME="$DATE.md"
	DATE_FIELD="$DATE"
fi

DIR_SLUGS=()
TITLE=""
for s in "${dir_segs[@]}"; do
	[ -z "$s" ] && continue
	DIR_SLUGS+=("$(slugify "$s")")
	TITLE="${TITLE:+$TITLE / }$s"
done
[ -z "$TITLE" ] && TITLE="${FNAME%.md}"
RELDIR="$(IFS=/; echo "${DIR_SLUGS[*]:-}")"
if [ -n "$RELDIR" ]; then DIR="$NOTES_ROOT/$RELDIR"; else DIR="$NOTES_ROOT"; fi
FILE="$DIR/$FNAME"

# --- Preconditions ----------------------------------------------------------
check_deps
ensure_notes_repo
check_git_identity
deploy_web_if_stale

# --- Resolve content --------------------------------------------------------
if [ "$SOURCE_MODE" = "file" ]; then
	if [ ! -f "$SOURCE_FILE" ]; then
		echo "Error: file not found: $SOURCE_FILE" >&2
		exit 1
	fi
	content="$(cat "$SOURCE_FILE")"
else
	html="$(read_clipboard_html || true)"
	if not_blank "$html"; then
		content="$(printf '%s' "$html" | python3 "$LIB/html2md.py")"
		echo "(converted rich clipboard HTML to Markdown)"
	elif content="$(read_clipboard_text)"; then
		: # plain text (may be empty → caught by the not_blank check below)
	else
		echo "Error: no clipboard tool found. Install xclip or wl-clipboard," >&2
		echo "       or pass a file: add-notes PATH --from FILE" >&2
		exit 1
	fi
fi

if ! not_blank "$content"; then
	echo "Error: no note content (file/clipboard was empty)." >&2
	exit 1
fi

# --- Write (handle collision) -----------------------------------------------
cleaned_with_fm="$(printf '%s' "$content" | python3 "$LIB/clean_md.py" \
	--title "$TITLE" --date "$DATE_FIELD" --created "$CREATED")"

mkdir -p "$DIR"

write_new() { printf '%s\n' "$cleaned_with_fm" >"$FILE"; }
append_section() {
	local body
	body="$(printf '%s' "$content" | python3 "$LIB/clean_md.py")"
	printf '\n\n## Added %s\n\n%s\n' "$TIME" "$body" >>"$FILE"
}

if [ -f "$FILE" ]; then
	choice="${ADD_NOTES_ON_EXISTING:-}"
	if [ -z "$choice" ]; then
		echo "A note already exists: ${FILE#"$NOTES_ROOT"/}"
		printf "Override, append, or cancel? [o/a/c] "
		if [ -r /dev/tty ]; then read -r choice </dev/tty || choice="c"; else read -r choice || choice="c"; fi
	fi
	case "$choice" in
	o | O | override) write_new && echo "Overrode ${FILE#"$NOTES_ROOT"/}" ;;
	a | A | append) append_section && echo "Appended to ${FILE#"$NOTES_ROOT"/}" ;;
	*)
		echo "Cancelled. No changes made."
		exit 0
		;;
	esac
else
	write_new
	echo "Wrote ${FILE#"$NOTES_ROOT"/}"
fi

# --- Rebuild index ----------------------------------------------------------
python3 "$LIB/build_index.py" "$NOTES_ROOT"

# --- Commit & push ----------------------------------------------------------
git -C "$NOTES_ROOT" add -A
if git -C "$NOTES_ROOT" diff --cached --quiet; then
	echo "Nothing to commit."
	exit 0
fi
git -C "$NOTES_ROOT" commit -q -m "Add notes: $TITLE ($DATE_FIELD)"
echo "Committed."

if [ "$NO_PUSH" -eq 1 ]; then
	echo "Skipped push (--no-push)."
	exit 0
fi

# Push only when there is somewhere to push to.
if git -C "$NOTES_ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
	git -C "$NOTES_ROOT" push && echo "Pushed."
elif git -C "$NOTES_ROOT" remote get-url origin >/dev/null 2>&1; then
	git -C "$NOTES_ROOT" push -u origin HEAD && echo "Pushed (set upstream to origin)."
else
	echo "No remote configured — skipped push. Add one with:"
	echo "  git -C \"$NOTES_ROOT\" remote add origin <url>"
fi
