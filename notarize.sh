#!/bin/bash
set -e

DMG_FILE="News-Universal2.dmg"

echo "=================================================="
echo "🛡️ Apple Notarization Pipeline (Optional / Future)"
echo "=================================================="

# Check if target DMG exists
if [ ! -f "${DMG_FILE}" ]; then
    echo "⚠️ Target package ${DMG_FILE} not found."
    echo "Please run ./package_dmg.sh first."
    exit 1
fi

# Detect authentication credentials
# Option 1: Keychain profile (recommended by Apple)
# Option 2: Apple ID + App-specific password + Team ID
if [ -n "${KEYCHAIN_PROFILE}" ]; then
    echo "🔑 Using Keychain Profile: ${KEYCHAIN_PROFILE}"
    AUTH_ARGS=(--keychain-profile "${KEYCHAIN_PROFILE}")
elif [ -n "${APPLE_ID}" ] && [ -n "${APPLE_ID_PASSWORD}" ] && [ -n "${TEAM_ID}" ]; then
    echo "🔑 Using Apple ID credentials for team: ${TEAM_ID}"
    AUTH_ARGS=(--apple-id "${APPLE_ID}" --password "${APPLE_ID_PASSWORD}" --team-id "${TEAM_ID}")
else
    echo "ℹ️ No Apple Developer credentials detected."
    echo ""
    echo "To notarize with an active Apple Developer Program membership:"
    echo "  Method 1 (Keychain Profile):"
    echo "    xcrun notarytool store-credentials \"notary-profile\" --apple-id <ID> --team-id <TEAM> --password <PWD>"
    echo "    KEYCHAIN_PROFILE=\"notary-profile\" ./notarize.sh"
    echo ""
    echo "  Method 2 (Environment Variables):"
    echo "    APPLE_ID=\"user@example.com\" \\"
    echo "    APPLE_ID_PASSWORD=\"xxxx-xxxx-xxxx-xxxx\" \\"
    echo "    TEAM_ID=\"ABC1234XYZ\" \\"
    echo "    ./notarize.sh"
    echo ""
    echo "⏭️ Skipping notarization (developer-account-independent pipeline)."
    exit 0
fi

echo "📤 Submitting ${DMG_FILE} to Apple Notarization Service..."
xcrun notarytool submit "${DMG_FILE}" "${AUTH_ARGS[@]}" --wait

echo "📎 Stapling notarization ticket to disk image..."
xcrun stapler staple "${DMG_FILE}"

echo "🔍 Validating stapled ticket..."
xcrun stapler validate "${DMG_FILE}"

echo "🎉 Notarization and ticket stapling complete!"
