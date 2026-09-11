#!/bin/bash
set -e

HOST_MACOS_VER=$(sw_vers -productVersion 2>/dev/null | cut -d. -f1,2 || echo "27.0")
TARGET_MACOS="${TARGET_MACOS:-$HOST_MACOS_VER}"

echo "Compiling tests for macOS ${TARGET_MACOS} ($(uname -m))..."
swiftc -O -target $(uname -m)-apple-macos${TARGET_MACOS} \
    DateParser.swift \
    FeedError.swift \
    IPAddressValidator.swift \
    SecureHTTPClient.swift \
    AppSettings.swift \
    FeedXMLParser.swift \
    WebContentExtractor.swift \
    NotificationService.swift \
    FeedFetcher.swift \
    JSONFeedParser.swift \
    ReadManager.swift \
    ThemeManager.swift \
    FeedArticle.swift \
    CacheManager.swift \
    AIManager.swift \
    FeedManager.swift \
    SavedStoriesManager.swift \
    OPMLManager.swift \
    NewsTests.swift \
    -o test_runner

echo "Running unit tests..."
./test_runner

# Clean up
rm -f test_runner
