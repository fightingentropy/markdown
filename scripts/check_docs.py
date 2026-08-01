#!/usr/bin/env python3
"""Fail when repository Markdown contains broken or machine-local links."""

from __future__ import annotations

import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parent.parent
LINK = re.compile(r"(?<!!)\[[^\]]*\]\(([^)]+)\)")


def main() -> int:
    failures: list[str] = []
    for document in sorted(ROOT.rglob("*.md")):
        if any(part.startswith(".") or part in {"build", "DerivedData"} for part in document.relative_to(ROOT).parts):
            continue
        text = document.read_text(encoding="utf-8")
        for match in LINK.finditer(text):
            raw = match.group(1).strip().strip("<>")
            target = raw.split(maxsplit=1)[0]
            parsed = urlsplit(target)
            if parsed.scheme in {"http", "https", "mailto"} or target.startswith("#"):
                continue
            line = text.count("\n", 0, match.start()) + 1
            if target.startswith(("/", "~")):
                failures.append(f"{document.relative_to(ROOT)}:{line}: machine-local link {target}")
                continue
            path = (document.parent / unquote(parsed.path)).resolve()
            try:
                path.relative_to(ROOT)
            except ValueError:
                failures.append(f"{document.relative_to(ROOT)}:{line}: link escapes repository {target}")
                continue
            if not path.exists():
                failures.append(f"{document.relative_to(ROOT)}:{line}: missing target {target}")

    if failures:
        print("Documentation link check failed:", file=sys.stderr)
        print("\n".join(f"- {failure}" for failure in failures), file=sys.stderr)
        return 1
    print("Documentation links are repository-relative and resolve locally.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
