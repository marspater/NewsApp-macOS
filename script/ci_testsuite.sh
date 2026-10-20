#!/bin/bash
set -e

JUNIT_PATH="$1"
shift || true

START_TIME=$(date +%s)

# Run full test suite (or filtered if arguments provided)
./test.sh "$@"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

if [ -n "$JUNIT_PATH" ]; then
    mkdir -p "$(dirname "$JUNIT_PATH")"
    cat <<EOF > "$JUNIT_PATH"
<?xml version="1.0" encoding="UTF-8"?>
<testsuites name="NewsTests" tests="1" failures="0" errors="0" time="${DURATION}">
  <testsuite name="unit tests" tests="1" failures="0" errors="0" time="${DURATION}">
    <testcase name="NewsTests" classname="NewsTests" time="${DURATION}"/>
  </testsuite>
</testsuites>
EOF
fi
