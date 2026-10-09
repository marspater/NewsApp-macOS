#!/bin/bash
set -euo pipefail

# Jules environment setup; see JULES.md. The Jules UI setup script sources it:
#   . script/jules_setup.sh
# Sourcing keeps the swiftly PATH in the shell Jules snapshots.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# Linux-runnable part of ./test.sh (stdlib-only offline checks).
python3 script/evaluation/evaluate.py
python3 script/evaluation/publisher_review.py
python3 script/evaluation/publisher_dates.py

# Swift 6.4 for `swiftc -parse` syntax checks only.
# Run swiftly outside the checkout so it writes no .swift-version into the repo.
cd /tmp
curl -fsSLO "https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz"
tar zxf "swiftly-$(uname -m).tar.gz"
./swiftly init --quiet-shell-followup --assume-yes --skip-install
# shellcheck source=/dev/null
. "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh"
swiftly install --use --assume-yes --post-install-file=/tmp/swift-post-install.sh 6.4.0
swiftly link || true
hash -r

# The image's apt lists are stale; refresh them before installing toolchain dependencies.
if [ -s /tmp/swift-post-install.sh ]; then
  sudo apt-get update -qq
  sudo bash /tmp/swift-post-install.sh
fi
swiftc --version

# Setup must leave the checkout clean.
cd "$root"
test -z "$(git status --porcelain)"
