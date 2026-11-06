#!/bin/bash
# Every test suite runs exactly once: a Tests/*.swift file with a `run()`, `main()`, or `runAllTests()` entry point is
# either an atom Tests/Runner.swift dispatches (script/test_atoms.sh) or a suite another registered suite calls, and
# every dispatched atom exists. A new file that is neither is a suite nobody runs. One atom may dispatch
# several entry points of its file (FeedKitSwiftSoupTests runs twice in its one process); that is not a duplicate.
set -euo pipefail
cd "$(dirname "$0")/.."
status=0
atoms=$(script/test_atoms.sh)
for atom in $atoms; do
    [ -f "$atom" ] || { echo "❌ Runner.swift dispatches $atom, which does not exist"; status=1; }
    type=$(basename "$atom" .swift)
    grep -qE "\b$type\.(run|main|runAllTests)\(" Tests/Runner.swift || {
        echo "❌ $atom is registered but its suite is not called by Runner.swift"; status=1;
    }
done
for file in $(grep -lE 'static func (run|main|runAllTests)\(\)' Tests/*.swift); do
    [ "$file" = Tests/Runner.swift ] && continue
    grep -qxF "$file" <<< "$atoms" && continue
    type=$(basename "$file" .swift)
    # Called from another suite, as NewsTests runs EpicNE2ETests.
    grep -lE "\b$type\.(run|main|runAllTests)\(\)" Tests/*.swift | grep -v -x "$file" | grep -q . && continue
    echo "❌ $file has an entry point but nothing runs it: add it to Tests/Runner.swift"
    status=1
done
# A domain atom (a file with its own test list) never runs in a targeted mode: `--story-regressions` runs only itself.
for file in $(grep -lE 'try await runSharded\(tests\)' Tests/*.swift); do
    [ "$file" = Tests/NewsTests.swift ] && continue
    grep -qF "selected(\"$file\"), !targetedMode" Tests/Runner.swift || {
        echo "❌ $file must be dispatched with !targetedMode in Tests/Runner.swift"; status=1;
    }
done
[ "$status" -eq 0 ] && echo "Test registry: every suite runs once ($(echo "$atoms" | wc -l | tr -d ' ') atoms)"
exit $status
