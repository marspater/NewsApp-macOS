#!/bin/bash
# Source from the repository root. Sets NEWS_VERSION (latest X.Y.Z tag, "v" stripped; 0.0.0 without one) and
# NEWS_BUILD (commit count) so build.sh and build_release.sh stamp the same version on the same commit.
NEWS_VERSION=$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' --match '[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || true)
NEWS_VERSION="${NEWS_VERSION#v}"
[[ "$NEWS_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || NEWS_VERSION="0.0.0"
# shellcheck disable=SC2034
NEWS_BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
