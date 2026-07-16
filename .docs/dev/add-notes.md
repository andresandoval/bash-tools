# add-notes — design spec

Specification and design record for the `add-notes` tool. Keep this document in sync
when the tool's interface or behavior changes (and add a README §9 changelog row).

## What the tool is

`add-notes` is a bash-tools command that captures AI meeting notes as clean Markdown in
whatever directory you run it in (that directory becomes a git-backed notes repo), and
deploys a self-contained static search/browse web UI into it. It was originally built
inside a single notes repo and then **decoupled** into this repo (`bash-tools`) so it
installs on `PATH` and can be used across many independent notes repos.

## Where everything lives (in this repo)

```
tools/add-notes.sh                     # entry point → the `add-notes` command
tools/add-notes/                       # support assets (NOT scanned as a command by setup.sh)
  lib/clean_md.py                      #   deterministic Markdown cleanup + frontmatter (stdlib)
  lib/html2md.py                       #   rich-clipboard HTML → Markdown (stdlib html.parser)
  lib/build_index.py                   #   walks notes → writes <repo>/.web/notes-data.js
  web/                                 #   .web TEMPLATE deployed into each notes repo
    index.html  app.js  styles.css  vendor/marked.min.js
functions/add-notes-completion.bash    # auto-sourced tab-completion (cwd-aware path drill-down)
README.md  §5 "add-notes"              # user docs
```

Installed via `./setup.sh` (select `add-notes` + `add-notes-completion`): a symlink at
`~/.local/bin/bash-tools/add-notes` → `tools/add-notes.sh`, and the completion sourced
from the managed `~/.local/bin/bash-tools/.bashrc`.

## Command interface

```
add-notes PATH [--from FILE | --from-clipboard] [--no-push]
```

- `PATH` = your own freeform, multi-level structure. `garagehub/daily-standup` →
  `garagehub/daily-standup/<today mmm-dd-yyyy>.md`. If `PATH` ends in `.md`
  (`garagehub/daily/jun-12-2026.md`) that exact filename is used (backfill past notes).
- Each folder segment is **slugified**; the original text is kept in the note's
  frontmatter `title`.
- Source: `--from FILE`, or `--from-clipboard` (the default). Mutually exclusive.
- `--no-push` (or `ADD_NOTES_NO_PUSH=1`) commits without pushing. `--version`, `-h/--help`.
- Env overrides for non-interactive runs: `ADD_NOTES_INIT=yes|no`,
  `ADD_NOTES_ON_EXISTING=override|append|cancel`.

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
   a remote/upstream exists.

Clipboard is cross-platform: WSL/Windows `powershell.exe Get-Clipboard` (forced UTF-8
output), macOS `pbpaste`, Linux `wl-paste`/`xclip`/`xsel`. HTML flavor uses
`Get-Clipboard -TextFormatType Html` / `wl-paste -t text/html` / `xclip -t text/html`.

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
ADD_NOTES_INIT=yes add-notes demo/team/standup --from /tmp/raw.md --no-push
# open ./.web/index.html in a browser to see the tree UI
```

Headless render check (WSL): point Windows Chrome at `.web/index.html` via
`wslpath -w` with `--headless=new --screenshot`.
