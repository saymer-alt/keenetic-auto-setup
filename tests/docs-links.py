#!/usr/bin/env python3
"""Fail CI on broken local Markdown links or pasted chat/tool artifacts."""

from __future__ import annotations

import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
LINK_RE = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
SCHEMES = {"http", "https", "mailto", "tel", "data"}
ARTIFACT_PATTERNS = (
    ("sandbox path", re.compile(r"sandbox:/mnt/data/", re.IGNORECASE)),
    ("file citation token", re.compile(r"(?:filecite|turn\d+file\d+)", re.IGNORECASE)),
    ("chat timestamp wrapper", re.compile(r"\[Message sent at [^\]]+\]")),
    ("chat skipped-message wrapper", re.compile(r"Skipped \d+ messages?", re.IGNORECASE)),
    ("uploaded-file wrapper", re.compile(r"<<File name=", re.IGNORECASE)),
    ("writing-block fence", re.compile(r":::writing\b", re.IGNORECASE)),
)


def destination(raw: str) -> str:
    raw = raw.strip()
    if raw.startswith("<") and ">" in raw:
        return raw[1 : raw.index(">")]
    # Optional Markdown title follows the destination. Repository-local paths in
    # this project do not contain literal spaces; percent-encoded spaces remain valid.
    return raw.split(None, 1)[0]


def resolve(doc: Path, target: str) -> Path | None:
    if not target or target.startswith("#"):
        return None

    parsed = urlsplit(target)
    if parsed.scheme.lower() in SCHEMES or parsed.netloc:
        return None

    path = unquote(parsed.path)
    if not path:
        return None

    if path.startswith("/"):
        candidate = ROOT / path.lstrip("/")
    else:
        candidate = doc.parent / path

    try:
        return candidate.resolve()
    except OSError:
        return candidate


def main() -> int:
    broken: list[tuple[str, str, str]] = []
    artifacts: list[tuple[str, str]] = []
    checked = 0

    for doc in sorted(ROOT.rglob("*.md")):
        # Repository history/build artifacts are not present in this checkout;
        # every tracked Markdown document is otherwise in scope.
        text = doc.read_text(encoding="utf-8")
        for label, pattern in ARTIFACT_PATTERNS:
            if pattern.search(text):
                artifacts.append((str(doc.relative_to(ROOT)), label))

        for match in LINK_RE.finditer(text):
            raw = destination(match.group(1))
            candidate = resolve(doc, raw)
            if candidate is None:
                continue

            checked += 1
            try:
                candidate.relative_to(ROOT)
            except ValueError:
                broken.append((str(doc.relative_to(ROOT)), raw, "escapes repository root"))
                continue

            if not candidate.exists():
                broken.append(
                    (
                        str(doc.relative_to(ROOT)),
                        raw,
                        str(candidate.relative_to(ROOT)),
                    )
                )

    if checked == 0:
        print("[FAIL] Local Markdown link check scanned 0 links", file=sys.stderr)
        return 1

    if broken:
        for doc, raw, resolved in broken:
            print(f"[FAIL] {doc}: {raw} -> {resolved}", file=sys.stderr)
        print(f"[FAIL] {len(broken)} broken local Markdown link(s)", file=sys.stderr)
        return 1

    if artifacts:
        for doc, label in artifacts:
            print(f"[FAIL] {doc}: pasted {label} detected", file=sys.stderr)
        print(f"[FAIL] {len(artifacts)} Markdown chat/tool artifact(s)", file=sys.stderr)
        return 1

    print(f"[OK] Local Markdown links: {checked} checked, 0 broken")
    print("[OK] Markdown hygiene: 0 pasted chat/tool artifacts")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
