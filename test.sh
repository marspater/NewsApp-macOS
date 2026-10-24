#!/bin/bash
set -e

TEST_OPT_FLAGS=()
for argument in "$@"; do
    if [[ "$argument" == "--performance-baseline" || "$argument" == "--transport-cancellation" || "$argument" == "--publisher-cancellation" ]]; then TEST_OPT_FLAGS=(-O); fi
done

script/design_lint.sh
python3 script/evaluation/evaluate.py
python3 script/evaluation/publisher_review.py
python3 script/evaluation/publisher_dates.py
python3 script/evaluation/overview_review.py
python3 script/evaluation/importance_review.py
python3 script/evaluation/relation_review.py
python3 script/evaluation/catalog_review.py
python3 script/evaluation/fit_pair_head.py
python3 script/training/pretrain_pairs.py --self-check

script/build_test_runner.sh test_runner "${TEST_OPT_FLAGS[@]}"

echo "Running unit tests..."
./test_runner "$@"

# Clean up
rm -f test_runner
