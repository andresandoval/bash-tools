# setup post-setup hints Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `setup.sh` prints the Markdown content of sibling `<filename>.hint` files for every enabled item after each run, starting with a hint for `wsl-terminal.bash` covering the Windows Terminal settings.

**Architecture:** One new function `print_post_setup_hints` in `setup.sh`, called at the end of `main()`. It scans the final `SELECTED_SOURCES`/`SELECTED_TOOLS` arrays for `<repo>/<item>.hint` files and prints them indented under a `Hints:` header. The scanner (`find ... -name '*.bash'` / `'*.sh'`) already ignores `.hint` files, so no selector changes.

**Tech Stack:** Bash. No test harness in this repo — verification is `bash -n` plus scripted function-level checks shown in each task.

**Spec:** `.docs/superpowers/specs/2026-07-24-setup-hints-design.md`

## Global Constraints

- The repository is immutable at runtime: `setup.sh` only reads `.hint` files, never writes into the repo.
- Commit policy: clean, human-style Conventional Commits. **No AI attribution, no `Co-authored-by:`, no "Generated with Claude" or similar trailers.**
- Spec mandates **one single implementation commit**: `feat(setup): print post-setup hints from sibling .hint files`. Tasks 1–2 verify but do not commit; Task 3 commits everything.
- Style: match `setup.sh`'s comment-heavy, section-delimited style (`# ---- ... ----` headers) and its logging/quoting conventions.
- Output contract: when no enabled file has a hint, setup output is byte-identical to today.

---

### Task 1: Create `environment/wsl-terminal.bash.hint`

**Files:**
- Create: `environment/wsl-terminal.bash.hint`

**Interfaces:**
- Consumes: nothing.
- Produces: the hint file Task 2's functional check reads, at the exact path `environment/wsl-terminal.bash.hint` (full filename of the script + `.hint`).

- [ ] **Step 1: Write the file**

Create `environment/wsl-terminal.bash.hint` with exactly this content:

```markdown
# wsl-terminal — Windows Terminal settings

The sibling script tells Windows Terminal the tab title and the working
directory on every prompt. Windows Terminal needs the settings below to honor
them (open the JSON settings with Ctrl+Shift+,).

## Same-directory tab / pane duplication

- Duplicate tab: Ctrl+Shift+D (the default `duplicateTab` action) opens in the
  current directory.
- Split pane: add `"splitMode": "duplicate"` to a `splitPane` action, e.g.
  `{ "command": { "action": "splitPane", "split": "auto", "splitMode": "duplicate" }, "keys": "alt+shift+d" }`
- Ref: https://learn.microsoft.com/en-us/windows/terminal/tutorials/new-tab-same-directory

## Dynamic tab title

- In the profile used for this distro (e.g. Ubuntu), set
  `"suppressApplicationTitle": false` so the title set by the shell is not
  suppressed.
- At top level, set `"showTerminalTitleInTitlebar": true` — the title bar then
  shows the selected tab's title instead of "Windows Terminal". Changing this
  requires starting a new terminal instance.
- Refs: https://learn.microsoft.com/en-us/windows/terminal/tutorials/tab-title
  and https://learn.microsoft.com/en-us/windows/terminal/customize-settings/appearance#use-active-terminal-title-as-application-title
```

- [ ] **Step 2: Verify the selector still ignores it**

Run: `find environment -maxdepth 1 -type f -name '*.bash' -printf '%f\n' | sort`
Expected: `flutter-env.bash`, `git-prompt.bash`, `golang-env.bash`, `wsl-terminal.bash` — and **no** `wsl-terminal.bash.hint` (the pattern `*.bash` does not match it).

Do **not** commit yet (single-commit constraint; commit happens in Task 3).

---

### Task 2: Add `print_post_setup_hints` to `setup.sh`

**Files:**
- Modify: `setup.sh` (new function after `ensure_bashrc_source`, ~line 843; one call added in `main()` after the `source ~/.bashrc` printf, ~line 868)

**Interfaces:**
- Consumes: globals `REPO_ROOT`, `SELECTED_SOURCES`, `SELECTED_TOOLS` (repo-relative paths like `environment/wsl-terminal.bash`); the hint file from Task 1.
- Produces: function `print_post_setup_hints` (no args, prints to stdout) called once at the end of `main()`.

- [ ] **Step 1: Insert the function**

In `setup.sh`, after the closing `}` of `ensure_bashrc_source` (before the `# Main execution flow.` section comment), insert:

```bash
# ------------------------------------------------------------------------------
# Print post-setup hints.
#
# A selectable file may ship a sibling "<filename>.hint" Markdown file holding
# follow-up steps that live outside the shell (e.g. Windows Terminal settings
# for environment/wsl-terminal.bash). The hints of all currently enabled items
# are printed after the closing message on every run, so they also serve as
# reminders. When no enabled item has a hint, nothing is printed.
# ------------------------------------------------------------------------------

print_post_setup_hints() {
    local item hint_file line printed_header=0

    for item in "${SELECTED_SOURCES[@]}" "${SELECTED_TOOLS[@]}"; do
        hint_file="${REPO_ROOT}/${item}.hint"
        [[ -f "${hint_file}" ]] || continue

        if (( printed_header == 0 )); then
            printf '\nHints:\n'
            printed_header=1
        fi

        printf '\n  %s:\n' "${item##*/}"
        while IFS= read -r line || [[ -n "${line}" ]]; do
            printf '    %s\n' "${line}"
        done < "${hint_file}"
    done
}
```

- [ ] **Step 2: Call it from `main()`**

In `main()`, change

```bash
    printf '\nDone.\n'
    printf 'Open a new shell or run:\n'
    printf '  source ~/.bashrc\n'
}
```

to

```bash
    printf '\nDone.\n'
    printf 'Open a new shell or run:\n'
    printf '  source ~/.bashrc\n'

    print_post_setup_hints
}
```

- [ ] **Step 3: Syntax check**

Run: `bash -n setup.sh`
Expected: no output, exit 0.

- [ ] **Step 4: Functional check — hint printed for an enabled file**

Run (extracts the function and calls it against the real repo):

```bash
bash -c '
  set -euo pipefail
  eval "$(sed -n "/^print_post_setup_hints()/,/^}/p" setup.sh)"
  REPO_ROOT="$PWD"
  SELECTED_SOURCES=("environment/git-prompt.bash" "environment/wsl-terminal.bash")
  SELECTED_TOOLS=("tools/git-prune-local.sh")
  print_post_setup_hints
'
```

Expected: output starts with a blank line, then `Hints:`, then a blank line, then `  wsl-terminal.bash:` followed by every line of `environment/wsl-terminal.bash.hint` indented by 4 spaces. Nothing is printed for `git-prompt.bash` or `git-prune-local.sh` (no `.hint` siblings).

- [ ] **Step 5: Functional check — silent when no hints apply**

Run:

```bash
bash -c '
  set -euo pipefail
  eval "$(sed -n "/^print_post_setup_hints()/,/^}/p" setup.sh)"
  REPO_ROOT="$PWD"
  SELECTED_SOURCES=("environment/git-prompt.bash")
  SELECTED_TOOLS=()
  print_post_setup_hints
' | wc -c
```

Expected: `0` (no output at all — today's setup output stays byte-identical). Note the empty `SELECTED_TOOLS=()` must not trip `set -u` (Bash ≥ 4.4 expands empty arrays under `[@]` safely; setup.sh already relies on this).

Do **not** commit yet.

---

### Task 3: Documentation and the single commit

**Files:**
- Modify: `AGENTS.md` (repository layout section; "Adding new content" section; inventory table after the `environment/wsl-terminal.bash` row)
- Modify: `README.md` (§7 Adding New Content; §9 changelog)

**Interfaces:**
- Consumes: the working-tree changes from Tasks 1–2.
- Produces: one commit on `master`.

- [ ] **Step 1: AGENTS.md — document the convention**

In the "Repository layout" section, after the existing bullet

```
- Files in `tools/` become **commands**: the command name is the filename with `.sh`
  stripped (e.g. `tools/git-prune-local.sh` → the `git-prune-local` command).
```

add:

```markdown
- A selectable file may have a sibling `<filename>.hint` Markdown file (e.g.
  `environment/wsl-terminal.bash.hint`); `setup.sh` prints it after every run in
  which the file is enabled. Hint files are never selectable themselves.
```

Then, in the "Adding new content" section, after the tool instructions (the numbered list ending with "The command name will be the filename minus `.sh`."), add:

```markdown
**A post-setup hint for any of the above:**
1. Create a sibling Markdown file named after the full filename plus `.hint`
   (e.g. `environment/wsl-terminal.bash.hint`, `tools/add-notes.sh.hint`).
2. `setup.sh` prints it after every run in which the file is enabled — use it
   for follow-up steps outside the shell (OS settings, app configuration).
   Hint files are never selectable; the scanner only matches `*.bash` / `*.sh`.
```

- [ ] **Step 2: AGENTS.md — inventory row**

Immediately after the line

```
| `environment/wsl-terminal.bash` | sourced | WSL: dynamic tab title + Windows Terminal same-dir tab/pane duplication |
```

insert:

```
| `environment/wsl-terminal.bash.hint` | hint (not selectable) | Windows Terminal settings printed by `setup.sh` after runs with `wsl-terminal.bash` enabled |
```

- [ ] **Step 3: README §7 — mention the convention**

At the end of §7 (Adding New Content), add:

```markdown
**A post-setup hint:** any alias/env/function/tool file may have a sibling
`<filename>.hint` Markdown file (e.g. `environment/wsl-terminal.bash.hint`).
`setup.sh` prints it after every run in which the file is enabled — handy for
follow-up steps outside the shell, like Windows Terminal settings. Hint files
never appear in the selector.
```

- [ ] **Step 4: README §9 — changelog row**

Append to the bottom of the changelog table:

```
| 2026-07-24 | `setup.sh`: print post-setup hints from sibling `<filename>.hint` Markdown files; add `environment/wsl-terminal.bash.hint` (Windows Terminal settings for title + same-dir duplication) |
```

- [ ] **Step 5: Review the pending change**

Run: `git status --short`
Expected changed paths, exactly: new `environment/wsl-terminal.bash.hint`, modified `setup.sh`, `AGENTS.md`, `README.md`. (Scratch paths under `.superpowers/` may also be dirty — exclude them.)

- [ ] **Step 6: Commit**

```bash
git add environment/wsl-terminal.bash.hint setup.sh AGENTS.md README.md
git commit -m "feat(setup): print post-setup hints from sibling .hint files"
```

Expected: one commit; `git show --stat HEAD` lists exactly the four paths. No AI attribution or trailers in the message.

- [ ] **Step 7: Post-commit verification**

Run: `bash -n setup.sh && git log --oneline -1`
Expected: syntax check passes; log shows `feat(setup): print post-setup hints from sibling .hint files`.

Manual follow-up for the user (not automatable): run `./setup.sh` interactively with `wsl-terminal.bash` enabled and confirm the hint block appears after "source ~/.bashrc".
