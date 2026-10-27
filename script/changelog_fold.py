#!/usr/bin/env python3
"""Fold CHANGELOG.d fragments into CHANGELOG.md under the Unreleased heading.

Each fragment is CHANGELOG.d/<issue>[-<slug>].md with one or more "- " bullet lines. Fragments are inserted
newest issue first, above the bullets already under the heading, and deleted. `--check` only reports what would
be folded and exits 1 when fragments exist, for a release gate; `--dry-run` prints the result without writing.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHANGELOG = ROOT / "CHANGELOG.md"
FRAGMENTS = ROOT / "CHANGELOG.d"
HEADING = re.compile(r"^## ")


def fragments():
    files = [p for p in FRAGMENTS.glob("*.md") if p.name != "README.md"]

    def key(path):
        match = re.match(r"(\d+)", path.stem)
        return (-int(match.group(1)) if match else 0, path.name)

    return sorted(files, key=key)


def bullets(path):
    lines = [line.rstrip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    bad = [line for line in lines if not line.startswith("- ")]
    if bad:
        sys.exit(f"{path.relative_to(ROOT)}: every line must be a '- ' bullet, found: {bad[0][:60]!r}")
    return lines


def fold(text, entries):
    lines = text.splitlines()
    for index, line in enumerate(lines):
        if HEADING.match(line):
            insert = index + 1
            while insert < len(lines) and not lines[insert].strip():
                insert += 1
            return "\n".join(lines[:index + 1] + [""] + entries + lines[insert:]) + "\n"
    sys.exit("CHANGELOG.md has no '## ' heading to fold under")


def main(argv):
    check = "--check" in argv
    dry = "--dry-run" in argv
    files = fragments()
    if not files:
        print("No changelog fragments to fold.")
        return 0
    entries = [line for path in files for line in bullets(path)]
    for path in files:
        print(f"{'would fold' if check or dry else 'folding'} {path.relative_to(ROOT)}")
    if check:
        return 1
    folded = fold(CHANGELOG.read_text(encoding="utf-8"), entries)
    if dry:
        print(folded[:2000])
        return 0
    CHANGELOG.write_text(folded, encoding="utf-8")
    for path in files:
        path.unlink()
    print(f"Folded {len(entries)} entries from {len(files)} fragments into CHANGELOG.md.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
