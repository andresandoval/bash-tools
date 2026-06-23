#!/usr/bin/env python3
"""Clean AI-generated meeting notes into tidy Markdown.

Reads raw notes on stdin and writes cleaned Markdown to stdout. The cleanup is
deterministic (no AI): it removes citation links, drops stray backslash escapes,
collapses separator and blank-line runs, and — when project/meeting/date are
given — prepends a small YAML frontmatter block.

Usage:
    clean_md.py < raw.txt > clean.md
    clean_md.py --project "GarageHub" --meeting "Daily Standup" \\
                --date jun-23-2026 [--created 2026-06-23T09:30:00] < raw.txt
"""

import argparse
import re
import sys
from datetime import datetime

# Citation/reference markers whose visible label is just a number — either
# [1](url) (AI-tool style) or [[1]](#cite_note-1) (Wikipedia superscript, whose
# link text is literally "[1]"), pointing at a URL or an in-page anchor. Ordinary
# [text](url) links are left alone.
CITATION_RE = re.compile(r"\[(?:\[\d+\]|\d+)\]\((?:https?://|#)[^)]*\)")

# A line that is only a run of = or - (an AI section separator), optionally with
# a trailing backslash / whitespace.
SEPARATOR_RE = re.compile(r"^\s*[=\-]{3,}\\?\s*$")

# A backslash that escapes a non-word, non-space character (e.g. "5\." or "\-").
# These are spurious escapes from the AI output; drop the backslash.
ESCAPE_RE = re.compile(r"\\(?=[^\w\s])")


def clean_body(text: str) -> str:
    """Apply the deterministic cleanup rules to note body text."""
    text = text.lstrip("﻿")  # drop a leading BOM if present
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = text.replace(" ", " ")  # non-breaking spaces -> regular spaces

    out_lines = []
    in_fence = False
    for line in text.split("\n"):
        stripped = line.lstrip()
        # Toggle fenced code blocks; never rewrite their contents.
        if stripped.startswith("```") or stripped.startswith("~~~"):
            in_fence = not in_fence
            out_lines.append(line)
            continue
        if in_fence:
            out_lines.append(line)
            continue

        # Separator-only line -> blank line.
        if SEPARATOR_RE.match(line):
            out_lines.append("")
            continue

        line = CITATION_RE.sub("", line)
        # Drop a trailing backslash used as a soft line break artifact.
        line = re.sub(r"\\+\s*$", "", line)
        line = ESCAPE_RE.sub("", line)
        out_lines.append(line.rstrip())

    # Collapse runs of blank lines down to a single blank line.
    collapsed = []
    blank = False
    for line in out_lines:
        if line == "":
            if not blank:
                collapsed.append("")
            blank = True
        else:
            collapsed.append(line)
            blank = False

    return "\n".join(collapsed).strip() + "\n"


def frontmatter(title: str, date: str, created: str) -> str:
    """Build a YAML frontmatter block. Values are double-quoted and escaped."""

    def q(value: str) -> str:
        return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'

    return (
        "---\n"
        f"title: {q(title)}\n"
        f"date: {q(date)}\n"
        f"created: {q(created)}\n"
        "---\n\n"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Clean AI meeting notes to Markdown.")
    parser.add_argument("--title")
    parser.add_argument("--date")
    parser.add_argument("--created")
    args = parser.parse_args()

    body = clean_body(sys.stdin.read())

    if args.title and args.date:
        created = args.created or datetime.now().isoformat(timespec="seconds")
        sys.stdout.write(frontmatter(args.title, args.date, created))

    sys.stdout.write(body)
    return 0


if __name__ == "__main__":
    sys.exit(main())
