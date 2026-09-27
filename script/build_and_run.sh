#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./build.sh
# Close the previous reader only after a successful build.
pkill -x News 2>/dev/null || true
open -n "$PWD/News.app"
case "${1:-run}" in
    --verify) sleep 2; pgrep -x News ;;
    --debug) lldb -n News ;;
    --logs|--telemetry) log stream --info --predicate 'subsystem == "com.marspater.news"' ;;
    run) ;;
    *) echo "Usage: $0 [--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac
