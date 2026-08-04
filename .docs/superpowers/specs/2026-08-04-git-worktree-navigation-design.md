# git worktree navigation — design

2026-08-04

## Goal

`functions/git-navigation.bash` provided one function, `goto-git-root`. It already lands in
the **current worktree's** root (`git rev-parse --show-toplevel` is worktree-relative), so it
was never broken inside a linked worktree — but two movements were impossible:

- getting from a linked worktree back to the **main repository** root, and
- hopping between **sibling worktrees** of the same repo.

There was also no signal telling you *which* worktree you landed in, which starts to matter
once several worktrees of one repo are checked out side by side.

Both layouts must work: a normal clone with linked worktrees added alongside it, and a bare
repository whose worktrees are siblings of it.

## Shape: functions, not a tool

Every command here changes the caller's directory, so none of them can be a `tools/*.sh`
entry — those run as child processes and their `cd` dies with them. Everything lives in
`functions/git-navigation.bash`, which is *sourced*: no `set -euo pipefail`, no `exit`, only
`return`.

Three functions, one intent each — matching the repo's explicit-verb naming (`git-prune-local`,
`git-list-merged-branches`) rather than flags on a command hit dozens of times a day:

| Function | Moves to |
|----------|----------|
| `goto-git-root` | the root of the working tree you are in (unchanged behavior) |
| `goto-git-main` | the main repository root, from anywhere in the repo |
| `goto-git-worktree [NAME]` | any worktree of the repo, by name or from a menu |

Rejected alternatives: one function with `--main` / `--pick` flags (grows an arg parser on the
hot path, and tab-completion of worktree names only works *after* a flag); a context-aware
`goto-git-root` that guesses (same command doing different things by location is the kind of
magic that bites you at 5pm).

## Data source

`git worktree list --porcelain` is the single source of truth. Records are blank-line separated;
the **main worktree is always first**, and a bare main repo has a `bare` line in place of
`HEAD`/`branch`:

```
worktree /path/to/repo.git        worktree /path/to/main
bare                              HEAD abc123…
                                  branch refs/heads/master
```

This covers both layouts without inspecting `core.bare` or guessing at path shapes.
`_git_nav_worktrees` parses it into one TAB-separated record per worktree:

```
<path><TAB><label><TAB><marker>
```

`label` is the branch name, or `(bare)` / `(detached)`; `marker` is `*` for the worktree the
caller is currently inside. Helpers are prefixed `_git_nav_` to keep the interactive namespace
clean; `_git_nav_select` renders the numbered menu (to stderr) and echoes the chosen path
(to stdout) so callers can capture it.

## Behavior

### `goto-git-root`

Unchanged core: `cd "$(git rev-parse --show-toplevel)"`. Two additions:

- **Linked-worktree note.** After a successful `cd`, if `--git-dir` and `--git-common-dir`
  resolve to different absolute paths, print one line: `worktree: <dir>  branch: <branch>`
  (`(detached)` when HEAD is detached). An ordinary single-checkout repo stays *completely
  silent* — no new noise on the hot path.
- **No-working-tree message.** When `--show-toplevel` fails but `--git-dir` succeeds (a bare
  repo, or the cwd is inside a `.git` directory), replace the misleading "not inside a Git
  repository" with a message pointing at `goto-git-main` / `goto-git-worktree`.

### `goto-git-main`

Takes the first record from `_git_nav_worktrees` and cds to its path. If that record is `(bare)`,
it cds there anyway and prints `main repository (bare) — use goto-git-worktree to reach a
checkout`. A bare repo *is* the main repository — the place `git fetch` and `git worktree add`
belong — so landing there is correct; the note just prevents wondering where the files went.

### `goto-git-worktree [NAME]`

- **With NAME:** match against worktree directory basenames and branch names — all exact
  matches first, and only if there are none, substring matches. No match → error, `return 1`,
  no movement. Exactly one → `cd`. Ambiguous → the numbered menu, narrowed to the candidates.
- **No NAME, several worktrees:** the numbered menu — dir basename, label, `(current)` marker.
  Dependency-free (`read`, no `fzf`), consistent with the repo's no-auto-install rule; empty
  input cancels with `return 0`, non-numeric or out-of-range errors with `return 1`. Neither
  moves you.
- **No NAME, one worktree:** cd there and print `only one worktree: <dir>`, so the silent
  no-op is not read as a menu that failed to appear.

Bare entries stay selectable in the menu (marked `(bare)`) — same destination as `goto-git-main`.

### `--help`

Each command takes `-h` / `--help` and prints `Usage:` / `Description:` / `See also:` to
stdout, matching the section style of the `tools/` help blocks. A shared `_git_nav_help`
holds all three texts in one `case` so they stay in sync, and the `See also:` block lists the
*other* two commands — these functions are mostly discoverable through each other, which is the
whole reason the gap went unnoticed for so long.

Each command also rejects what it does not take (`goto-git-root`/`goto-git-main`: any argument;
`goto-git-worktree`: unknown options and a second NAME) with a `return 1` and a pointer to
`--help`, rather than silently ignoring it. `--help` works outside a repository.

### Tab-completion

`_goto_git_worktree_complete` completes worktree directory basenames plus branch names, and
lives **in the same file** rather than a separate `*-completion.bash`: the functions and their
completion are one selectable unit, so enabling the file gets everything. (`meeting-notes`
needs its own file only because the command itself lives in `tools/`.) Outside a repository it
offers nothing and does not error. A leading `-` completes to `--help`; `goto-git-root` and
`goto-git-main` get a one-line `complete -W "--help"`, which is all they accept.

## Non-changes

- No `setup.sh` change — `functions/git-navigation.bash` is already a selectable file. Picking
  up the new functions needs only `source ~/.bashrc`.
- No `.docs/dev/` spec — that directory is for multi-file tools with `tools/<name>/` assets.
- Nothing is written into the repository; these functions only `cd`.

## Verification

`bash -n` on the file, plus a 56-check behavior suite over scratch fixtures (a normal clone
with a linked worktree, a bare clone with a sibling worktree, and a single-worktree repo)
covering: silence in the main worktree, the linked-worktree note, `goto-git-main` from both
layouts, exact/substring/branch matching, the menu (layout, pick, cancel, bad input — none of
which move you), the no-match error, the bare-repo messages, the single-worktree note, all
three functions outside a repository, `-h`/`--help` for each command (on stdout, not stderr;
never listing itself under `See also`; working outside a repo; not moving you), every rejected
argument form, and completion inside a repo, outside one, and for `--help`.
