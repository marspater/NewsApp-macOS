#!/bin/bash
# Phase 0 only: seed SQLite and evaluate the pre-model matrix. No Core ML or vDSP execution.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
exec python3 -m script.evaluation.editorial_matrix "$@"
