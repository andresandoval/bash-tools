@AGENTS.md

## Claude-specific notes

- A tool complex enough to need one has a design spec at `.docs/dev/<tool>.md`, whether it
  is multi-file (`meeting-notes.md`) or a single script (`dev-env.md`). Read the relevant
  spec before modifying such a tool.
- When a tool's interface or behavior changes, update its spec in `.docs/dev/` and add
  a row to the changelog in `README.md` §9.
