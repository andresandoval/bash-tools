# AGENTS.md

Guidance for AI agents (Claude Code, Cursor, Copilot, etc.) working in this repository.

## Project overview

**bash-tools** is a personal shell-configuration manager. It collects aliases,
environment exports, shell functions, and standalone command-line tools into a single
repository, and exposes a selectable subset of them to the user's interactive shell.
A single script, `setup.sh`, scans the repository, lets the user pick what to enable
through a checklist UI, and wires the selection into the shell — without ever modifying
the repository itself.

## Repository layout

```
aliases/       *.bash  → sourced from ~/.bashrc
environment/   *.bash  → sourced from ~/.bashrc (PATH / env var exports)
functions/     *.bash  → sourced from ~/.bashrc (shell functions)
tools/         *.sh    → exposed as commands in ~/.local/bin/bash-tools
.docs/dev/             → design specs for multi-file tools (not scanned by setup.sh)
setup.sh               → the only entry point; installs/reconciles everything
```

- Files in `aliases/`, `environment/`, and `functions/` are **sourced** into the shell.
- Files in `tools/` become **commands**: the command name is the filename with `.sh`
  stripped (e.g. `tools/git-prune-local.sh` → the `git-prune-local` command).

## How `setup.sh` works

Run `./setup.sh` to (re)configure the shell. It is idempotent — re-run it any time
files are added, removed, or you want to change the selection.

Key behaviors to understand before changing anything:

- **The repository is immutable.** `setup.sh` never writes files, metadata, or symlinks
  *inside* the repo. All persistent state lives outside it:
  - `~/.local/bin/bash-tools/.bashrc` — the **managed file**: a generated bashrc-style
    file holding the `BASH_TOOLS_HOME` export, the `PATH` addition, one `source` line per
    enabled alias/environment/function, and the `# bash-tools inventory:` comments. It is
    overwritten in full on every run.
  - `~/.bashrc` — a single managed `source` line, preceded by the marker
    `# bash-tools managed source`, that loads the managed file. Added idempotently.
  - `~/.local/bin/bash-tools/` — one entry per enabled tool (symlink or wrapper), added
    to `PATH`. The managed `.bashrc` lives here too but is never treated as a tool entry.
- **`BASH_TOOLS_HOME`** is the canonical repository root. If unset, it is inferred from
  the location of `setup.sh`. The generated managed file exports it and uses it for all
  `source` lines.
- **Migration from the old layout.** Earlier versions wrote a delimited block
  (`# >>> bash-tools managed block >>>` … `# <<< … <<<`) directly into `~/.bashrc`.
  `setup.sh` no longer writes that block, but reads it once as a fallback to preserve an
  existing selection. Removing a leftover legacy block from `~/.bashrc` is done manually.
- **Selection UI.** Prefers `whiptail`, then `dialog`, then a built-in text-based
  selector. Missing UI dependencies are *never auto-installed*; the script prints an
  install hint for the detected package manager and falls back to the text selector.
- **Tools: symlink vs wrapper.** On Linux/macOS each enabled tool is a symlink into
  `tools/`. On Windows (Git Bash / MSYS / Cygwin), where `ln -s` often silently copies,
  a small wrapper script is written instead (marked with `# bash-tools managed wrapper`
  and a `# Source:` line so later runs can recognize and clean it up).
- **Reconciliation.** On each run, selected items are (re)enabled, deselected items are
  removed, and entries for files deleted from the repo are pruned. Unrelated files in
  `~/.bashrc` or `~/.local/bin/bash-tools/` are left untouched.
- An inventory of known files is stored as `# bash-tools inventory:` comments inside the
  managed file so the next run can report newly added / removed files.

After running, open a new shell or `source ~/.bashrc`.

## Adding new content

**An alias, env file, or function:**
1. Drop a `*.bash` file into `aliases/`, `environment/`, or `functions/`.
2. Run `./setup.sh` and check the new file in the selector.

**A tool / command:**
1. Add a `*.sh` file to `tools/` with a `#!/usr/bin/env bash` shebang.
2. Make it executable: `chmod +x tools/your-tool.sh` (also commit the executable bit).
3. Run `./setup.sh` and select it. The command name will be the filename minus `.sh`.

## Conventions

- **Bash style:** start scripts with `#!/usr/bin/env bash` and `set -euo pipefail`.
  Tools should provide a usage/`show_help` block. Match the existing comment-heavy,
  section-delimited style in `setup.sh`.
- **Executable bit:** tools must be executable, or the generated command will fail.
- **Commits:** use Conventional Commits with a scope matching the area touched, e.g.
  `feat(git-prompt): ...`, `chore(setup): ...`, `refactor(git-prune-local): ...`.

## Git Commit Policy

When creating Git commits, follow these rules:

- Create clean, standard Git commits only.
- Never add AI attribution or signatures.
- Never include `Co-authored-by:` trailers.
- Never include `Generated by Claude`, `Created with Claude`, `🤖 Generated`, or any
  similar metadata.
- Never mention AI assistance in commit messages or commit metadata unless I explicitly
  request it.
- The final commit should be indistinguishable from one created manually by a human
  developer.

## Things not to do

- Do **not** make scripts write files, symlinks, or metadata *into* the repository —
  the immutable-repo principle is core to the design.
- Do **not** hand-edit the managed file `~/.local/bin/bash-tools/.bashrc`; it is
  regenerated by `setup.sh` and manual changes will be overwritten.
- Do **not** assume `ln -s` works on Windows shells; respect the wrapper-script path.
- Do **not** add logic that auto-installs system packages.

## Quick reference — current inventory

| File | Type | Effect |
|------|------|--------|
| `aliases/common-alias.bash` | sourced | general-purpose aliases (`ll`, `to-clipboard`) |
| `aliases/gnome-alias.bash` | sourced | GNOME-specific aliases (`gedit`) |
| `environment/flutter-env.bash` | sourced | Flutter / Android SDK env + PATH |
| `environment/golang-env.bash` | sourced | Go env (`GOPATH`, `GOROOT`) + PATH |
| `environment/git-prompt.bash` | sourced | two-line Catppuccin git-aware prompt |
| `environment/wsl-terminal.bash` | sourced | WSL: dynamic tab title + Windows Terminal same-dir tab/pane duplication |
| `functions/git-navigation.bash` | sourced | `goto-git-root` function |
| `functions/add-notes-completion.bash` | sourced | tab-completion for the `add-notes` command |
| `tools/age-pdf.sh` | command `age-pdf` | age a PDF to look like an old scan |
| `tools/appimage-install.sh` | command `appimage-install` | install an AppImage as a desktop app |
| `tools/cleanup-old-kernels.sh` | command `cleanup-old-kernels` | remove old kernels (dnf) |
| `tools/compare-copy.sh` | command `compare-copy` | compare a file copy between dirs |
| `tools/copy-realpath.sh` | command `copy-realpath` | copy a file's absolute path to clipboard |
| `tools/git-prune-local.sh` | command `git-prune-local` | prune local git branches |
| `tools/nvidia-prime-run.sh` | command `nvidia-prime-run` | run a command on the NVIDIA GPU (PRIME offload) |
| `tools/add-notes.sh` | command `add-notes` | capture meeting notes as clean Markdown under a freeform path + tree search UI, in any dir |
| `tools/add-notes/` | assets (not a command) | `lib/` Python helpers + `web/` UI template for `add-notes` |

### Multi-file tools

`setup.sh` only exposes top-level `tools/*.sh` files, so a tool that needs more than one
file keeps its helpers in a sibling `tools/<name>/` directory (e.g. `tools/add-notes/`),
which the scanner ignores. The entry script resolves its own real path with
`readlink -f "${BASH_SOURCE[0]}"` (so it works through the installed symlink) and reads
its assets from there. Such a tool still writes nothing into this repo — it operates on
the user's working directory only.

Each multi-file tool has a design spec in `.docs/dev/<name>.md` (e.g.
`.docs/dev/add-notes.md`). Read it before changing the tool, and keep it updated when
the tool's interface or behavior changes.
