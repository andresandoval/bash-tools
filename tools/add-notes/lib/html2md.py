#!/usr/bin/env python3
"""Convert rich-clipboard HTML to Markdown (clipboard2markdown-style).

Reads HTML on stdin and writes Markdown to stdout. Built on the standard-library
html.parser — no third-party dependencies. Handles the tags that show up in
meeting notes copied from chat UIs / docs / web pages: headings, paragraphs,
lists (nested), bold/italic, links, inline code, code blocks, blockquotes,
horizontal rules, and simple tables.

It also understands the Windows CF_HTML clipboard payload (the
`Version:…/StartHTML:…` header with <!--StartFragment-->…<!--EndFragment-->
markers) and converts only the fragment.

Usage:
    html2md.py < clipboard.html > notes.md
"""

import re
import sys
from html.parser import HTMLParser

BLOCK_TAGS = {"p", "div", "section", "article", "header", "footer", "tr"}
SKIP_TAGS = {"script", "style", "head", "meta", "link", "title"}


def extract_fragment(html: str) -> str:
    """Strip a Windows CF_HTML wrapper down to the actual HTML fragment."""
    m = re.search(r"<!--StartFragment-->(.*?)<!--EndFragment-->", html, re.S)
    if m:
        return m.group(1)
    # No comment markers: if it looks like a CF_HTML header, cut at the first tag.
    if re.match(r"^\s*(Version|StartHTML|SourceURL):", html):
        lt = html.find("<")
        if lt != -1:
            return html[lt:]
    return html


class MarkdownConverter(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.frames = [[]]          # output buffer stack (for blockquote/pre/cells)
        self.list_stack = []        # [{"type": "ul"|"ol", "idx": int}]
        self.link_hrefs = []        # stack of hrefs for nested <a>
        self.in_pre = False
        self.skip_depth = 0
        # Table state
        self.in_table = False
        self.table_rows = []
        self.row = None

    # --- buffer helpers ---
    def emit(self, s):
        self.frames[-1].append(s)

    def push_frame(self):
        self.frames.append([])

    def pop_frame(self):
        return "".join(self.frames.pop())

    # --- parser callbacks ---
    def handle_starttag(self, tag, attrs):
        if self.skip_depth or tag in SKIP_TAGS:
            if tag in SKIP_TAGS:
                self.skip_depth += 1
            return
        attrs = dict(attrs)

        if re.fullmatch(r"h[1-6]", tag):
            self.emit("\n\n" + "#" * int(tag[1]) + " ")
        elif tag in ("strong", "b"):
            self.emit("**")
        elif tag in ("em", "i"):
            self.emit("_")
        elif tag == "a":
            href = attrs.get("href", "")
            self.link_hrefs.append(href)
            if href:
                self.emit("[")
        elif tag == "code" and not self.in_pre:
            self.emit("`")
        elif tag == "pre":
            self.in_pre = True
            self.push_frame()
        elif tag == "blockquote":
            self.push_frame()
        elif tag == "hr":
            self.emit("\n\n---\n\n")
        elif tag == "br":
            self.emit("\n")
        elif tag in ("ul", "ol"):
            self.list_stack.append({"type": tag, "idx": 1})
        elif tag == "li":
            indent = "  " * (len(self.list_stack) - 1) if self.list_stack else ""
            top = self.list_stack[-1] if self.list_stack else {"type": "ul"}
            if top["type"] == "ol":
                marker = f"{top['idx']}. "
                top["idx"] += 1
            else:
                marker = "- "
            self.emit("\n" + indent + marker)
        elif tag == "table":
            self.in_table = True
            self.table_rows = []
        elif tag == "tr":
            self.row = []
        elif tag in ("td", "th"):
            self.push_frame()
        elif tag in BLOCK_TAGS:
            self.emit("\n\n")

    def handle_endtag(self, tag):
        if tag in SKIP_TAGS:
            if self.skip_depth:
                self.skip_depth -= 1
            return
        if self.skip_depth:
            return

        if re.fullmatch(r"h[1-6]", tag):
            self.emit("\n\n")
        elif tag in ("strong", "b"):
            self.emit("**")
        elif tag in ("em", "i"):
            self.emit("_")
        elif tag == "a":
            href = self.link_hrefs.pop() if self.link_hrefs else ""
            if href:
                self.emit(f"]({href})")
        elif tag == "code" and not self.in_pre:
            self.emit("`")
        elif tag == "pre":
            inner = self.pop_frame().strip("\n")
            self.in_pre = False
            self.emit("\n\n```\n" + inner + "\n```\n\n")
        elif tag == "blockquote":
            inner = self.pop_frame().strip("\n")
            quoted = "\n".join(
                ("> " + ln) if ln.strip() else ">" for ln in inner.split("\n")
            )
            self.emit("\n\n" + quoted + "\n\n")
        elif tag in ("ul", "ol"):
            if self.list_stack:
                self.list_stack.pop()
            if not self.list_stack:
                self.emit("\n")
        elif tag in ("td", "th"):
            cell = re.sub(r"\s+", " ", self.pop_frame()).strip()
            if self.row is not None:
                self.row.append(cell)
        elif tag == "tr":
            if self.row:
                self.table_rows.append(self.row)
            self.row = None
        elif tag == "table":
            self._flush_table()
            self.in_table = False
        elif tag in BLOCK_TAGS:
            self.emit("\n\n")

    def handle_data(self, data):
        if self.skip_depth:
            return
        if self.in_pre:
            self.emit(data)
        else:
            self.emit(re.sub(r"\s+", " ", data))

    def _flush_table(self):
        if not self.table_rows:
            return
        cols = max(len(r) for r in self.table_rows)
        rows = [r + [""] * (cols - len(r)) for r in self.table_rows]
        out = ["\n\n| " + " | ".join(rows[0]) + " |",
               "| " + " | ".join(["---"] * cols) + " |"]
        for r in rows[1:]:
            out.append("| " + " | ".join(r) + " |")
        self.emit("\n".join(out) + "\n\n")

    def result(self) -> str:
        text = "".join(self.frames[0])
        text = re.sub(r"[ \t]+\n", "\n", text)   # drop trailing spaces
        text = re.sub(r"\n{3,}", "\n\n", text)    # collapse blank runs
        return text.strip() + "\n"


def main() -> int:
    html = sys.stdin.read().lstrip("﻿")  # drop a leading BOM if present
    html = extract_fragment(html)
    parser = MarkdownConverter()
    parser.feed(html)
    parser.close()
    sys.stdout.write(parser.result())
    return 0


if __name__ == "__main__":
    sys.exit(main())
