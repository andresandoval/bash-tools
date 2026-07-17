#!/usr/bin/env python3
"""Rewrite selected frontmatter values of a note in place.

Used by `add-notes --rename`: after a note moves, its `title` (and, when the
filename stem changed, `date`) must follow the new location, while every other
frontmatter line — label, created, anything unknown — stays byte-identical.
Only the value of a targeted key is replaced; missing keys are not added, and
files without a frontmatter block are left untouched. Standard library only.

Usage:
    refront.py FILE [--title TEXT] [--date TEXT]
"""

import argparse
import sys
from pathlib import Path


def q(value: str) -> str:
    """Double-quote and escape a value like clean_md.py's frontmatter writer."""
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main() -> int:
    parser = argparse.ArgumentParser(description="Rewrite frontmatter values in place.")
    parser.add_argument("file")
    parser.add_argument("--title")
    parser.add_argument("--date")
    args = parser.parse_args()

    updates = {}
    if args.title is not None:
        updates["title"] = args.title
    if args.date is not None:
        updates["date"] = args.date
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
    path.write_text(raw[:4] + "\n".join(lines) + raw[end:], encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
