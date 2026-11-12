#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source script/paired_launch_wait.sh
read_fresh_launch_log() { printf '%s\n' "$MOCK_LINE"; }
MOCK_LINE='today_fresh_edition_ready outcome=confirmed '
wait_for_fresh_edition now $$ any
if wait_for_fresh_edition now $$ swapped; then exit 1; fi
MOCK_LINE='today_fresh_edition_ready outcome=swapped '
wait_for_fresh_edition now $$ swapped
MOCK_LINE=''
NEWS_PAIRED_SWAP_WAIT=1
if wait_for_fresh_edition now $$ any; then exit 1; fi
echo 'Fresh-edition wait checks passed.'
