# wsl-terminal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the root-level `title.sh` prototype into `environment/wsl-terminal.bash`, a selectable sourced file that keeps Windows Terminal tabs/panes in the current directory when duplicated and keeps the tab title in sync with `cd`.

**Architecture:** One sourced Bash snippet in `environment/`, guarded to be a no-op outside interactive WSL shells. A single function runs on every prompt via `PROMPT_COMMAND` (prepend idiom shared with `environment/git-prompt.bash`) and emits two escape sequences: OSC 0 for the tab title, OSC 9;9 for the working-directory report Windows Terminal uses for same-directory duplication.

**Tech Stack:** Bash, Windows Terminal OSC sequences, `wslpath`.

**Spec:** `.docs/superpowers/specs/2026-07-24-wsl-terminal-design.md`

## Global Constraints

- The repository is immutable at runtime: the new file must never write files, symlinks, or metadata into the repo.
- Commit policy: clean, human-style Conventional Commits. **No AI attribution, no `Co-authored-by:`, no "Generated with Claude" or similar trailers.**
- Sourced-file style: comment-heavy, section-delimited, matching `environment/git-prompt.bash`.
- Spec mandates **one single implementation commit**: `feat(wsl-terminal): set tab title and report pwd to Windows Terminal`. Tasks 1–2 therefore verify but do not commit; Task 3 commits everything.
- This repo has no automated test harness; verification is `bash -n` plus scripted functional checks shown in each task.

---

### Task 1: Create `environment/wsl-terminal.bash`

**Files:**
- Create: `environment/wsl-terminal.bash`

**Interfaces:**
- Consumes: `$WSL_DISTRO_NAME` (set by WSL), `wslpath` (WSL utility), `$PROMPT_COMMAND` (may already contain `__ctp_build_prompt` from `environment/git-prompt.bash`).
- Produces: shell function `__wt_update_title` (no args, prints two escape sequences to stdout) and a `PROMPT_COMMAND` entry running it before any pre-existing hooks.

- [ ] **Step 1: Write the file**

Create `environment/wsl-terminal.bash` with exactly this content:

```bash
# Windows Terminal integration for Bash running under WSL
# Source this file from ~/.bashrc
#
# Two behaviors, both refreshed on every prompt via PROMPT_COMMAND:
#
#   1. Working-directory inheritance: emits the OSC 9;9 sequence carrying the
#      Windows path of $PWD, so duplicating a tab or splitting a pane in
#      Windows Terminal opens in the current directory.
#      Ref: https://learn.microsoft.com/en-us/windows/terminal/tutorials/new-tab-same-directory
#
#   2. Dynamic tab title: sets the title to "<distro> — <dirname>" (for
#      example "Ubuntu — bash-tools") via the standard OSC 0 sequence. The
#      distro name comes from $WSL_DISTRO_NAME, so the same file works on any
#      WSL distribution.
#
# Outside WSL (plain Linux, macOS, Git Bash) sourcing this file is a silent
# no-op thanks to the guards below.

# Only configure the terminal for interactive Bash shells.
[[ $- != *i* ]] && return

# Only run under WSL: wslpath and the OSC 9;9 sequence mean nothing elsewhere.
[[ -z ${WSL_DISTRO_NAME:-} ]] && return

__wt_update_title() {
    # Short display name for the tab title: ~ at $HOME, / at the filesystem
    # root, otherwise the basename of the current directory.
    local dir_name
    if [[ "$PWD" == "$HOME" ]]; then
        dir_name="~"
    elif [[ "$PWD" == "/" ]]; then
        dir_name="/"
    else
        dir_name="${PWD##*/}"
    fi

    # Tab title: "<distro> — <dirname>".
    printf '\e]0;%s — %s\a' "$WSL_DISTRO_NAME" "$dir_name"

    # Tell Windows Terminal the current working directory (as a Windows path)
    # so tabs/panes duplicated from this one start here.
    printf '\e]9;9;%s\e\\' "$(wslpath -w "$PWD")"
}

# Run before every prompt. Prepend to any existing PROMPT_COMMAND rather than
# clobbering it, so this coexists with other hooks (e.g. git-prompt.bash).
PROMPT_COMMAND="__wt_update_title${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
```

- [ ] **Step 2: Syntax check**

Run: `bash -n environment/wsl-terminal.bash`
Expected: no output, exit code 0.

- [ ] **Step 3: Functional check — escape sequences emitted on WSL**

Run (from the repo root, inside WSL, so `$WSL_DISTRO_NAME` is already set):

```bash
bash --noprofile --norc -i -c 'source environment/wsl-terminal.bash; cd /home; __wt_update_title | cat -v; echo; echo "PC=$PROMPT_COMMAND"'
```

Expected output (distro/path vary with the machine; `M-bM-^@M-^T` is the UTF-8 em dash rendered by `cat -v`):

```
^[]0;Ubuntu M-bM-^@M-^T home^G^[]9;9;\\wsl.localhost\Ubuntu\home^[\
PC=__wt_update_title
```

Also verify the special cases:

```bash
bash --noprofile --norc -i -c 'source environment/wsl-terminal.bash; cd "$HOME"; __wt_update_title | cat -v; echo; cd /; __wt_update_title | cat -v; echo'
```

Expected: first line's title part reads `^[]0;Ubuntu M-bM-^@M-^T ~^G...`, second line's reads `^[]0;Ubuntu M-bM-^@M-^T /^G...`.

- [ ] **Step 4: Functional check — no-op outside WSL**

Run:

```bash
env -u WSL_DISTRO_NAME bash --noprofile --norc -i -c 'source environment/wsl-terminal.bash; type __wt_update_title; echo "PC=[$PROMPT_COMMAND]"'
```

Expected: `type` prints `bash: line 1: type: __wt_update_title: not found` and the last line is `PC=[]` — the guard returned before defining anything.

- [ ] **Step 5: Functional check — chains with an existing PROMPT_COMMAND**

Run:

```bash
bash --noprofile --norc -i -c 'PROMPT_COMMAND="echo other"; source environment/wsl-terminal.bash; echo "PC=$PROMPT_COMMAND"'
```

Expected: `PC=__wt_update_title; echo other`.

Do **not** commit yet (single-commit constraint; commit happens in Task 3).

---

### Task 2: Remove `title.sh` and update documentation

**Files:**
- Delete: `title.sh` (repo root)
- Modify: `AGENTS.md:119` (inventory table, after the `git-prompt.bash` row)
- Modify: `README.md:34` (repo-structure tree), `README.md:205` (§6 table, after the `git-prompt.bash` row), `README.md:239-249` (§9 changelog, append row)

**Interfaces:**
- Consumes: the file created in Task 1 (`environment/wsl-terminal.bash`) — docs must match its actual path and behavior.
- Produces: nothing consumed by later tasks besides a clean working tree for the Task 3 commit.

- [ ] **Step 1: Delete the prototype**

Run: `git rm title.sh`
Expected: `rm 'title.sh'`.

- [ ] **Step 2: Add the AGENTS.md inventory row**

In `AGENTS.md`, immediately after the line

```
| `environment/git-prompt.bash` | sourced | two-line Catppuccin git-aware prompt |
```

insert:

```
| `environment/wsl-terminal.bash` | sourced | WSL: dynamic tab title + Windows Terminal same-dir tab/pane duplication |
```

- [ ] **Step 3: Update the README repo-structure tree**

In `README.md` §2, change

```
│   ├── golang-env.bash
│   └── git-prompt.bash
```

to

```
│   ├── golang-env.bash
│   ├── git-prompt.bash
│   └── wsl-terminal.bash
```

- [ ] **Step 4: Add the README §6 table row**

Immediately after the line

```
| `environment/git-prompt.bash` | environment | Two-line, Git-aware Catppuccin Macchiato prompt |
```

insert:

```
| `environment/wsl-terminal.bash` | environment | WSL: tab title follows `cd`; Windows Terminal duplicates tabs/panes in the same directory |
```

- [ ] **Step 5: Add the README §9 changelog row**

Append to the bottom of the §9 changelog table:

```
| 2026-07-24 | Add `environment/wsl-terminal.bash` (WSL tab title + Windows Terminal same-directory tab duplication); remove root `title.sh` prototype |
```

- [ ] **Step 6: Verify docs consistency**

Run: `grep -rn "title.sh" README.md AGENTS.md CLAUDE.md; grep -c "wsl-terminal.bash" README.md AGENTS.md`
Expected: the first grep matches nothing (exit 1); the second prints `3` for README.md and `1` for AGENTS.md.

Do **not** commit yet.

---

### Task 3: Single implementation commit

**Files:**
- No new edits; commits the work of Tasks 1–2.

**Interfaces:**
- Consumes: staged/working-tree changes from Tasks 1–2.
- Produces: one commit on `master`.

- [ ] **Step 1: Review the pending change**

Run: `git status --short && git diff --stat HEAD`
Expected: exactly these paths — deleted `title.sh`, new `environment/wsl-terminal.bash`, modified `AGENTS.md`, modified `README.md`.

- [ ] **Step 2: Commit**

```bash
git add environment/wsl-terminal.bash AGENTS.md README.md title.sh
git commit -m "feat(wsl-terminal): set tab title and report pwd to Windows Terminal"
```

Expected: one commit; `git show --stat HEAD` lists the four paths above. The message must contain no AI attribution or trailers.

- [ ] **Step 3: Post-commit verification**

Run: `bash -n environment/wsl-terminal.bash && git log --oneline -1`
Expected: syntax check passes; log shows `feat(wsl-terminal): set tab title and report pwd to Windows Terminal`.

Manual follow-up for the user (not automatable): run `./setup.sh`, tick `wsl-terminal.bash`, open a new Windows Terminal tab, `cd` around to watch the title, then duplicate the tab / split a pane and confirm it opens in the same directory.
