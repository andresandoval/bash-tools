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
  lib/refront.py                       #   in-place frontmatter value rewrite (for --rename)
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
add-notes PATH [--title TEXT] [--from FILE | --from-clipboard] [--no-push]
add-notes --delete PATH [--no-push]
add-notes --rename OLD NEW [--no-push]
add-notes --rebuild [--no-push]
```

- `PATH` = your own freeform, multi-level structure. `garagehub/daily-standup` →
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
  (`Delete note: <path>`). Confirmation prompt; `ADD_NOTES_DELETE=yes|no` skips it.
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
- `--rebuild` = force-redeploy `.web/` from the tool template (ignores the
  `.tool-version` gate, so it also repairs a modified `.web`), rebuild the index,
  commit (`Rebuild notes web UI (tool version X)`). No note involved. Uncommitted
  changes confined to `.web/` are tolerated — that is the repair case, and rebuild
  overwrites them anyway; dirt anywhere else still aborts.
- The three modes are mutually exclusive; `--rebuild`/`--delete` reject PATH,
  source flags, and `--title`. `--no-push` applies to all modes.
- `--no-push` (or `ADD_NOTES_NO_PUSH=1`) commits without pushing. `--version`, `-h/--help`.
- Env overrides for non-interactive runs: `ADD_NOTES_INIT=yes|no`,
  `ADD_NOTES_ON_EXISTING=override|append|cancel`, `ADD_NOTES_DELETE=yes|no`.

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
   a remote/upstream exists (`commit_and_push`, shared by all three modes).

Delete mode runs the same preconditions (repo root, clean tree, identity), then
confirms, removes the file, prunes now-empty parent dirs, reindexes, and commits.
Rename mode runs the preconditions, moves the file (creating target dirs, pruning
emptied source dirs), refreshes frontmatter (`refront.py`), reindexes, and commits.
Rebuild mode runs the preconditions, force-deploys `.web/`, reindexes, and commits.

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
- **Entry titles live in frontmatter `label`, not `title`** — `title` already stores
  the pre-slug folder-path text on every existing note (and the index ignores it), so
  reusing it would have made old notes display their folder path as a title. A new key
  means zero migration; titles never affect sort order.
- **Flags, not subcommands** (`--rebuild`, `--delete`) — keeps `PATH` fully freeform
  with no reserved words.

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
