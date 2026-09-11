#!/bin/bash
set -e

APP_NAME="News"
APP_DIR="${APP_NAME}.app"
DMG_NAME="News-Universal2.dmg"
ZIP_NAME="News-Universal2.zip"
VOLUME_NAME="News"
STAGING_DIR="/tmp/news_dmg_staging"

echo "=================================================="
echo "📦 Packaging Distribution Artifacts for ${APP_NAME}"
echo "=================================================="

# Ensure release app exists
if [ ! -d "${APP_DIR}" ]; then
    echo "⚠️ ${APP_DIR} not found. Running ./build_release.sh first..."
    ./build_release.sh
fi

# Clean previous distribution artifacts
rm -rf "${DMG_NAME}" "${ZIP_NAME}" "${DMG_NAME}.sha256" "${ZIP_NAME}.sha256" "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"

echo "📂 Staging Application bundle and Applications symlink..."
cp -R "${APP_DIR}" "${STAGING_DIR}/"
ln -s /Applications "${STAGING_DIR}/Applications"

# Remove hidden metadata files from staging
find "${STAGING_DIR}" -name ".DS_Store" -delete 2>/dev/null || true

echo "💿 Creating compressed read-only DMG (UDZO format)..."
hdiutil create \
    -volname "${VOLUME_NAME}" \
    -srcfolder "${STAGING_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_NAME}"

rm -rf "${STAGING_DIR}"

echo "🔍 Verifying DMG integrity..."
hdiutil verify "${DMG_NAME}"

echo "🗜️ Creating ZIP distribution archive..."
ditto -c -k --sequesterRsrc --keepParent "${APP_DIR}" "${ZIP_NAME}"

echo "🔒 Generating SHA-256 checksum digests..."
shasum -a 256 "${DMG_NAME}" > "${DMG_NAME}.sha256"
shasum -a 256 "${ZIP_NAME}" > "${ZIP_NAME}.sha256"

echo ""
echo "=================================================="
echo "✅ Distribution Packaging Complete!"
echo "=================================================="
echo "DMG:    ${DMG_NAME} ($(du -h "${DMG_NAME}" | cut -f1))"
echo "ZIP:    ${ZIP_NAME} ($(du -h "${ZIP_NAME}" | cut -f1))"
echo "DMG SHA-256: $(cat "${DMG_NAME}.sha256" | cut -d' ' -f1)"
echo "ZIP SHA-256: $(cat "${ZIP_NAME}.sha256" | cut -d' ' -f1)"
