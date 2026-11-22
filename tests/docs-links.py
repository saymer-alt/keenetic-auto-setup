#!/usr/bin/env python3
"""Fail CI on broken local Markdown links or pasted chat/tool artifacts."""

from __future__ import annotations

import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
FENCE_RE = re.compile(r"^ {0,3}(`{3,}|~{3,})")
INLINE_CODE_RE = re.compile(r"(`+)(.+?)\1")
COMMENT_OPEN = "<!--"
# A link is `[label](dest)`. The destination may contain arbitrarily nested,
# balanced parentheses (`guide_(v2(beta)).md`, `…/a_(b(c))`); a regex with the
# balanced-paren alternation is not portable across regex engines and hits
# recursion limits at nested depths, so the matched content is balanced by hand
# in scan_destination(). This is not a full Markdown engine: only well-formed
# balanced destinations are consumed, an unterminated `(` is left unmatched.
LINK_OPEN_RE = re.compile(r"!?\[[^\]]*\]\(")
SCHEMES = {"http", "https", "mailto", "tel", "data"}
# Current user-facing KAS Web guides must not depend on a fast-moving beta tag.
# Historical ADRs, release transactions, CI fixtures, changelogs and the
# PANEL_UPDATE.md status/contract document are outside this guard: they need
# exact release IDs as evidence.
EVERGREEN_WEB_GUIDES = (
    "README.md",
    "docs/EN/README.md",
    "docs/26-kas-web-beta-install.md",
    "docs/EN/WEB_BETA_INSTALL.md",
    "web/control-center/packaging/README.md",
)
PINNED_WEB_PREVIEW = re.compile(
    r"\b(?:v\d+\.\d+\.\d+[-~])?beta[.~-]\d+\b"
    r"|https://github\.com/saymer-alt/keenetic-auto-setup/releases/"
    r"(?:tag|download)/v\d+\.\d+\.\d+-beta\.\d+",
    re.IGNORECASE,
)

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


def link_scan_view(text: str) -> str:
    """Mask HTML comments, fenced code blocks and inline code spans.

    Comments are masked before fence recognition, including consecutive
    comments on one line and comments spanning multiple lines. Backticks
    inside a comment must not alter the fence state.
    """
    lines: list[str] = []
    fence: str | None = None
    in_comment = False
    for line in text.split("\n"):
        if fence is not None:
            marker = FENCE_RE.match(line)
            if marker and marker.group(1)[0] == fence[0] and len(marker.group(1)) >= len(fence) \
                    and not line.strip().strip(fence[0]):
                fence = None
            lines.append("")
            continue

        if in_comment:
            end = line.find("-->")
            if end < 0:
                lines.append("")
                continue
            line = " " * (end + 3) + line[end + 3:]
            in_comment = False

        # Mask every complete comment, not just the first on the line.
        # An unclosed comment masks the remainder and continues on later lines.
        search_from = 0
        while True:
            start = line.find(COMMENT_OPEN, search_from)
            if start < 0:
                break
            end = line.find("-->", start + len(COMMENT_OPEN))
            if end < 0:
                line = line[:start]
                in_comment = True
                break
            line = line[:start] + " " * (end + 3 - start) + line[end + 3:]
            search_from = end + 3

        marker = FENCE_RE.match(line)
        if marker:
            fence = marker.group(1)
            lines.append("")
        else:
            lines.append(inline_code_only(line))
    return "\n".join(lines)


def inline_code_only(line: str) -> str:
    """Mask inline code spans, keeping the rest of a line intact."""
    return INLINE_CODE_RE.sub(lambda m: " " * len(m.group(0)), line)


def scan_destinations(text: str):
    """Yield raw link destinations from text, tracking balanced parentheses.

    Recognises `[label](dest)` where dest may contain arbitrarily nested
    balanced parentheses. Positional labels (`[x][id]`, `[x]: url`) are not
    link labels and are naturally skipped because they have no `(` right after
    the label. A `(` opened but never closed is left untouched (matches nothing).
    """
    pos = 0
    while True:
        m = LINK_OPEN_RE.search(text, pos)
        if m is None:
            return
        i = m.end()
        depth = 0
        j = i
        length = len(text)
        while j < length:
            ch = text[j]
            if ch == "(":
                depth += 1
            elif ch == ")":
                if depth == 0:
                    break
                depth -= 1
            elif ch in "\r\n" and depth == 0:
                break
            j += 1
        if depth == 0 and j < length and text[j] == ")":
            yield text[i:j]
            pos = j + 1
        else:
            # Unbalanced/unterminated destination: do not consume its '(' and
            # keep scanning after the label so later links still match.
            pos = m.start() + 1


def resolve(doc: Path, target: str) -> Path | None:
    if not target or target.startswith("#"):
        return None

    # Scheme-less web link: a bare authority is external, never a repository path.
    if target.lower().startswith("www."):
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

        for raw in scan_destinations(link_scan_view(text)):
            raw = destination(raw)
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

    pinned: list[tuple[str, str]] = []
    for relative in EVERGREEN_WEB_GUIDES:
        candidate = ROOT / relative
        if not candidate.is_file():
            pinned.append((relative, "missing expected evergreen guide"))
            continue
        match = PINNED_WEB_PREVIEW.search(candidate.read_text(encoding="utf-8"))
        if match:
            pinned.append((relative, f"pinned preview version/link: {match.group(0)}"))

    if pinned:
        for path, problem in pinned:
            print(f"[FAIL] {path}: {problem}", file=sys.stderr)
        return 1

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
    print("[OK] KAS Web guides: no pinned preview versions or retired release URLs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
