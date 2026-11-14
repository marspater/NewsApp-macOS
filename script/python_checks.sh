#!/bin/bash
# The Python tooling's self-checks and unit tests: part of the plain ./test.sh gate, and CircleCI `checks` runs them
# on every push, so a change to the tooling alone needs no macOS run (script/ci_changes.sh). One list for both.
set -euo pipefail
cd "$(dirname "$0")/.."

for check in evaluate publisher_review publisher_dates overview_review importance_review relation_review lead_review \
    catalog_review fit_pair_head calibrate_tension; do
    python3 "script/evaluation/$check.py"
done
python3 script/training/pretrain_pairs.py --self-check
python3 -m unittest discover -s script/evaluation -p 'test_*.py'
