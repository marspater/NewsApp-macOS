#!/bin/bash
# Every test suite runs exactly once: a Tests/*.swift file with an entry point (`static func run()` or `main()`) is
# either an atom Tests/Runner.swift dispatches (script/test_atoms.sh) or a suite another registered suite calls, and
# every dispatched atom exists. A new file that is neither is a suite nobody runs. One atom may dispatch
# several entry points of its file (FeedKitSwiftSoupTests runs twice in its one process); that is not a duplicate.
set -euo pipefail
cd "$(dirname "$0")/.."
status=0
atoms=$(script/test_atoms.sh)
for atom in $atoms; do
    [ -f "$atom" ] || { echo "❌ Runner.swift dispatches $atom, which does not exist"; status=1; }
done
for file in $(grep -lE 'static func (run|main)\(\)' Tests/*.swift); do
    [ "$file" = Tests/Runner.swift ] && continue
    grep -qxF "$file" <<< "$atoms" && continue
    type=$(basename "$file" .swift)
    # Called from another suite, as NewsTests runs EpicNE2ETests.
    grep -lE "\b$type\.(run|main)\(\)" Tests/*.swift | grep -v -x "$file" | grep -q . && continue
    echo "❌ $file has an entry point but nothing runs it: add it to Tests/Runner.swift"
    status=1
done
[ "$status" -eq 0 ] && echo "Test registry: every suite runs once ($(echo "$atoms" | wc -l | tr -d ' ') atoms)"
exit $status
