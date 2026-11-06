#!/usr/bin/env python3
"""Check relative Markdown links and heading anchors in the repository's documents.

Checks every `[text](target)` whose target is not an external URL: the target
file must exist, and a `#fragment` must match a heading in the target file,
using GitHub's heading-id rules. Links and headings inside fenced code blocks
are ignored, as GitHub renders them literally. External URLs are not fetched; the pinned
commit links in the reviews are left to their readers. Run from the repository
root: `python3 scripts/check-links.py`. Exit code 1 lists every broken link.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOTS = ["README.md", "KNOWN_ISSUES.md", "SECURITY.md", "docs", "audits"]
LINK = re.compile(r"(?<!!)\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
HEADING = re.compile(r"^#{1,6}\s+(.*?)\s*#*\s*$", re.MULTILINE)
INLINE_CODE = re.compile(r"`[^`]*`")
FENCED_CODE = re.compile(r"^(`{3,}|~{3,})[^\n]*\n.*?^\1[ \t]*$", re.MULTILINE | re.DOTALL)


def prose(path: Path) -> str:
    """Return the file's text without fenced code blocks, which GitHub renders literally."""
    return FENCED_CODE.sub("", path.read_text(encoding="utf-8"))


def markdown_files() -> list[Path]:
    files: list[Path] = []
    for root in ROOTS:
        path = Path(root)
        if path.is_file():
            files.append(path)
        elif path.is_dir():
            files.extend(sorted(path.rglob("*.md")))
    return files


def github_anchor(heading: str) -> str:
    text = INLINE_CODE.sub(lambda m: m.group(0).strip("`"), heading)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = text.strip().lower()
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")


def anchors(path: Path) -> set[str]:
    found: dict[str, int] = {}
    result: set[str] = set()
    for match in HEADING.finditer(prose(path)):
        base = github_anchor(match.group(1))
        count = found.get(base, 0)
        result.add(base if count == 0 else f"{base}-{count}")
        found[base] = count + 1
    return result


def check(path: Path) -> list[str]:
    errors: list[str] = []
    for match in LINK.finditer(prose(path)):
        target = match.group(1)
        if target.startswith(("http://", "https://", "mailto:")):
            continue
        file_part, _, fragment = target.partition("#")
        resolved = path if file_part == "" else (path.parent / file_part).resolve()
        if not resolved.exists():
            errors.append(f"{path}: missing target {target}")
            continue
        if fragment and resolved.suffix == ".md" and fragment not in anchors(resolved):
            errors.append(f"{path}: no heading for {target}")
    return errors


def main() -> int:
    errors = [error for path in markdown_files() for error in check(path)]
    for error in errors:
        print(error)
    print(f"{len(errors)} broken link(s) in {len(markdown_files())} Markdown file(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
