# wsl-terminal — design

2026-07-24

## Goal

Integrate the root-level `title.sh` prototype into the bash-tools ecosystem as a
proper selectable sourced file, providing two behaviors for Bash running under WSL
in Windows Terminal:

1. **Working-directory inheritance** — duplicating a tab or splitting a pane opens
   in the current directory, per the OSC 9;9 mechanism described in
   <https://learn.microsoft.com/en-us/windows/terminal/tutorials/new-tab-same-directory>.
   (In `title.sh` this line is commented out; the integrated version re-enables it.)
2. **Dynamic tab title** — the tab title tracks the current directory on every
   prompt, formatted `<distro> — <dirname>` (e.g. `Ubuntu — bash-tools`).

## New file: `environment/wsl-terminal.bash`

A sourced snippet in the house style (comment-heavy header, keeps the Microsoft
docs reference). Contents:

- **Guards** (early `return`, making the file a silent no-op where it doesn't
  apply):
  - interactive shells only: `[[ $- != *i* ]] && return`
  - WSL only: `[[ -z ${WSL_DISTRO_NAME:-} ]] && return`
- **One function, `__wt_update_title`**, run on every prompt:
  - display name: `~` when `$PWD` is `$HOME`, `/` at the filesystem root,
    otherwise the basename `${PWD##*/}`;
  - tab title via OSC 0: `printf '\e]0;%s — %s\a' "$WSL_DISTRO_NAME" "$dir_name"`
    — distro name taken from the environment, not hardcoded;
  - working-directory report via OSC 9;9:
    `printf '\e]9;9;%s\e\\' "$(wslpath -w "$PWD")"`.
- **Hook:** `PROMPT_COMMAND="__wt_update_title${PROMPT_COMMAND:+; $PROMPT_COMMAND}"`
  — the same prepend idiom used by `environment/git-prompt.bash`, so both files
  chain regardless of source order.
- All commented-out legacy variants from `title.sh` are dropped.

## Removals

- Delete root-level `title.sh`. Commit `82f0ddc "title"` is already pushed and
  stays in history; no rewriting.

## Documentation updates

- `AGENTS.md`: add `environment/wsl-terminal.bash` to the quick-reference
  inventory table.
- `README.md` §9: add a changelog row.
- No `.docs/dev/` spec — that convention is for multi-file tools only.

## Rejected alternatives

- **Two separate files** (title vs. pwd-report): never enabled independently;
  doubles the `PROMPT_COMMAND` hooks.
- **Folding into `git-prompt.bash`**: couples an aesthetic prompt choice to
  WSL-specific behavior.

## Verification

- `bash -n environment/wsl-terminal.bash` (syntax).
- Source the file in a WSL shell and inspect the emitted escape sequences
  (e.g. capture `__wt_update_title` output with `cat -v`).
- Manual check in Windows Terminal: title updates on `cd`; duplicated tab /
  split pane opens in the same directory.

## Commit

Single conventional commit:
`feat(wsl-terminal): set tab title and report pwd to Windows Terminal`
(clean message per repo Git commit policy).
