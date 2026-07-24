# setup post-setup hints — design

2026-07-24

## Goal

Let any selectable file ship usage hints that `setup.sh` prints after a run, so
steps that live outside the shell (e.g. Windows Terminal settings for
`wsl-terminal.bash`) are surfaced right next to the "open a new shell" message.

## Convention

A selectable file may have a **sibling hint file** named `<full-filename>.hint`
(append `.hint` to the complete filename):

```
environment/wsl-terminal.bash
environment/wsl-terminal.bash.hint
tools/add-notes.sh
tools/add-notes.sh.hint
```

- Hint files are **Markdown**, printed as-is to the terminal (raw markdown reads
  fine; no rendering).
- The scanner is unaffected: `setup.sh` matches `-name '*.bash'` / `-name '*.sh'`
  only, so `.hint` files are never offered as selectable items.
- Hints are read-only data; the repo stays immutable.

## setup.sh change

New function `print_post_setup_hints`, called at the end of `main()` after the
existing "Open a new shell or run: source ~/.bashrc" block:

- Iterates the final selection — `SELECTED_SOURCES` then `SELECTED_TOOLS`
  (repo-relative paths like `environment/wsl-terminal.bash`).
- For each item whose `<repo>/<item>.hint` exists, prints the hint under a
  header. Shown on **every run** for **all enabled** files (not just newly
  enabled ones) — the hint doubles as a reminder.
- If no enabled file has a hint, prints nothing — output is byte-identical to
  today.

Output format:

```
Hints:

  wsl-terminal.bash:
    <hint file content, each line indented by 4 spaces>
```

(File header uses the basename; one blank line between multiple hints.)

## First hint file: `environment/wsl-terminal.bash.hint`

Markdown content covering the Windows-side configuration for both features:

- **Same-directory duplication:** duplicate tab is `Ctrl+Shift+D` (default
  `duplicateTab` action); for panes add `"splitMode": "duplicate"` to a
  `splitPane` action in the Windows Terminal settings JSON.
  Ref: <https://learn.microsoft.com/en-us/windows/terminal/tutorials/new-tab-same-directory>
- **Dynamic tab title:** in the Windows Terminal settings JSON set
  `"suppressApplicationTitle": false` on the profile used for the distro (e.g.
  Ubuntu), and `"showTerminalTitleInTitlebar": true` at top level — the title
  bar then shows the selected tab's title instead of "Windows Terminal";
  changing it requires starting a new terminal instance.
  Refs: <https://learn.microsoft.com/en-us/windows/terminal/tutorials/tab-title>
  and <https://learn.microsoft.com/en-us/windows/terminal/customize-settings/appearance#use-active-terminal-title-as-application-title>

## Documentation updates

- `AGENTS.md`: describe the `.hint` convention in the repository-layout and
  "Adding new content" sections; add `environment/wsl-terminal.bash.hint` to the
  inventory table (type: assets/hint, not a command).
- `README.md`: mention the convention in §7 (Adding New Content); changelog row
  in §9.

## Rejected alternatives

- `# bash-tools hint:` comment lines inside the scripts — hints wouldn't be
  real markdown files and long hints bloat the scripts.
- Hardcoding the wsl-terminal hint in `setup.sh` — couples the generic scanner
  to one file.
- Showing hints only for newly enabled files — quieter, but the hint is never
  seen again when it's needed later (e.g. new machine, Windows Terminal not yet
  configured).

## Verification

- `bash -n setup.sh`.
- Run `./setup.sh` with `wsl-terminal.bash` enabled → hint block printed after
  the closing message; with it disabled (or no `.hint` files enabled) → output
  unchanged from today.
- Confirm `.hint` files do not appear in the selector list.

## Commit

Single commit:
`feat(setup): print post-setup hints from sibling .hint files`
