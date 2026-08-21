# meeting-notes — design spec

Specification and design record for the `meeting-notes` tool. Keep this document in sync
when the tool's interface or behavior changes (and add a README §9 changelog row).

## What the tool is

`meeting-notes` is a bash-tools command that captures AI meeting notes as clean Markdown in
whatever directory you run it in (that directory becomes a git-backed notes repo), and
deploys a self-contained static search/browse web UI into it. It was originally built
inside a single notes repo and then **decoupled** into this repo (`bash-tools`) so it
installs on `PATH` and can be used across many independent notes repos.

## Where everything lives (in this repo)

```
tools/meeting-notes.sh                     # entry point → the `meeting-notes` command
tools/meeting-notes/                       # support assets (NOT scanned as a command by setup.sh)
  lib/clean_md.py                      #   deterministic Markdown cleanup + frontmatter (stdlib)
  lib/html2md.py                       #   rich-clipboard HTML → Markdown (stdlib html.parser)
  lib/build_index.py                   #   walks notes → writes <repo>/.web/notes-data.js
  lib/refront.py                       #   in-place frontmatter value rewrite (--rename/--retitle)
  web/                                 #   .web TEMPLATE deployed into each notes repo
    index.html  app.js  styles.css  vendor/marked.min.js
functions/meeting-notes-completion.bash    # auto-sourced tab-completion (cwd-aware path drill-down)
README.md  §5 "meeting-notes"              # user docs
```

Installed via `./setup.sh` (select `meeting-notes` + `meeting-notes-completion`): a symlink
at `~/.local/bin/bash-tools/meeting-notes` → `tools/meeting-notes.sh`, and the completion sourced
from the managed `~/.local/bin/bash-tools/.bashrc`.

## Command interface

```
meeting-notes --add PATH [--title TEXT] [--from FILE | --from-clipboard] [--no-push] [--no-preview]
meeting-notes --delete PATH [--no-push] [--no-preview]
meeting-notes --rename OLD NEW [--no-push]
meeting-notes --retitle PATH TEXT [--no-push]
meeting-notes --rebuild [--no-push]
```

Exactly one mode flag is required. There are **no positional arguments**: a bare word
is rejected with `unexpected argument: X (use --add PATH to add a note)`, and finishing
argument parsing with no mode set prints `a mode flag is required (--add, --delete,
--rename, --retitle, or --rebuild).` followed by the full help on stderr, exit **1**. Only
`-h/--help` and `--version` exit 0 without doing work.

- `--add PATH` = add a note. `PATH` is your own freeform, multi-level structure
  (`--add=PATH` also works). `garagehub/daily-standup` →
  `garagehub/daily-standup/<today mmm-dd-yyyy>.md`. If `PATH` ends in `.md`
  (`garagehub/daily/jun-12-2026.md`) that exact filename is used (backfill past notes).
- Each folder segment is **slugified**; the original text is kept in the note's
  frontmatter `title`.
- `--title TEXT` = optional entry title, stored as frontmatter `label` and shown by
  the web UI as `date — title`; also searchable. When appending to an existing note,
  the title goes into the section heading (`## Added HH:MM — TEXT`) instead.
- Source: `--from FILE`, or `--from-clipboard` (the default). Mutually exclusive.
- `--delete PATH` = remove one note file (literal path, or its slugified form as a
  fallback), prune emptied parent dirs, rebuild the index, commit
  (`Delete note: <path>`). Confirmation prompt; `MEETING_NOTES_DELETE=yes|no` skips it.
  Refuses non-`.md` paths and anything under `.git`/`.web`.
- `--rename OLD NEW` = move/rename one note. OLD resolves like `--delete`
  (literal, then slugified). NEW ending in `.md` is the exact target (segments +
  stem slugified); otherwise NEW is a destination folder and the file keeps its
  name. Refuses to overwrite an existing target (no confirmation prompt — a
  rename is reversible). Frontmatter is refreshed via `lib/refront.py`: `title`
  always follows the new location; `date` is rewritten only when the filename
  stem changed (the index prefers frontmatter `date` over the filename); `label`,
  `created`, and unknown keys are preserved byte-for-byte. Then prune emptied
  dirs, reindex, commit (`Rename note: OLD -> NEW`). Takes two arguments, so
  there is no `--rename=` form.
- `--retitle PATH TEXT` = set one note's entry title (frontmatter `label`, the
  same key `--add --title` writes) without moving the file. PATH resolves like
  `--delete`; empty TEXT is rejected. Only `label` is rewritten — `title`, `date`,
  and `created` still describe the note's unchanged location. `refront.py`
  *inserts* `label` when the note has none, so notes predating `--title` gain one
  rather than silently keeping no title. No confirmation prompt (reversible, as
  `--rename`). Then reindex and commit (`Retitle note: PATH -> TEXT`). Takes two
  arguments, so there is no `--retitle=` form; TEXT is read positionally because
  it is free text that may legitimately begin with `-`.
- `--rebuild` = force-redeploy `.web/` from the tool template (ignores the
  `.tool-version` gate, so it also repairs a modified `.web`), rebuild the index,
  commit (`Rebuild notes web UI (tool version X)`). No note involved. Uncommitted
  changes confined to `.web/` are tolerated — that is the repair case, and rebuild
  overwrites them anyway; dirt anywhere else still aborts.
- The five modes are mutually exclusive and may each be given only once;
  `--rebuild`/`--delete`/`--rename`/`--retitle` reject the source flags and
  `--title`; `--rebuild`/`--rename`/`--retitle` also reject `--no-preview`.
  `--no-push` applies to all modes.
- `--no-push` (or `MEETING_NOTES_NO_PUSH=1`) commits without pushing. `--version`, `-h/--help`.
- `--no-preview` (or `MEETING_NOTES_NO_PREVIEW=1`) suppresses the content preview in
  the two modes that show one (`--add`, `--delete`). The env var never trips the
  mode check — only the explicit flag does, so exporting it does not break
  `--rebuild`/`--rename`.
- Env overrides for non-interactive runs: `MEETING_NOTES_INIT=yes|no`,
  `MEETING_NOTES_ON_EXISTING=override|append|cancel`, `MEETING_NOTES_DELETE=yes|no`,
  `MEETING_NOTES_NO_PREVIEW=1`.

## Runtime behavior

1. Preflight deps: `python3`, `git` (fails clean with install hints).
2. cwd must be the **git repo root** (subdir → error). If not a git repo, prompts to
   `git init`; if already tracked, the working tree must be **clean**.
3. Verifies a usable git identity (`git var GIT_AUTHOR_IDENT`) before writing anything.
4. Deploys/refreshes `.web/` from the tool template, staleness-tracked by the tool's
   `git describe` vs `<repo>/.web/.tool-version`.
5. Reads content: `--from` file, else clipboard **HTML-first** (converted via
   `html2md.py`, clipboard2markdown-style) with plain-text fallback.
6. Cleans (`clean_md.py`), writes note with frontmatter, prompts on same-file collision
   (override/append/cancel), rebuilds `.web/notes-data.js`, commits, and pushes only if
   a remote/upstream exists (`commit_and_push`, shared by all five modes).
7. Prints a content preview last, after the commit/push output (see *Content preview*).

Delete mode runs the same preconditions (repo root, clean tree, identity), then previews
the note, confirms, removes the file, prunes now-empty parent dirs, reindexes, and
commits.
Rename mode runs the preconditions, moves the file (creating target dirs, pruning
emptied source dirs), refreshes frontmatter (`refront.py`), reindexes, and commits.
Retitle mode runs the preconditions, resolves the note, rewrites `label`
(`refront.py`), reindexes, and commits — nothing moves and no content changes.
Rebuild mode runs the preconditions, force-deploys `.web/`, reindexes, and commits.

Clipboard is cross-platform: WSL/Windows `powershell.exe Get-Clipboard` (forced UTF-8
output), macOS `pbpaste`, Linux `wl-paste`/`xclip`/`xsel`. HTML flavor uses
`Get-Clipboard -TextFormatType Html` / `wl-paste -t text/html` / `xclip -t text/html`.

## Content preview

`--add` prints an excerpt of the note after the commit/push output; `--delete` prints one
before the confirmation prompt. Two helpers in the entry script do the work:

- `strip_frontmatter` — drops the leading `---`…`---` block. A `---` *inside* the body
  (a horizontal rule) survives: the flag clears at the closing delimiter, so later
  matches fall through to `print`.
- `preview_body LABEL` — renders the excerpt from stdin, `LABEL` supplying the leading
  verb (`Added` / `About to delete`). One `awk` pass; no new dependency.

Shape: a `LABEL N lines, M words:` header, then `PREVIEW_HEAD` (5) lines, a
`⋮ K more lines` marker, then `PREVIEW_TAIL` (3) lines. Blank lines are skipped
entirely — counting them would crowd out real content in a short excerpt — so all three
counts are of non-blank lines and `head + K + tail == N` always reconciles. At or below
`HEAD + TAIL` lines the whole body prints with no marker. Long lines are clipped to the
terminal width (`tput cols`, minus 4) or 100 when stdout is not a TTY, with a trailing
`…`. Empty or whitespace-only input prints nothing at all.

Sources, chosen so the preview always reflects what actually landed on disk:

| Case | Previewed |
|------|-----------|
| new note / override | `cleaned_with_fm` piped through `strip_frontmatter` |
| append | `APPENDED_BODY` — only the new section |
| delete | the target file piped through `strip_frontmatter` |

The new-note case strips frontmatter from the already-computed `cleaned_with_fm` rather
than re-running `clean_md.py`: one less `python3` invocation, and byte-identical to the
file by construction (`clean_md.py` emits `frontmatter(...)` followed by the same
`clean_body(...)` in both cases).

`append_section` keeps its body in the global `APPENDED_BODY` (not a `local`) purely so
this preview can show only the appended section. The generated `## Added HH:MM` heading
is *not* previewed — it is metadata the tool wrote, not content the user supplied, so it
is excluded for the same reason frontmatter is.

## Shared note lookup

`--delete`, `--rename`, and `--retitle` all accept either the literal path or its
slugified form. That two-step lookup lives in one helper, `resolve_note_rel`, which
echoes the resolved repo-relative path and returns 1 when neither form exists (each
caller prints its own `note not found` message). The path guards (relative-only, no
`..`, nothing under `.git`/`.web`, `.md` only) stay per-mode, because their error
wording names the mode.

## Design decisions on record

- **Slugified path segments** — folder names are normalized; the human-readable text
  lives in frontmatter `title`.
- **Clipboard is the default source**, HTML-first with plain-text fallback.
- **Run-at-root requirement** — the tool refuses to run from a subdirectory of the
  notes repo, so notes and `.web/` always land at the repo root.
- **`.web` is shipped from the tool** and version-gated per notes repo via
  `.web/.tool-version`, so UI updates propagate on next use without manual steps.
- **The tool writes nothing into this repo** — it operates on the user's working
  directory only (bash-tools' immutable-repo principle).
- **Sidebar notes sort chronologically, newest first** — `mmm-dd-yyyy` dates are parsed
  (not string-compared, which would order by month name); undated notes sort last.
  Folders remain alphabetical.
- **Entry titles live in frontmatter `label`, not `title`** — `title` already stores
  the pre-slug folder-path text on every existing note (and the index ignores it), so
  reusing it would have made old notes display their folder path as a title. A new key
  means zero migration; titles never affect sort order.
- **A content preview beats a browser round-trip** — a failed `Ctrl+X`/`Ctrl+C` used to
  commit the *previous* clipboard silently, and the only way to catch it was to serve
  `./.web` (e.g. `lite-server`) and find the entry in a browser. A head+tail excerpt in
  the terminal answers the same question, so that loop is gone. `--delete` shows one too:
  "am I removing the right note?" is the same question, and the prompt previously offered
  nothing but a path. It is skipped when `MEETING_NOTES_DELETE` preapproves the prompt —
  with no question being asked, a preview informs nothing. `--rename` (content unchanged)
  and `--rebuild` (no note involved) show nothing, and reject `--no-preview` as
  meaningless — `--retitle` likewise (it changes one frontmatter value, not the body).
- **Retitling is its own mode, not `--title` on `--rename`** — a file's path and
  its display label are different things, and folding them together would mean
  either typing the path twice (`--rename X X --title T`) or dropping the
  `OLD == NEW` guard that catches rename typos. A separate `--retitle` keeps both
  modes single-purpose; move-and-retitle is two commands, both cheap commits.
- **`refront.py` inserts a missing targeted key** rather than skipping it, at the
  canonical position `clean_md.py` writes (`title`, `label`, `date`, `created`).
  Without this, `--retitle` would silently no-op on every note added before
  `--title` existed — exactly the notes most likely to need a title. It also lets
  a date-fix rename repair a note whose frontmatter lacks `date`.
- **Flags, not subcommands** (`--add`, `--rebuild`, `--delete`, `--rename`,
  `--retitle`) — keeps `PATH` fully freeform with no reserved words.
- **Every mode is an explicit flag, including `--add`** — the tool was originally
  named `add-notes` with adding as the implicit default and `PATH` positional. The
  rename to `meeting-notes` (2026-07-28) names the domain rather than one verb, so
  adding became `--add PATH` alongside the other three modes. A missing mode flag is
  an error rather than a help-and-exit-0, because it means an incomplete command
  rather than a request for help. Dropping the positional argument also removed the
  parser's "is this bare word a PATH or a stray token?" ambiguity.
- **The `ADD_NOTES_*` env vars were renamed to `MEETING_NOTES_*` with no fallback** —
  a silent fallback would leave two names live indefinitely; this is a personal tool
  with a known set of callers.
- **Resizable sidebar with horizontal scroll** — a drag divider between the tree
  and the content pane resizes the panel (width clamped to [160px, 60vw], persisted
  in `localStorage["notes-sidebar-w"]`, double-click resets); tree rows use
  `width: max-content` so long names overflow into the sidebar's horizontal
  scrollbar instead of being ellipsized.

## Known considerations / extension points

- **git identity is per-repo, not global** on some setups — a freshly seeded notes repo
  needs an identity or the commit step errors (by design, with a hint). Consider a
  global identity if you seed many repos.
- **Encoding handling is WSL/PowerShell-specific** where it matters: non-ASCII
  round-trips correctly and nbsp is normalized to spaces; Wikipedia-style `[n]`
  reference superscripts (incl. the `[[1]](#cite_note-1)` form) are stripped, real
  links kept. Other site-specific cruft (e.g. `[edit]` links) is NOT special-cased —
  extend `clean_md.py`/`html2md.py` if needed.

## How to test quickly

```bash
tmp=$(mktemp -d); cd "$tmp"
printf '# T\n\n- a\n- b\n' > /tmp/raw.md
MEETING_NOTES_INIT=yes meeting-notes --add demo/team/standup --from /tmp/raw.md --no-push
# the preview after "Committed." should show the note's first/last lines
# open ./.web/index.html in a browser to see the tree UI
```

The `--delete` preview needs a real TTY (it reads the prompt from `/dev/tty`), so pipe
into a pty rather than into the command:

```bash
printf 'n\n' | script -qec "meeting-notes --delete demo/team/standup/<date>.md" /dev/null
```

Headless render check (WSL): point Windows Chrome at `.web/index.html` via
`wslpath -w` with `--headless=new --screenshot`.
