# dev-env — design spec

Specification and design record for the `dev-env` tool. Keep this document in sync when
the tool's interface or behavior changes (and add a README §9 changelog row).

## What the tool is

`dev-env` manages the files a project needs but git does not track: `.env` files, local
config folders, seed scripts. You keep one **store** per project outside every checkout
(e.g. `~/Dev/environments/my-project`), describe the mapping once in a **manifest**, and
then apply that store to any checkout — a clone, a git worktree, or a plain directory
with the same shape.

The problem it removes: a new git worktree starts with none of these files, and copying
them by hand is slow and easy to get wrong. With `dev-env` the store is the single source
of truth, and every worktree points at it.

The tool never guesses which store to use. You name the store on every run.

## Where everything lives (in this repo)

```
tools/dev-env.sh                      # entry point → the `dev-env` command
functions/dev-env-completion.bash     # auto-sourced tab-completion
.docs/dev/dev-env.md                  # this spec
README.md  §5 "dev-env"               # user docs
```

Single-file bash tool: no `tools/dev-env/` asset directory and no Python. Dependencies are
`bash`, coreutils (`ln`, `cp`, `mv`, `rm`, `mkdir`, `readlink`), `diff` and `cmp`. `git` is
used only for two optional things: finding the worktree root, and the ignore report.

Installed via `./setup.sh` (select `dev-env` + `dev-env-completion`): a symlink at
`~/.local/bin/bash-tools/dev-env` → `tools/dev-env.sh`, and the completion sourced from the
managed `~/.local/bin/bash-tools/.bashrc`.

## Concepts

**Store** — a directory outside any project that holds the real files plus the manifest.
The tool writes into the store only on `adopt` and `pull`. It is your data; git-manage it
yourself if you want.

**Manifest** — `<store>/.manifest`. It maps each store file or folder to a path inside the
target.

**Target** — where the links go. Resolution order:

1. `--target DIR`, if given.
2. The git worktree root, when the current directory is inside a git working tree
   (`git rev-parse --show-toplevel`). This is what lets you run the tool from a
   subdirectory of a worktree.
3. The current directory, when it is not a git working tree.

Most commands print the store and the target they resolved before doing anything else.
`diff` never prints them, and `pull` prints them only once it has found something to do.

**Store argument** — `STORE` is a path when it contains `/` or starts with `~`, `.` or `/`.
Otherwise it is a name resolved under `$DEV_ENV_HOME` (default `~/Dev/environments`), so
`dev-env apply my-project` means `~/Dev/environments/my-project`. If the resolved path is a
directory, the manifest is `<dir>/.manifest`; if it is a file, that file is the manifest and
its directory is the store root.

## Manifest format (version 1)

```ini
# dev-env manifest — my-project
version = 1

[link]
source = root-module.env
dest   = /.env

[link]
source = auth-service.env
dest   = /auth/.env

[link]
source = some-folder
dest   = /.some-folder

[copy]
source = seed.sh
dest   = /scripts/seed.sh

[link]
source = web-local.env
dest   = /web/.env
optional = true
```

### Syntax rules

- `version = N` is required, appears exactly once, and comes before the first section.
  Only version `1` is supported; anything else is an error. This is the growth guard — a
  future format change is detected, never misread.
- A section header is the directive: `[link]` (absolute symlink) or `[copy]` (real copy).
  An unknown directive is an error with its line number.
- Keys inside a section: `source` (required), `dest` (required), `optional`
  (`true`/`false`, default `false`).
- A line whose first non-blank character is `#` is a comment. `#` inside a value is **not**
  a comment — filenames may contain it.
- Whitespace around `=`, and at both ends of a value, is trimmed. There is no quoting and
  no escaping in version 1: a name with a leading or trailing space is not supported.
- Blank lines are ignored.

### Value rules

- `source` is relative to the store root. Absolute paths, an empty value, and any `..`
  segment are errors. It may be flat (`auth-service.env`) or nested (`auth/.env`) — the
  store layout is your choice.
- `dest` starts with `/`, which means the target root. Any `..` segment is an error. A
  trailing `/` is stripped. `dest` must name a path inside the target root (not the root
  itself: `/.` or `dest = /` is an error with "must name a path inside the target root").
- Both are normalized and must stay inside their root.

### Rejected manifests

Every one of these fails the whole run with the line number, before anything is written:

- an unknown key, an unknown directive, a missing `source` or `dest`;
- a duplicate key inside one section;
- an `optional` value that is not `true` or `false`;
- the same `dest` in two entries (naming both lines);
- a `dest` that is a path prefix of another `dest` (e.g. `/auth` and `/auth/.env`) —
  linking a directory and something inside it is undefined;
- a missing or unsupported `version`.

The same `source` in two entries is allowed: one store file may feed two places.

Entries keep manifest order in every report.

## Command interface

```
dev-env apply  STORE [--force-dir] [--dry-run] [--force] [--target DIR]
dev-env status STORE [--target DIR]
dev-env diff   STORE [PATH...] [--target DIR]
dev-env pull   STORE [PATH...] [--yes] [--target DIR]
dev-env remove STORE [--restore] [--force] [--target DIR]
dev-env adopt  STORE PATH... [--as NAME] [--mode copy] [--target DIR]
```

A command is required and comes first, as in `meeting-notes`: it is read before anything
else, and everything after it is parsed as that command's arguments and options. A word in
the command position that is not one of the six is rejected with `unknown command: X
(expected apply, status, diff, pull, remove, or adopt)`. No arguments at all prints `a
command is required (apply, status, diff, pull, remove, or adopt).` followed by the overview
help on stderr, exit **1**.

Help is per command: `dev-env --help` lists the commands, `dev-env <command> --help` prints
that command's arguments, options and examples. `--help` also stands in for a missing
argument, so `dev-env apply --help` works. `--version` prints the bash-tools version.

Options may appear before or after the positional arguments.

### apply

Create every link and copy the manifest describes.

- `--force-dir` creates missing parent directories in the target instead of failing. This
  is the seed case: an empty directory becomes a working checkout shape.
- `--dry-run` prints the same per-entry plan and writes nothing.
- `--force` overwrites a drifted copy (see "Drift" below) after backing it up.

### status

Read-only. Prints one classified line per entry, then the ignore report. Writes nothing.

### diff

Unified diff for `copy` entries, store version against target version: `diff -u` for files,
`diff -ru` for directories, labelled `store/<source>` and `target/<dest>`. With no `PATH`
arguments it covers every copy entry; identical entries print nothing.

`PATH` selects entries. It matches an entry's `dest` (with or without the leading `/`) or its
`source`. An argument that matches nothing is an error. When the same entry is named twice on
the command line (e.g. `dev-env diff store /.env .env`), it is selected once.

Exit 2 when the `diff` utility itself fails (e.g. unreadable file). Exit 1 when differences
are found. Exit 0 when there are none.

### pull

Copy the target version back into the store — the merge-back direction. Only `copy` entries
qualify; a `link` entry is rejected with `a link entry needs no pull: <dest>`, because both
sides are already the same file.

With no `PATH` arguments it offers every drifted copy entry. It lists what will change, asks
once for confirmation, and then backs up each store version to `<source>.dev-env.bak` before
overwriting it. `--yes` (or `DEV_ENV_PULL=yes`) skips the prompt; `DEV_ENV_PULL=no` answers
no.

A `pull` replaces its own previous backup: an existing `<source>.dev-env.bak` is removed
right before the new one is written, because it holds the store version from an earlier
pull, not a user file. `apply` and `remove --restore` keep the ordinary refusal — there the
backup holds something the user had in the way.

A selected entry whose target `dest` is missing, or is a symlink (never a managed copy), is
not pulled; it is listed under "Not pulled" with the reason, the same way `diff` reports it.

**Duplicate source guard:** If two selected entries resolve to the same store file, `pull`
exits 1 with `two entries pull into the same store file: <source>` and lists both target
destinations. A single store file cannot accept two different target versions at once.

### remove

Delete what this store owns in the target.

- A `link` entry whose `dest` is a symlink resolving to this store's `source` is removed.
- A `copy` entry whose `dest` is identical to the store version is removed.
- A drifted copy is **kept** and reported as differing from the store, unless `--force`.
  Run `diff` or `pull` first. With `--force`, it is removed and reported with the note
  `--force: content differed from the store`.
- Anything else is kept and reported as foreign. The tool never deletes what it does not own.
- `--restore` moves each `<dest>.dev-env.bak` back into place after the removal.

Directories that `--force-dir` created are not tracked, so they are not pruned. An emptied
directory is reported, not removed.

### adopt

Move files that already exist in the target into the store, add manifest entries, and link
them back. This is how a store is built the first time.

- Each `PATH` is relative to the target root (a leading `/` is optional). If absolute, it
  must be inside the target root; absolute paths outside it are rejected with `not inside
  the target root: <path>`.
- Duplicate `PATH` arguments in a single run are rejected with `given twice in one run: <path>`.
  A separate check rejects two paths using the same store name with `two paths would use the
  same store name: <name>`. The second check cannot trigger through the current interface:
  `--as` takes only one `PATH`, and every store name mirrors its own path, so different
  paths always produce different names. It remains as a guard for a future option that lets
  multiple paths choose their own store names.
- The default store name mirrors the path: `/auth/.env` → `auth/.env`, `/.env` → `.env`.
  `--as NAME` sets a flat name instead (`auth-service.env`), and is allowed only with exactly
  one `PATH`. The `NAME` is validated with the same rules as manifest `source`: relative
  (no leading `/`), and no `..` segment. A `/` inside the name is still allowed because it
  mirrors the destination structure. Mirroring keeps the leading dot, so `/.some-folder`
  becomes a hidden entry in the store; use `--as some-folder` when you want the store to be
  readable with plain `ls`.
- `--mode copy` records a `[copy]` entry: the file is copied into the store and the original
  stays where it is. The default (`link`) moves the file into the store and symlinks it back.
- It refuses when the `dest` is already in the manifest, or when the store `source` path is
  already taken.
- It creates the store directory and a `version = 1` manifest when they do not exist, and
  says so.
- The new block is appended to the end of the manifest, after a blank line.

## Runtime behavior

### Preflight — all or nothing

`apply` validates everything before it writes anything. If any check fails it prints every
problem at once and exits 1 without touching the target.

1. The store root exists; the manifest exists, is readable, and parses; the version is
   supported.
2. The target root exists, is a directory, and is writable.
3. Each `source` exists in the store. A missing required source is an error; a missing
   `optional = true` source marks the entry skipped.
4. The parent directory of each `dest` exists in the target. **This is the structure check**
   — it is what catches the wrong store or the wrong project. `--force-dir` turns it into a
   "will create" line instead.
5. For any `dest` that needs a backup, `<dest>.dev-env.bak` must not already exist. A taken
   backup path is an error naming the file, because a silent second backup would hide a
   leftover from an earlier run.

### apply — per entry

| Situation | Action | Report |
|---|---|---|
| `link`, dest missing | create absolute symlink | `linked` |
| `link`, dest is our symlink | nothing | `ok` |
| `link`, dest is anything else | move to `<dest>.dev-env.bak`, then link | `backup + linked` |
| `copy`, dest missing | `cp -R` preserving mode | `copied` |
| `copy`, dest identical to store | nothing | `ok` |
| `copy`, dest differs (drift) | nothing, unless `--force` → backup then copy | `drift` |
| `copy`, dest is a symlink | move to `<dest>.dev-env.bak`, then copy | `backup + copied` |
| source missing, `optional = true` | nothing | `skipped` |

A copy entry's `dest` is **identical** when `cmp -s` reports no difference (files) or
`diff -rq` reports none (directories). A `dest` that is a symlink is never a managed copy,
so it is backed up like any other obstacle.

Re-running is cheap and idempotent: everything already in place reports `ok`.

### Drift

A `copy` entry whose target version differs from the store version is **drift**. `apply`
never discards it on its own, because that difference may be the change you want to merge
back. The workflow is `dev-env diff` → `dev-env pull`, or `dev-env apply --force` to throw the
target version away (backed up first).

`link` entries cannot drift: the two paths are the same file.

### status — classifications

One per entry, in manifest order:

- `ok` — the link resolves to the store source, or the copy is identical.
- `missing` — `dest` does not exist.
- `drift` — copy entry, `dest` differs from the store.
- `foreign` — `dest` exists but this store does not own it: a link entry pointing at a real
  file, a directory, or a link elsewhere; or a copy entry whose `dest` is a symlink.
- `stale-source` — the `source` is gone from the store (`skipped` when the entry is optional).
- `no-parent` — the parent directory of `dest` does not exist in the target.

`backup` is appended to the line when `<dest>.dev-env.bak` exists.

### Git ignore report

`apply` prints it after its work, and `status` prints it always. It never edits a git file.

When the target is a git working tree, each existing `dest` is tested with
`git -C <target> check-ignore -q -- <relpath>`. Paths git does not ignore are listed with the
exact command to fix it, using the shared exclude file resolved through
`git rev-parse --git-common-dir` (linked worktrees share it with the main repository):

```
Not ignored by git:
  .env
  auth/.env

Add them locally (not committed):
  printf '%s\n' '/.env' '/auth/.env' >> /path/to/repo/.git/info/exclude
```

### Exit codes

| Command | 0 | 1 | 2 |
|---|---|---|---|
| `apply` | every entry applied or already `ok` | any error, or an entry left unapplied (drift without `--force`) | manifest has no entries |
| `status` | every entry `ok` or `skipped` | any other classification, or an error | — |
| `diff` | no differences | differences found | error (bad usage, unreadable file) |
| `pull` | pulled, or nothing to pull | any error, or the prompt was answered no | usage error (no entry matches, or a link entry was named) |
| `remove` | removed what it owns | any error | — |
| `adopt` | adopted | any error | — |

`apply` returns 1 on drift because the target does not match the store when it finishes.
The drift line names the commands that resolve it.

`diff` follows the `diff` convention on purpose: "differences found" is not a failure, and 2
is the error code.

### Environment variables

- `DEV_ENV_HOME` — store root for bare-name lookup. Default `~/Dev/environments`.
- `DEV_ENV_PULL=yes|no` — answer the `pull` confirmation without a prompt.

## Design decisions on record

- **The store is named on every run, never inferred.** Inferring it from the repository
  name or remote would be convenient and wrong the first time two projects share a name, or
  when the target is a plain directory rather than a checkout. Naming it also lets one
  project have several stores (per customer, per environment), which an inferred key cannot
  express.
- **The target may be any directory, not only a git worktree.** The tool checks structure,
  not repository identity. This keeps it useful for a plain folder, a container mount, or a
  fresh directory seeded with `--force-dir`.
- **The parent-directory check is the schema check.** There is no separate "does this store
  belong here" concept. If the manifest's destinations do not fit the target's shape, the
  target is the wrong one, and the tool says which paths did not fit. `--force-dir` is the
  explicit way to say "build the shape instead".
- **Sectioned manifest with a directive section name.** A line-based `source -> dest` form
  is shorter, but every new behavior would become a new parsing rule inside the same line.
  A section header names the operation, so `copy` was added without touching the parser's
  shape, and the next directive costs one `case` branch. `version = 1` makes the change
  detectable.
- **Unknown keys are errors, not warnings.** A silently ignored `optonal = true` is a file
  that never appears, found weeks later. There is one user and one manifest per project, so
  strictness costs nothing.
- **`link` conflicts are backed up; `copy` drift is not touched.** They look similar but ask
  different questions. An unmanaged file sitting where a link belongs is in the way, and the
  backup keeps it recoverable. A copy that differs from the store is a change someone made
  on purpose, and destroying it would break the merge-back workflow that `copy` mode exists
  for.
- **Absolute symlinks.** The store lives outside the project and the relative distance
  changes with every worktree path, so a relative link buys nothing and breaks when the
  worktree moves.
- **A directory is linked as one symlink**, not mirrored file by file. That matches how
  these folders are used (a whole `.some-folder` belongs to the environment), and it means a
  new file in the store folder appears in every target with no re-apply.
- **No state file.** `status` and `remove` derive everything from the manifest plus the real
  symlink targets, so there is nothing to go stale when a worktree is deleted. The cost is
  that `--force-dir` directories are not pruned on `remove` — an empty directory is cheap,
  and a tracked one would have to survive being wrong.
- **The tool reports git ignore problems and never fixes them.** Writing `.gitignore` would
  touch a tracked file, and writing `.git/info/exclude` would edit git state the user did not
  ask it to edit. A copy-paste line is enough.
- **Pure bash, no Python.** The whole tool is path arithmetic, `ln`, `cp` and `diff`. The
  manifest parser is one `while read` loop with a line counter. Adding a Python dependency
  to a symlink manager would be the only reason `python3` is needed on a machine.
- **Backups use the `.dev-env.bak` suffix in place**, not a hidden directory. The backup sits
  next to the file it replaced, so it is visible in the directory you are working in, and
  `remove --restore` finds it with no bookkeeping.
- **`pull` refuses duplicate store sources.** When two selected entries resolve to the same
  store file, `pull` exits 1 instead of silently overwriting the first with the second. A
  single store file cannot accept two different target versions at once, and such a collision
  is always a mistake in the manifest (two destinations feeding one source).
- **PATH arguments are de-duplicated.** When an entry is selected twice on the command line
  (e.g. by different names or from different selection rules), it is processed once. This
  simplifies the logic and prevents duplicate reports.
- **`adopt --as NAME` is validated.** The `NAME` is checked with the same rules as manifest
  `source`: relative, no leading `/`, and no `..` segment. An unvalidated name could move a
  file outside the store, breaking the all-or-nothing guarantee. A `/` inside the name is
  still legal, because it mirrors the destination structure (e.g. `auth/service.env`).
- **`adopt` refuses absolute paths outside the target root.** An absolute `PATH` that does
  not resolve inside the target is rejected instead of being reinterpreted as relative. This
  catches mismatched stores and wrong targets early, when the command is typed.
- **A symlinked directory cannot be used to escape a root.** A string prefix check (does the
  path start with `$TARGET_ROOT`?) is not enough: a target holding, say,
  `vendor -> /somewhere/outside` makes the resolved location different from what the
  unresolved path spells. `apply`'s parent-directory check and `adopt`'s path validation both
  resolve the existing parent directory with `readlink -f` and require it to be the target
  root or a path under it, before any write.
- **`adopt` refuses duplicate PATH arguments.** The same path cannot appear twice in one run
  (even with different syntax), because the all-or-nothing check is run before any move and
  a duplicate would only surface mid-move if it slipped past — a guarantee break.

## Known considerations / extension points

- **Windows shells (Git Bash, MSYS, Cygwin)**: `ln -s` often copies silently there, the same
  problem `setup.sh` works around with wrapper scripts. `dev-env` detects those shells
  (`$OSTYPE`) and fails a `link` entry with a message pointing at `mode = copy`. This is
  untested in practice — the tool is used from WSL and Linux.
- **No templating or per-worktree values.** Every target gets the same bytes. A feature that
  needs its own port or database name still needs a local edit, which then shows up as drift
  on a `copy` entry (and is invisible on a `link` entry, since the edit lands in the store).
  Placeholder substitution would be a new directive if it is ever needed.
- **No profiles.** One manifest per store. A second environment is a second store directory,
  or a second manifest file passed by path.
- **`adopt` appends, it never reorders or rewrites** existing manifest blocks. Comments and
  formatting above are preserved byte-for-byte.

## How to test quickly

```bash
tmp=$(mktemp -d); mkdir -p "$tmp/store" "$tmp/proj/auth"
printf 'version = 1\n\n[link]\nsource = root.env\ndest = /.env\n\n[link]\nsource = auth.env\ndest = /auth/.env\n' > "$tmp/store/.manifest"
printf 'A=1\n' > "$tmp/store/root.env"; printf 'B=2\n' > "$tmp/store/auth.env"
cd "$tmp/proj" && dev-env apply "$tmp/store" && dev-env status "$tmp/store"
ls -l .env auth/.env          # both are symlinks into the store
dev-env apply "$tmp/store"    # second run: every entry reports ok
```

Structure check and seeding:

```bash
mkdir -p "$tmp/empty" && cd "$tmp/empty"
dev-env apply "$tmp/store"                # fails: /auth parent directory missing
dev-env apply "$tmp/store" --force-dir    # creates auth/, then links
```

Drift and merge back (needs a `[copy]` entry in the manifest):

```bash
printf 'B=changed\n' > auth/.env
dev-env status "$tmp/store"   # drift
dev-env diff   "$tmp/store"
dev-env pull   "$tmp/store" --yes
```
