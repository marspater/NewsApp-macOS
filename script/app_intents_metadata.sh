#!/bin/bash
# Source from the repository root after defining SWIFT_SOURCES and before invoking swiftc (#748). Plain swiftc skips
# Xcode's App Intents metadata step, so the bundle had no Metadata.appintents and Shortcuts and Spotlight could not
# see NewsShortcuts. NEWS_APP_INTENTS_FLAGS makes the compile emit the Swift const values the processor reads; after
# compiling, news_app_intents_metadata RESOURCES_DIR DEPLOYMENT_TARGET writes Metadata.appintents into the bundle.
NEWS_APP_INTENTS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/news-app-intents.XXXXXX")
# The conformances Xcode 27 gathers const values for (its <target>_const_extract_protocols.json).
echo '["AppIntent","EntityQuery","AppEntity","TransientEntity","AppEnum","AppShortcutProviding","AppShortcutsProvider","AnyResolverProviding","AppIntentsPackage","DynamicOptionsProvider","_IntentValueRepresentable","_AssistantIntentsProvider","_GenerativeFunctionExtractable","IntentValueQuery","Resolver","AppExtension","ExtensionPointDefining"]' \
    >"$NEWS_APP_INTENTS_DIR/protocols.json"
# One const values file per source in batch mode, or the module entry under whole-module optimization.
{
    printf '{"": {"const-values": "%s/module.swiftconstvalues"}' "$NEWS_APP_INTENTS_DIR"
    for source in "${SWIFT_SOURCES[@]}"; do
        printf ',\n"%s": {"const-values": "%s/%s.swiftconstvalues"}' "$source" "$NEWS_APP_INTENTS_DIR" "${source//\//_}"
    done
    echo '}'
} >"$NEWS_APP_INTENTS_DIR/output-file-map.json"
# The processor finds the App Shortcuts provider by its module-qualified name, so the module is always News.
# Caller scripts consume this array after sourcing; Bash arrays cannot be exported to child processes.
# shellcheck disable=SC2034
NEWS_APP_INTENTS_FLAGS=(-module-name News -emit-const-values -output-file-map "$NEWS_APP_INTENTS_DIR/output-file-map.json"
    -Xfrontend -const-gather-protocols-file -Xfrontend "$NEWS_APP_INTENTS_DIR/protocols.json")

news_app_intents_metadata() {
    local resources="$1" deployment_target="$2" swift sdk xcode_build
    # The const values name each file as swiftc was given it, so the list keeps the same relative paths.
    printf '%s\n' "${SWIFT_SOURCES[@]}" >"$NEWS_APP_INTENTS_DIR/sources.txt"
    find "$NEWS_APP_INTENTS_DIR" -name '*.swiftconstvalues' >"$NEWS_APP_INTENTS_DIR/constvalues.txt"
    swift=$(xcrun --find swift)
    sdk=$(xcrun --sdk macosx --show-sdk-path)
    xcode_build=$(xcodebuild -version | awk '/Build version/ {print $3}')
    xcrun appintentsmetadataprocessor --toolchain-dir "${swift%/usr/bin/swift}" --module-name News \
        --sdk-root "$sdk" --xcode-version "$xcode_build" --platform-family macOS \
        --deployment-target "$deployment_target" --target-triple "arm64-apple-macos${deployment_target}" \
        --source-file-list "$NEWS_APP_INTENTS_DIR/sources.txt" \
        --swift-const-vals-list "$NEWS_APP_INTENTS_DIR/constvalues.txt" --output "$resources" 2>&1 |
        grep -v '^[0-9-]* [0-9:.]* appintentsmetadataprocessor\[' || true
    rm -rf "$NEWS_APP_INTENTS_DIR"
    if [[ ! -f "$resources/Metadata.appintents/extract.actionsdata" ]]; then
        echo "❌ appintentsmetadataprocessor did not write $resources/Metadata.appintents" >&2
        return 1
    fi
}
