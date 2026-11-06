#!/bin/bash
# Prints the test atoms that cover the changed Swift files, one per line: the staged files when a commit is in
# progress, else the working tree against HEAD. A changed test atom selects itself; a changed Sources/ file selects
# every atom whose test file names its type (the file's basename, up to any `+`). Any other change (test.sh,
# Tests/Runner.swift, scripts, resources, Package.swift, or a Sources/ file no atom names) prints every atom, so a
# selection never silently skips a test. Markdown and docs/ select nothing. No changed file prints nothing.
# ponytail: the hook calls this without GIT_INDEX_FILE, so `git commit -a` with other files staged by hand selects
# only the hand-staged ones; pass the list as arguments from the hook if that mix ever matters.
# Arguments replace the changed-file list: `script/changed_atoms.sh Sources/Services/IPAddressValidator.swift`.
set -e
cd "$(dirname "$0")/.."
if [[ $# -gt 0 ]]; then
    changed=$(printf '%s\n' "$@")
else
    changed=$(git diff --cached --name-only --diff-filter=d)
    [[ -z "$changed" ]] && changed=$(git diff --name-only --diff-filter=d HEAD)
fi
atoms=$(script/test_atoms.sh)
selected=""
while read -r file; do
    [[ -z "$file" ]] && continue
    case "$file" in
        *.md | docs/*) ;;
        Tests/*.swift)
            grep -qxF "$file" <<< "$atoms" || exec script/test_atoms.sh
            selected+="$file"$'\n'
            ;;
        Sources/*.swift)
            type=$(basename "$file" .swift)
            type=${type%%+*}
            # shellcheck disable=SC2086 # atom paths have no spaces
            hits=$(grep -lwF "$type" $atoms || true)
            [[ -z "$hits" ]] && exec script/test_atoms.sh
            selected+="$hits"$'\n'
            ;;
        *) exec script/test_atoms.sh ;;
    esac
done <<< "$changed"
printf '%s' "$selected" | sort -u
