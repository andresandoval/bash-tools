# Design — rename `add-notes` to `meeting-notes`, require a mode flag

Date: 2026-07-28
Status: approved

## Goal

Rename the `add-notes` tool to `meeting-notes`, and make its four operations
explicit, mutually exclusive mode flags. Adding a note now requires `--add PATH`;
invoking the tool with no mode flag prints the help with an error explaining that a
flag is missing.

The change is interface-only. Note storage, frontmatter, the `.web` search UI, the
index format, and the git commit/push behavior are untouched.

## Motivation

`add-notes` reads as "add", so its non-adding modes (`--delete`, `--rename`,
`--rebuild`) fight the name. `meeting-notes` names the domain instead of one verb,
and a required `--add` puts adding on equal footing with the other three modes. A
bare positional `PATH` becomes an error, which removes the "did I mean to add or to
target something?" ambiguity from the argument parser.

## File renames

All renames use `git mv` so history follows the files.

| From | To |
|------|-----|
| `tools/add-notes.sh` | `tools/meeting-notes.sh` |
| `tools/add-notes/` (contains `lib/`, `web/`) | `tools/meeting-notes/` |
| `functions/add-notes-completion.bash` | `functions/meeting-notes-completion.bash` |
| `.docs/dev/add-notes.md` | `.docs/dev/meeting-notes.md` |

The command name is derived by `setup.sh` from the filename, so
`tools/meeting-notes.sh` becomes the `meeting-notes` command with no change to
`setup.sh` itself. The sibling asset directory keeps matching the entry script's
stem, so it stays invisible to the scanner.

No compatibility shim is kept. The next `./setup.sh` run prunes the stale
`add-notes` entry from `~/.local/bin/bash-tools/` (and its `source` line for the
completion function) and installs the renamed pair, provided both are selected.

## CLI surface

```
meeting-notes --add PATH [--title TEXT] [--from FILE | --from-clipboard] [--no-push]
meeting-notes --delete PATH [--no-push]
meeting-notes --rename OLD NEW [--no-push]
meeting-notes --rebuild [--no-push]
meeting-notes --version
meeting-notes -h | --help
```

`--add` takes the destination path as its own argument, in both `--add PATH` and
`--add=PATH` forms, mirroring `--delete PATH`. `PATH` keeps its current semantics
exactly: a freeform multi-level path whose segments are slugified, where a trailing
`.md` segment sets the exact filename and anything else appends `<date>.md`.

### Mode handling

`MODE` starts empty rather than defaulting to `add`. `--add`, `--delete`,
`--rename`, and `--rebuild` each set it and each guard against an already-set mode,
so `--add` participates in the existing mutual-exclusion error, whose message
becomes:

```
Error: --add, --rebuild, --delete, and --rename are mutually exclusive (and may be
given only once).
```

### Positional arguments

There are no positional arguments left. Any bare word is an error:

```
Error: unexpected argument: X (use --add PATH to add a note)
```

This replaces the old branch that assigned the first bare word to `DEST_PATH`.

### Missing mode flag

When parsing finishes with `MODE` still empty — including a bare `meeting-notes`
with no arguments at all, and `meeting-notes --no-push` — the tool prints to stderr:

```
Error: a mode flag is required (--add, --delete, --rename, or --rebuild).
```

followed by a blank line and the full help, and exits **1**. This replaces the old
zero-argument path, which printed the help and exited 0.

`-h`/`--help` and `--version` are handled during parsing and still exit **0** with
output on stdout.

### Flags scoped to `--add`

`--title`, `--from`, and `--from-clipboard` remain valid only with `--add`. The
existing post-parse validation is retained, now keyed on the new mode value, so
e.g. `meeting-notes --rebuild --title X` still fails with:

```
Error: --rebuild does not accept: --title
```

The `PATH` entry is dropped from that check's list, because a stray path can no
longer reach it — it is rejected earlier as an unexpected argument.

`--no-push` stays valid in every mode.

## Environment variables

Renamed to match the command, with no fallback to the old names:

| Old | New |
|-----|-----|
| `ADD_NOTES_INIT` | `MEETING_NOTES_INIT` |
| `ADD_NOTES_NO_PUSH` | `MEETING_NOTES_NO_PUSH` |
| `ADD_NOTES_DELETE` | `MEETING_NOTES_DELETE` |
| `ADD_NOTES_ON_EXISTING` | `MEETING_NOTES_ON_EXISTING` |

Their accepted values and effects are unchanged.

## Tab completion

`functions/meeting-notes-completion.bash`:

- Function renamed `_add_notes_complete` → `_meeting_notes_complete`; the
  registration becomes `complete -o default -F _meeting_notes_complete meeting-notes`.
- `--add` is added to the completed flag list.
- `--add`'s value completes directories under the cwd with a trailing slash and
  `nospace`, so drilling through a structure with Tab works as the positional `PATH`
  did. This is the same logic the positional branch used, moved behind
  `[ "$prev" = "--add" ]`.
- The positional-`PATH` branch and its `have_path` scan are removed, since there is
  no positional argument to complete.
- `--delete` and `--rename` keep completing `.md` files (and directories, to drill
  through), skipping `.git`/`.web`. `--rename`'s second argument still falls through
  to directory completion — which, with the positional branch gone, is provided by
  the trailing directory-completion block that now serves as the default.

## Other references to update

In `tools/meeting-notes.sh`:

- `ASSET_DIR="$TOOLS_DIR/meeting-notes"`.
- The header comment and `usage()` text, including every example.
- User-facing strings that name the command: the "must be run from the root of the
  git repository" error, the "commits each note on its own" hint, and the
  "or pass a file: …" clipboard hint.

Elsewhere:

- `tools/meeting-notes/lib/build_index.py`, `clean_md.py`, `refront.py` — docstring
  and comment mentions of `add-notes` / `add-notes --title` / `add-notes --rename`.
- `tools/meeting-notes/web/app.js` — the empty-state string becomes
  `No notes yet. Add one with <code>meeting-notes --add &lt;path&gt;</code>.`
- `.docs/dev/meeting-notes.md` — the tool's design spec, updated for the new name,
  the `--add` flag, the missing-flag behavior, and the renamed env vars.
- `AGENTS.md` — the inventory table rows, the multi-file-tools paragraph, and the
  `.docs/dev/` pointer.
- `CLAUDE.md` — the `.docs/dev/` example filename.
- `README.md` — the repository tree, the multi-file-tool callout, the tools table,
  the tool's own usage section, the functions table, and a new §9 changelog row
  dated 2026-07-28.

Deliberately left unchanged: `.docs/superpowers/plans/2026-07-24-setup-hints.md`
and `.docs/superpowers/specs/2026-07-24-setup-hints-design.md`. They mention
`tools/add-notes.sh.hint` as an example, but they are records of a change already
made; editing them would misrepresent what was designed at the time.

Note repositories created by the old tool need no migration: the deployed `.web`
directory, `.web/.tool-version`, and note frontmatter contain no reference to the
command name. Because `.tool-version` records the bash-tools git description, the
first post-rename run redeploys `.web` normally, picking up the new empty-state
string.

## Verification

1. `bash -n tools/meeting-notes.sh` and
   `bash -n functions/meeting-notes-completion.bash`.
2. In a scratch directory outside the repo, exercise the script by its repo path
   (`/path/to/bash-tools/tools/meeting-notes.sh`) so no `setup.sh` run is needed —
   the script resolves its own assets, so this behaves like the installed command.
   Written below as `meeting-notes` for brevity:
   - `meeting-notes` → missing-flag error + help on stderr, exit 1.
   - `meeting-notes garagehub/standup` → unexpected-argument error, exit 1.
   - `meeting-notes --add X --delete Y` → mutual-exclusion error.
   - `meeting-notes --rebuild --title X` → does-not-accept error.
   - `meeting-notes --help` / `--version` → exit 0.
   - `MEETING_NOTES_INIT=yes meeting-notes --add garagehub/standup --from raw.md
     --no-push` in an empty dir → repo initialized, note written, `.web` deployed,
     index built, committed, push skipped.
   - `--add` the same path again with `MEETING_NOTES_ON_EXISTING=append` → appended
     section.
   - `--rename`, then `--delete` with `MEETING_NOTES_DELETE=yes`, then `--rebuild`.
   - Confirm the old `ADD_NOTES_NO_PUSH=1` no longer suppresses a push (it is
     ignored, so the no-remote message appears instead of "Skipped push").
3. Confirm no `add-notes` / `ADD_NOTES` occurrences remain outside the two
   historical `.docs/superpowers/` documents and the README changelog's past rows.
