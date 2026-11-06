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
    rsync -a --exclude .git --exclude .antigravity --exclude .claude --exclude .build --exclude build \
        --exclude '*.app' ./ "$STAGE/src/"
    # Observe native didFinish, rather than treating cancellation as a successful Web load.
    # This hook exists only in the staged verification bundle, never in shipping sources.
    python3 - "$STAGE/src/Sources/Views/Reader/ArticleWebView.swift" <<'PY_WEB'
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
    (cd "$STAGE/src" && NEWS_HARNESS=Tests/Harness/NativeReadingMemory.swift \
        NEWS_BUNDLE_ID=com.marspater.news.workloadcheck ./build.sh > "$OUTPUT/build.log" 2>&1)
    APP="$STAGE/src/NewsHarness.app"
    codesign --verify --deep --strict "$APP"
    WORKLOAD_STATUS=0
    "$APP/Contents/MacOS/NewsHarness" "$OUTPUT" > "$OUTPUT/workload.log" 2>&1 || WORKLOAD_STATUS=$?
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
SOURCE_ROOT=.
if [[ "${NEWS_NATIVE_BODY_COUNTS:-0}" == "1" ]]; then
    # Counted views (#778, Tests/Harness/ListInvalidationBaseline.swift): a staged copy of the checkout ticks the
    # harness's BodyCount at the top of each view body, the list's page fetch and the reader's revision query.
    # Shipping sources carry no counters.
    rsync -a --exclude .git --exclude .antigravity --exclude .claude --exclude .build --exclude build \
        --exclude '*.app' ./ "$STAGE/src/"
    for view in MainView SidebarView ArticleListView ArticleCardView EventCardView ArticleDetailView; do
        # The views live in sub-folders of Views (List, Reader, ...), so find each by name.
        file=$(find "$STAGE/src/Sources/Views" -name "$view.swift" -print -quit)
        if [[ -z "$file" ]]; then echo "❌ Counted view $view.swift not found under Sources/Views" >&2; exit 1; fi
        perl -0pi -e "s/(var body: some View \{)/\$1 let _ = BodyCount.tick(\"$view\");/" "$file"
    done
    perl -0pi -e 's/(private func fetchPage\([^{]*\{)/$1 BodyCount.tick("ListFetch");/' "$STAGE/src/Sources/Views/List/ArticleListView.swift"
    perl -0pi -e 's/(let revisions = try\? await articleStore\.database\.publisherContentRevisions)/BodyCount.tick("ReaderRevisionQuery"); $1/' \
        "$STAGE/src/Sources/Views/Reader/ArticleDetailView.swift"
    SOURCE_ROOT="$STAGE/src"
fi
# The harness app: the production sources with the harness as entry point (build.sh, NewsHarness target).
(cd "$SOURCE_ROOT" && NEWS_HARNESS="${NEWS_NATIVE_HARNESS:-Tests/Harness/NativePerformanceBaseline.swift}" \
    NEWS_APP_DIR="$STAGE/NewsHarness.app" ./build.sh)
"$STAGE/NewsHarness.app/Contents/MacOS/NewsHarness" "$OUTPUT"
echo "Native performance evidence: $OUTPUT"
