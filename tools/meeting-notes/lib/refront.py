#!/usr/bin/env python3
"""Rewrite selected frontmatter values of a note in place.

Used by `meeting-notes --rename` (after a note moves, its `title` — and, when the
filename stem changed, `date` — must follow the new location) and by
`meeting-notes --retitle` (which rewrites `label`, the entry title the web UI
shows next to the date). Every frontmatter line that is not targeted stays
byte-identical.

A targeted key that the file does not have yet is *inserted* at its canonical
position (the key order `clean_md.py` writes: title, label, date, created).
Notes added before a key existed therefore gain it rather than silently keeping
the old value — `label` is absent from every note predating `--title`. Files
without a frontmatter block are still left untouched. Standard library only.

Usage:
    refront.py FILE [--title TEXT] [--label TEXT] [--date TEXT]
"""

import argparse
import sys
from pathlib import Path

# Canonical frontmatter key order, mirroring clean_md.py's frontmatter writer.
ORDER = ["title", "label", "date", "created"]


def q(value: str) -> str:
    """Double-quote and escape a value like clean_md.py's frontmatter writer."""
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def insert_key(lines, key: str, value: str) -> None:
    """Insert `key` at its canonical spot: before the first key that outranks it."""
    rank = ORDER.index(key)
    entry = f"{key}: {q(value)}"
    for i, line in enumerate(lines):
        other = line.partition(":")[0].strip()
        if other in ORDER and ORDER.index(other) > rank:
            lines.insert(i, entry)
            return
    lines.append(entry)


def main() -> int:
    parser = argparse.ArgumentParser(description="Rewrite frontmatter values in place.")
    parser.add_argument("file")
    parser.add_argument("--title")
    parser.add_argument("--label")
    parser.add_argument("--date")
    args = parser.parse_args()

    updates = {}
    for key in ORDER:
        value = getattr(args, key, None)
        if value is not None:
            updates[key] = value
    if not updates:
        return 0

    path = Path(args.file)
    raw = path.read_text(encoding="utf-8")
    if not raw.startswith("---\n"):
        return 0
    end = raw.find("\n---", 4)
    if end == -1:
        return 0

    lines = raw[4:end].split("\n")
    for i, line in enumerate(lines):
        if ":" not in line:
            continue
        key = line.partition(":")[0].strip()
        if key in updates:
            lines[i] = f"{key}: {q(updates.pop(key))}"
    # Whatever is left had no line to rewrite — add it, in canonical order.
    for key in ORDER:
        if key in updates:
            insert_key(lines, key, updates.pop(key))
    path.write_text(raw[:4] + "\n".join(lines) + raw[end:], encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
