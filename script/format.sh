#!/bin/bash
# Formats or lints Swift source files using swift-format.
set -euo pipefail

cd "$(dirname "$0")/.."

# Resolve swift-format executable
SWIFT_FORMAT=""
if command -v swift-format >/dev/null 2>&1; then
    SWIFT_FORMAT="swift-format"
elif xcrun --find swift-format >/dev/null 2>&1; then
    SWIFT_FORMAT="$(xcrun --find swift-format)"
elif command -v swift >/dev/null 2>&1; then
    SWIFT_FORMAT="swift format"
else
    echo "⚠️ swift-format not found in PATH or Xcode toolchain. Skipping format." >&2
    exit 0
fi

CONFIG_ARG=()
if [ -f ".swift-format" ]; then
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
        if [ -n "$STAGED_FILES" ]; then
            echo "🎨 Running swift-format on staged files..."
            while IFS= read -r file; do
                if [ -f "$file" ]; then
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
        if [ -n "$STAGED_FILES" ]; then
            while IFS= read -r file; do
                if [ -f "$file" ]; then
                    run_lint_file "$file"
                fi
            done <<< "$STAGED_FILES"
        fi
        ;;
    --all)
        echo "🎨 Formatting all Swift files in Sources and Tests..."
        find Sources Tests -name "*.swift" | sort | while IFS= read -r file; do
            run_format_file "$file"
        done
        echo "✅ Finished formatting all Swift files."
        ;;
    --lint-all)
        echo "🔍 Linting all Swift files in Sources and Tests..."
        find Sources Tests -name "*.swift" | sort | while IFS= read -r file; do
            run_lint_file "$file"
        done
        echo "✅ All Swift files pass formatting lint."
        ;;
    "")
        # Default: format staged files if any, otherwise print usage
        STAGED_FILES=$(git diff --cached --name-only --diff-filter=d | grep '\.swift$' || true)
        if [ -n "$STAGED_FILES" ]; then
            "$0" --staged
        else
            echo "Usage: $0 [--staged | --lint-staged | --all | --lint-all | <file.swift> ...]"
        fi
        ;;
    *)
        # Format individual passed files
        for file in "$@"; do
            if [ -f "$file" ]; then
                echo "🎨 Formatting $file..."
                run_format_file "$file"
            else
                echo "⚠️ File not found: $file" >&2
            fi
        done
        ;;
esac
