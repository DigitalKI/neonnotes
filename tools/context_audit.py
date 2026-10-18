#!/usr/bin/env python3
"""Audit the project context kit.

Checks the hand-edited orientation docs for the failures that matter:
missing files, broken relative links, duplicate invariant IDs, unlinked ADRs,
and architecture-map coverage. Everything else is a warning.

Usage:
    python3 tools/context_audit.py            # audit the current project
    python3 tools/context_audit.py --root DIR

Exit codes: 0 = ok (warnings allowed), 1 = hard error.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

REQUIRED = [
    "AGENTS.md",
    "docs/architecture.md",
    "docs/invariants.md",
    "docs/roadmap.md",
    "docs/decisions.md",
]

LINK_RE = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
INV_RE = re.compile(r"\bINV-(\d{3})\b")
ADR_ID_RE = re.compile(r"\bADR-(\d{4})\b")


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def local_links(text: str) -> list[str]:
    out = []
    for target in LINK_RE.findall(text):
        target = target.split("#", 1)[0].strip()
        if not target or target.startswith(("http://", "https://", "mailto:", "res://", "user://")):
            continue
        out.append(target)
    return out


def audit(root: Path) -> int:
    errors: list[str] = []
    warnings: list[str] = []

    for rel in REQUIRED:
        if not (root / rel).is_file():
            errors.append(f"missing required context file: {rel}")

    # Relative links must resolve.
    for rel in REQUIRED:
        path = root / rel
        if not path.is_file():
            continue
        for target in local_links(read_text(path)):
            resolved = (path.parent / target).resolve()
            try:
                resolved.relative_to(root.resolve())
            except ValueError:
                warnings.append(f"{rel}: link escapes the repo: {target}")
                continue
            if not resolved.exists():
                errors.append(f"{rel}: broken link: {target}")

    # AGENTS.md must point at the kit.
    agents = read_text(root / "AGENTS.md")
    for needle in ("docs/architecture.md", "docs/invariants.md", "docs/gotchas.md", "docs/roadmap.md", "docs/decisions.md"):
        if needle not in agents:
            warnings.append(f"AGENTS.md does not mention {needle}")

    # Invariant IDs: unique, and each rule should link a guard.
    inv_text = read_text(root / "docs/invariants.md")
    ids = INV_RE.findall(inv_text)
    duplicates = sorted({i for i in ids if ids.count(i) > 1})
    for dup in duplicates:
        errors.append(f"duplicate invariant ID: INV-{dup}")
    # Check each INV bullet has a guard/code reference somewhere in its block.
    lines = inv_text.splitlines()
    for idx, line in enumerate(lines):
        if not INV_RE.search(line):
            continue
        block_lines = [line]
        for nxt in lines[idx + 1:]:
            if nxt.startswith("- **INV-") or nxt.startswith("## "):
                break
            block_lines.append(nxt)
        block = "\n".join(block_lines)
        referenced = any(
            marker in block
            for marker in (
                "Guard:",
                "guard:",
                ".gd",
                ".tscn",
                ".cfg",
                ".py",
                ".sh",
                ".gdshader",
                "Test",
                "unit_tests",
            )
        )
        if not referenced:
            warnings.append(f"INV-{INV_RE.search(line).group(1)} has no guard/code reference")

    # Decisions: every ADR file is linked from the index, and every linked ADR exists.
    decisions = read_text(root / "docs/decisions.md")
    linked = set()
    for target in local_links(decisions):
        if "ADR-" in target:
            linked.add(Path(target).name)
    adr_dir = root / "docs/decisions"
    if adr_dir.is_dir():
        for adr in sorted(adr_dir.glob("ADR-*.md")):
            if adr.name not in linked:
                errors.append(f"ADR not linked from docs/decisions.md: {adr.name}")
    for target in local_links(decisions):
        if "ADR-" in target:
            resolved = (root / "docs" / target).resolve()
            if not resolved.exists():
                errors.append(f"decisions.md links a missing ADR: {target}")

    # Architecture map coverage: let repo_map.py verify module paths.
    repo_map = root / "tools/repo_map.py"
    if repo_map.is_file():
        result = subprocess.run(
            [sys.executable, str(repo_map), "--root", str(root), "--check", "docs/architecture.md"],
            text=True,
            capture_output=True,
        )
        if result.returncode != 0:
            for line in (result.stdout + result.stderr).splitlines():
                if line.startswith("error:"):
                    errors.append(line.removeprefix("error:").strip())
                elif line.startswith("warning:"):
                    warnings.append(line.removeprefix("warning:").strip())
                elif line.startswith("  - "):
                    warnings.append(line.strip())
        else:
            for line in result.stderr.splitlines():
                if line.startswith("warning:"):
                    warnings.append(line.removeprefix("warning:").strip())
                elif line.startswith("  - "):
                    warnings.append(line.strip())
    else:
        warnings.append("tools/repo_map.py not found; skipped architecture coverage check")

    # Size warnings (not hard failures).
    for rel, limit in (("docs/architecture.md", 250), ("docs/invariants.md", 400), ("docs/roadmap.md", 150)):
        path = root / rel
        if path.is_file():
            n = len(read_text(path).splitlines())
            if n > limit:
                warnings.append(f"{rel} is {n} lines (soft limit {limit}); consider a deep-dive split")

    for e in errors:
        print(f"ERROR: {e}", file=sys.stderr)
    for w in warnings:
        print(f"WARN:  {w}", file=sys.stderr)
    print(f"context audit: {len(errors)} error(s), {len(warnings)} warning(s)")
    return 1 if errors else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".", help="project root (default: cwd)")
    args = parser.parse_args()
    root = Path(args.root).resolve()
    if not (root / "project.godot").is_file():
        print(f"error: no project.godot under {root}", file=sys.stderr)
        return 1
    return audit(root)


if __name__ == "__main__":
    raise SystemExit(main())
