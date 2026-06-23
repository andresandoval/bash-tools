#!/usr/bin/env bash
#
# add-notes — store AI meeting notes as clean Markdown in the current directory,
# then commit (and push if a remote exists). The directory you run this in is the
# notes repository: it is git-initialized on demand and gets a self-contained
# `.web/` search UI deployed into it.
#
# Notes are saved to ./<project>/<meeting>/<date>.md, cleaned of AI cruft, with
# YAML frontmatter. Formatted (HTML) clipboard content is converted to Markdown
# automatically (clipboard2markdown-style); otherwise plain text is used.
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
Usage: add-notes PROJECT MEETING [PATH] [--no-push]

Store meeting notes as clean Markdown under ./<project>/<meeting>/<date>.md in the
current directory, then commit (and push if a remote is configured).

Arguments:
  PROJECT      Project name (e.g. "GarageHub"). Folder name is slugified.
  MEETING      Meeting name (e.g. "Daily Standup"). Folder name is slugified.
  PATH         Optional file with the raw notes. If omitted, the clipboard is
               read. Formatted (HTML) clipboard content is converted to clean
               Markdown automatically; otherwise plain text is used.

Options:
  --no-push    Commit but do not push (also via ADD_NOTES_NO_PUSH=1).
  --version    Print the tool version and exit.
  -h, --help   Show this help.

Behavior:
  - The current directory is the notes repo. If it is not a git repo you are
    asked to initialize one (skip the prompt with ADD_NOTES_INIT=yes|no); if it
    already is, the working tree must be clean.
  - A self-contained search UI is deployed/refreshed in ./.web (open index.html).
  - If today's file already exists you are asked to override, append, or cancel
    (override non-interactively with ADD_NOTES_ON_EXISTING=override|append|cancel).

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

# --- Clipboard helpers (only used when no file path is given) ---------------
clipboard_cmd() {
	if command -v powershell.exe >/dev/null 2>&1; then
		echo "powershell.exe -NoProfile -Command Get-Clipboard"
	elif command -v pbpaste >/dev/null 2>&1; then
		echo "pbpaste"
	elif command -v wl-paste >/dev/null 2>&1; then
		echo "wl-paste"
	elif command -v xclip >/dev/null 2>&1; then
		echo "xclip -selection clipboard -o"
	elif command -v xsel >/dev/null 2>&1; then
		echo "xsel -b"
	else
		return 1
	fi
}

read_clipboard_html() {
	if command -v powershell.exe >/dev/null 2>&1; then
		powershell.exe -NoProfile -Command "Get-Clipboard -TextFormatType Html" 2>/dev/null
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

# --- Git seeding: ensure the cwd is a clean notes repo ----------------------
ensure_notes_repo() {
	if git -C "$NOTES_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
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
POSITIONAL=()
for arg in "$@"; do
	case "$arg" in
	-h | --help)
		usage
		exit 0
		;;
	--version)
		tool_version
		exit 0
		;;
	--no-push) NO_PUSH=1 ;;
	*) POSITIONAL+=("$arg") ;;
	esac
done

PROJECT="${POSITIONAL[0]:-}"
MEETING="${POSITIONAL[1]:-}"
INPUT="${POSITIONAL[2]:-}"

if [ -z "$PROJECT" ] || [ -z "$MEETING" ]; then
	echo "Error: PROJECT and MEETING are required." >&2
	echo >&2
	usage >&2
	exit 1
fi

check_deps
ensure_notes_repo
check_git_identity
deploy_web_if_stale

# --- Resolve content --------------------------------------------------------
if [ -n "$INPUT" ]; then
	if [ ! -f "$INPUT" ]; then
		echo "Error: file not found: $INPUT" >&2
		exit 1
	fi
	content="$(cat "$INPUT")"
else
	html="$(read_clipboard_html || true)"
	if not_blank "$html"; then
		content="$(printf '%s' "$html" | python3 "$LIB/html2md.py")"
		echo "(converted rich clipboard HTML to Markdown)"
	else
		if ! cmd="$(clipboard_cmd)"; then
			echo "Error: no clipboard tool found. Install xclip or wl-clipboard," >&2
			echo "       or pass a file path: add-notes PROJECT MEETING PATH" >&2
			exit 1
		fi
		content="$(eval "$cmd" 2>/dev/null || true)"
	fi
fi

if ! not_blank "$content"; then
	echo "Error: no note content (file/clipboard was empty)." >&2
	exit 1
fi

# --- Compute paths ----------------------------------------------------------
DATE="$(date +%b-%d-%Y | tr '[:upper:]' '[:lower:]')"
CREATED="$(date +%Y-%m-%dT%H:%M:%S)"
TIME="$(date +%H:%M)"
PROJ_SLUG="$(slugify "$PROJECT")"
MEET_SLUG="$(slugify "$MEETING")"
DIR="$NOTES_ROOT/$PROJ_SLUG/$MEET_SLUG"
FILE="$DIR/$DATE.md"

cleaned_with_fm="$(printf '%s' "$content" | python3 "$LIB/clean_md.py" \
	--project "$PROJECT" --meeting "$MEETING" --date "$DATE" --created "$CREATED")"

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
		echo "A note already exists for today: ${FILE#"$NOTES_ROOT"/}"
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
git -C "$NOTES_ROOT" commit -q -m "Add notes: $PROJECT / $MEETING ($DATE)"
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
