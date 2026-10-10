#!/bin/bash
set -euo pipefail

# Compile real views with an isolated AppKit entry point. The opt-in combined workload uses
# a separate sandboxed bundle and the production cache setup, without notification authorization.
cd "$(dirname "$0")/.."
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/news-native-build.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
OUTPUT="${1:-$(mktemp -d "${TMPDIR:-/tmp}/news-native-results.XXXXXX")}"
mkdir -p "$OUTPUT"
OUTPUT=$(cd "$OUTPUT" && pwd)
if [[ "${NEWS_READING_FULL_APP:-0}" == "1" ]]; then
    # Reuse the app-bundle build and production entitlements; never replace the installed app.
    rsync -a --exclude .git --exclude .antigravity --exclude .claude --exclude .build --exclude '*.app' ./ "$STAGE/src/"
    sed -i '' '/^@main$/d' "$STAGE/src/Sources/App/NewsApp.swift"
    sed -i '' 's|Sources/App/NewsApp.swift \\|Sources/App/NewsApp.swift Tests/NativeReadingMemory.swift \\|; s|<string>com.marspater.news</string>|<string>com.marspater.news.workloadcheck</string>|' "$STAGE/src/build.sh"
    # Observe native didFinish, rather than treating cancellation as a successful Web load.
    # This hook exists only in the staged verification bundle, never in shipping sources.
    python3 - "$STAGE/src/Sources/Views/ArticleWebView.swift" <<'PY_WEB'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
source = path.read_text()
needle = """        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard self.webView === webView, navigation === activeNavigation else { return }
"""
assert source.count(needle) == 1
source = source.replace(needle, needle + '            NotificationCenter.default.post(name: Notification.Name("workloadWebFinished"), object: nil)\n')
path.write_text(source)
PY_WEB
    (cd "$STAGE/src" && ./build.sh > "$OUTPUT/build.log" 2>&1)
    codesign --verify --deep --strict "$STAGE/src/News.app"
    WORKLOAD_STATUS=0
    "$STAGE/src/News.app/Contents/MacOS/News" "$OUTPUT" > "$OUTPUT/workload.log" 2>&1 || WORKLOAD_STATUS=$?
    python3 - "$OUTPUT" "$(git rev-parse HEAD)" "$(git status --porcelain --untracked-files=no)" <<'PY_REPORT'
import base64, json, pathlib, shutil, subprocess, sys
out = pathlib.Path(sys.argv[1])
line = next(line for line in (out / "workload.log").read_text().splitlines() if line.startswith("WORKLOAD_REPORT="))
report = json.loads(base64.b64decode(line.split("=", 1)[1]))
report["source_revision"] = sys.argv[2]
report["source_has_local_changes"] = bool(sys.argv[3])
report["hardware"] = subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string", "hw.model"], text=True).splitlines()
report["toolchain"] = subprocess.check_output(["xcrun", "swift", "--version"], text=True).strip()
report["bundle_identifier"] = "com.marspater.news.workloadcheck"
image = next(line.split("=", 1)[1] for line in (out / "workload.log").read_text().splitlines() if line.startswith("WORKLOAD_IMAGE="))
shutil.copyfile(image, out / "overview.png")
(out / "reading-memory.json").write_text(json.dumps(report, indent=2) + "\n")
assert report["complete"] and len(report["web"]) == 5 and len(report["overviews"]) == 10
PY_REPORT
    echo "Combined app workload evidence: $OUTPUT"
    exit "$WORKLOAD_STATUS"
fi
sed '/^@main$/d' Sources/App/NewsApp.swift > "$STAGE/NewsApp.swift"
SOURCES=()
while IFS= read -r source; do
    if [[ "$source" != "Sources/App/NewsApp.swift" ]]; then SOURCES+=("$source"); fi
done < <(find Sources -name '*.swift' -print | sort)
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/news-module-cache}"
export SWIFT_MODULECACHE_PATH="$CLANG_MODULE_CACHE_PATH"
swiftc -swift-version 6 -O -parse-as-library -target arm64-apple-macos15.0 \
    "${SOURCES[@]}" "$STAGE/NewsApp.swift" "${NEWS_NATIVE_HARNESS:-Tests/NativePerformanceBaseline.swift}" -o "$STAGE/news_native_baseline"
"$STAGE/news_native_baseline" "$OUTPUT"
echo "Native performance evidence: $OUTPUT"
