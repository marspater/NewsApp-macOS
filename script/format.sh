#!/bin/bash
# Formats or lints Swift source files using swift-format.
set -euo pipefail

cd "$(dirname "$0")/.."

# Every Swift file starts with the Apache-2.0 header (copy it from any Swift file; in Package.swift it follows the
# swift-tools-version line). Checked before swift-format is needed: --check runs in CI on the working tree, --staged
# in the pre-commit hook on the staged content. Paths stay NUL-delimited, so no name is quoted or split.
# Every Swift file under Sources/Intelligence also names its Angelia owner in a `// Angelia · <owner>` comment after
# the header (docs/ANGELIA.md, rule 6). Owned files elsewhere (Services, Storage, Models) carry the same comment but
# are not checked here: the register lists them.
LICENSE_HEADER='// Copyright 2026 Mars Pater
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.'
case "${1:-}" in
    --check|--lint-all) HEADER_SOURCE=tree ;;
    --staged|--lint-staged) HEADER_SOURCE=index ;;
    *) HEADER_SOURCE="" ;;
esac
if [[ -n "$HEADER_SOURCE" ]]; then
    MISSING=""
    UNOWNED=""
    while IFS= read -r -d '' file; do
        if [[ "$HEADER_SOURCE" == index ]]; then
            content=$(git show ":$file")
        elif [[ -f "$file" ]]; then
            content=$(<"$file")
        else
            continue
        fi
        [[ "$file" == Package.swift && "$content" == "// swift-tools-version"* ]] && content=${content#*$'\n'}
        [[ "$content" == "$LICENSE_HEADER"$'\n'* ]] || MISSING+="$file"$'\n'
        [[ "$file" != Sources/Intelligence/* || "$content" == *$'\n// Angelia · '* ]] || UNOWNED+="$file"$'\n'
    done < <(if [[ "$HEADER_SOURCE" == index ]]; then
        git diff --cached --name-only -z --diff-filter=d -- '*.swift'
    else
        git ls-files -z -- '*.swift'
    fi)
    if [[ -n "$MISSING" ]]; then
        echo "❌ These Swift files do not start with the Apache-2.0 license header (copy it from any Swift file):" >&2
        printf '%s' "$MISSING" >&2
        exit 1
    fi
    if [[ -n "$UNOWNED" ]]; then
        echo "❌ These Swift files do not name their Angelia owner (add '// Angelia · <owner> ...' after the header; see docs/ANGELIA.md):" >&2
        printf '%s' "$UNOWNED" >&2
        exit 1
    fi
fi

# Resolve swift-format executable
SWIFT_FORMAT=""
if command -v swift-format >/dev/null 2>&1; then
    SWIFT_FORMAT="swift-format"
elif xcrun --find swift-format >/dev/null 2>&1; then
    SWIFT_FORMAT="$(xcrun --find swift-format)"
elif command -v swift >/dev/null 2>&1; then
    SWIFT_FORMAT="swift format"
else
    if [[ -n "${CI:-}" ]]; then
        echo "❌ swift-format not found; refusing to pass the format check without a toolchain." >&2
        exit 1
    fi
    echo "⚠️ swift-format not found in PATH or Xcode toolchain. Skipping format." >&2
    exit 0
fi

CONFIG_ARG=()
if [[ -f ".swift-format" ]]; then
    CONFIG_ARG=(--configuration ".swift-format")
fi

run_format_file() {
    local file="$1"
    $SWIFT_FORMAT format -i "${CONFIG_ARG[@]}" "$file"
}

run_lint_file() {
    local file="$1"
    $SWIFT_FORMAT lint -s "${CONFIG_ARG[@]}" "$file"
}

MODE="${1:-}"

case "$MODE" in
    --staged)
        STAGED_FILES=$(git diff --cached --name-only --diff-filter=d | grep '\.swift$' || true)
        if [[ -n "$STAGED_FILES" ]]; then
            echo "🎨 Running swift-format on staged files..."
            while IFS= read -r file; do
                if [[ -f "$file" ]]; then
                    # If the file has unstaged modifications, do not auto-add unstaged lines
                    if ! git diff --quiet -- "$file"; then
                        if ! run_lint_file "$file" >/dev/null 2>&1; then
                            echo "❌ $file has unstaged changes and is not formatted." >&2
                            echo "   Run './script/format.sh $file' and stage your changes." >&2
                            exit 1
                        fi
                    else
                        run_format_file "$file"
                        git add "$file"
                    fi
                fi
            done <<< "$STAGED_FILES"
        fi
        ;;
    --lint-staged)
        STAGED_FILES=$(git diff --cached --name-only --diff-filter=d | grep '\.swift$' || true)
        if [[ -n "$STAGED_FILES" ]]; then
            while IFS= read -r file; do
                if [[ -f "$file" ]]; then
                    run_lint_file "$file"
                fi
            done <<< "$STAGED_FILES"
        fi
        ;;
    --all)
        echo "🎨 Formatting all Swift files in Sources and Tests..."
        # One process across all cores; one swift-format launch per file took several times longer.
        $SWIFT_FORMAT format -i --parallel -r "${CONFIG_ARG[@]}" Sources Tests
        echo "✅ Finished formatting all Swift files."
        ;;
    --check|--lint-all)
        echo "🔍 Linting all Swift files in Sources and Tests..."
        $SWIFT_FORMAT lint -s --parallel -r "${CONFIG_ARG[@]}" Sources Tests
        echo "✅ All Swift files pass formatting lint."
        ;;
    "")
        # Default: format staged files if any, otherwise print usage
        STAGED_FILES=$(git diff --cached --name-only --diff-filter=d | grep '\.swift$' || true)
        if [[ -n "$STAGED_FILES" ]]; then
            "$0" --staged
        else
            echo "Usage: $0 [--staged | --lint-staged | --all | --check | --lint-all | <file.swift> ...]"
        fi
        ;;
    *)
        # Format individual passed files
        for file in "$@"; do
            if [[ -f "$file" ]]; then
                echo "🎨 Formatting $file..."
                run_format_file "$file"
            else
                echo "⚠️ File not found: $file" >&2
            fi
        done
        ;;
esac
