# Xcode Setup & Apple App Store Review Guide

This guide establishes the official specification and operating procedures for configuring Xcode, managing build schemes, complying with Apple's App Store Review Guidelines, and preparing **News for macOS** for App Store submission and Developer ID notarization.

---

## 1. Executive Summary & Review Scope

News is a native, local-first RSS, Atom, and JSON Feed reader built with SwiftUI, AppKit, WebKit, SQLite, and Apple's on-device intelligence frameworks.

| Attribute | Specification |
|:---|:---|
| **Target OS** | macOS 15.0+ (Sequoia) |
| **Architectures** | Apple Silicon (`arm64`) native |
| **Language & Toolchain** | Swift 6.0 (`-strict-concurrency=complete`) |
| **Sandboxing** | App Sandbox enabled (`com.apple.security.app-sandbox = true`) |
| **Security Runtime** | Hardened Runtime enabled with minimal entitlements |
| **Privacy Footprint** | Local-first, zero telemetry, zero analytics SDKs, zero cloud AI egress |
| **Primary Category** | News (`News & Magazines`) |
| **Age Rating** | 17+ (Unrestricted Web Access due to general RSS feed aggregation) |

---

## 2. Xcode Project Setup & Build Settings

News can be built directly using the included shell pipeline (`build.sh`, `build_release.sh`) or opened as a native Xcode Project / Swift Package workspace.

### 2.1 Workspace & Scheme Architecture

When opening in Xcode or generating an `.xcodeproj`:

1. **`News` (App Scheme)**:
   - Primary executable target compiling `Sources/`.
   - Linked frameworks: `SwiftSoup` (static), `FeedKit` (static), Apple SDKs (`Foundation`, `SwiftUI`, `AppKit`, `WebKit`, `Charts`, `SQLite3`, `NaturalLanguage`, `CoreML`, `CoreSpotlight`, `OSLog`).
   - Active scheme for Run, Test, Profile, and Archive.
2. **`NewsTests` (Test Scheme)**:
   - Compiles unit tests and E2E suites (`Tests/`).
   - Validates all parsing, security boundaries, classification, and situation board behaviors.

### 2.2 Recommended Xcode Build Settings

Configure the following build settings in Xcode to guarantee Apple compliance and performance:

```xcconfig
// Deployment & Architecture
MACOSX_DEPLOYMENT_TARGET = 15.0
ARCHS = arm64
ONLY_ACTIVE_ARCH = NO

// Swift 6 Language & Concurrency
SWIFT_VERSION = 6.0
SWIFT_STRICT_CONCURRENCY = complete
SWIFT_DEFAULT_ACTOR_ISOLATION = Complete
OTHER_SWIFT_FLAGS = $(inherited) -package-name News

// App Sandbox & Security
ENABLE_HARDENED_RUNTIME = YES
CODE_SIGN_ENTITLEMENTS = News.entitlements
CODE_SIGN_STYLE = Manual // or Automatic with Apple Developer Team
ENABLE_USER_SCRIPT_SANDBOXING = YES

// Code Generation & Optimization
SWIFT_OPTIMIZATION_LEVEL[config=Debug] = -Onone
SWIFT_OPTIMIZATION_LEVEL[config=Release] = -O
DEBUG_INFORMATION_FORMAT[config=Release] = dwarf-with-dsym

// Assets & App Icon
ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon
GENERATE_INFOPLIST_FILE = NO
INFOPLIST_FILE = News.app/Contents/Info.plist // or shared template
```

### 2.3 Entitlements Architecture (`News.entitlements`)

Apple strictly scrutinizes App Sandbox entitlements. News declares only the absolute minimum set required for feed reader functionality:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Mandatory for Mac App Store submission -->
    <key>com.apple.security.app-sandbox</key>
    <true/>

    <!-- Outbound network access to fetch public feeds, articles, and card images -->
    <key>com.apple.security.network.client</key>
    <true/>

    <!-- Ephemeral loopback listener strictly bound to 127.0.0.1 for SSRF prevention -->
    <key>com.apple.security.network.server</key>
    <true/>

    <!-- User-selected file access for OPML subscription import and export -->
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
</dict>
</plist>
```

> [!IMPORTANT]
> Apple App Reviewers will ask why `network.server` is declared. Document in the App Review Notes that it is **strictly an on-device loopback proxy** (`127.0.0.1`) that validates destination IP addresses to protect users against Server-Side Request Forgery (SSRF) and DNS rebinding attacks.

---

## 3. Apple App Store Review Guidelines Compliance Matrix

This section maps News directly against Apple's **App Store Review Guidelines**.

### Guideline 1: Safety

* **1.2 User-Generated Content & External Feeds**:
  - News acts as an open client for user-supplied RSS/Atom/JSON feeds.
  - To comply with UGC and content safety requirements:
    - Users can delete or unsubscribe from any feed at any time (`Edit > Delete`).
    - Users can mute offensive publisher domains or topic keywords (`Settings > Muting`).
    - Malformed or malicious feed payloads are neutralized by strict streaming XML/JSON parsers and SwiftSoup HTML sanitization.
* **WebKit & Browser Security**:
  - Web previews disable JavaScript execution by default to prevent cross-site scripting (XSS) and unvetted WebRTC sockets.
  - Native WebKit content rules block intranet IP ranges, numeric literals, and single-label hostnames.
  - Users have a one-click option to open any article in their system default browser (`⌘O`).
* **1.4 Physical Harm & Crisis Claims**:
  - The **World Tension Index** provides an automated heuristic score based on international news coverage.
  - The UI explicitly clarifies that this is an informational indicator derived from public headlines, not emergency civil defense alerting.

### Guideline 2: Performance

* **2.1 App Completeness**:
  - Zero placeholder buttons, lorem-ipsum copy, or non-functional features.
  - All empty states provide native `ContentUnavailableView` controls with actionable refresh or subscription buttons.
  - Graceful handling of network timeouts, offline states, and HTTP 429/503 backoff headers.
* **2.3 Accurate Metadata**:
  - Description clearly states that article summarization and event clustering run on-device using Apple Foundation Models and Natural Language, with no cloud transmission.
* **2.4 Hardware & Software Compatibility**:
  - Native Apple Silicon (`arm64`) execution.
  - Responsive window geometry supporting minimum width (720pt) up to ultra-wide displays (1600pt+).
  - Proper integration with macOS Stage Manager, Split View, and Full Screen modes.
  - Low Power Mode awareness: reduces background prefetching and suspends non-essential NLP queues when battery conservation is active.
* **2.5 Software Requirements**:
  - App Sandbox strictly enabled.
  - Zero private APIs or private framework linking (verified via `otool -L`).
  - Strict compliance with macOS 15.0+ Sequoia SDKs.

### Guideline 3: Business

* **3.1 Business Model & Monetization**:
  - The application is 100% free with no in-app purchases or paywalls.
  - Future StoreKit 2 monetization (Epic Parked #657) is completely isolated and omitted from this release.
* **3.1.3 Reader App & External Content**:
  - Unrestricted data export: users can export their entire subscription library to open OPML 2.0 format (`File > Export Subscriptions...`). Saved stories and read history export as JSON or Markdown (`File > Export Saved Stories`, `File > Export History`).

### Guideline 4: Design & Human Interface Guidelines (HIG)

* **4.1 Originality & System Citizenship**:
  - Follows Apple's macOS Sequoia design language and the project's [docs/DESIGN.md](DESIGN.md):
    - Unified window toolbar styling (`.windowToolbarStyle(.unified)`).
    - Standard macOS window controls (traffic lights) remain unobstructed.
    - System materials (`.ultraThinMaterial`, `NSVisualEffectView`) for sidebars and popovers.
    - Standard macOS keyboard shortcuts: New Briefing (`⌘N`), Refresh (`⌘R`), Preferences (`⌘,`), Close (`⌘W`), Find (`⌘F`), and keyboard navigation (`j` / `k` / `Return`).
* **Accessibility (a11y)**:
  - All icon buttons include `.accessibilityLabel` and `.help` tooltips.
  - Grouped cards use `.accessibilityElement(children: .combine)`.
  - Supports **Reduce Motion**: automatically disables hero carousel auto-advancing and cross-fading, locking the view to a static presentation.
  - Supports **Increase Contrast**: replaces translucent borders with high-contrast hairlines.
  - Supports **Reduce Transparency**: substitutes solid system surfaces for frosted materials.

### Guideline 5: Legal & Privacy

* **5.1.1 Data Collection & Storage**:
  - **Zero Telemetry**: No third-party SDKs (no Firebase, Sentry, Mixpanel, or Google Analytics).
  - All reading state, bookmarks, and cached overviews remain strictly on the user's Mac in `~/Library/Containers/com.marspater.news/`.
  - Spotlight integration (`CoreSpotlight`) indexes only articles explicitly saved by the user.
* **5.1.2 Privacy Manifest (`PrivacyInfo.xcprivacy`)**:
  - A verified `PrivacyInfo.xcprivacy` file is bundled at the root of `News.app/Contents/Resources/`:
    - `NSPrivacyTracking`: `<false/>`
    - `NSPrivacyCollectedDataTypes`: `<array/>` (Empty)
    - `NSPrivacyAccessedAPITypes`:
      - `NSPrivacyAccessedAPICategoryUserDefaults` (Reason: `CA92.1` — app settings storage).
      - `NSPrivacyAccessedAPICategoryFileTimestamp` (Reason: `C617.1` — cache invalidation and database timestamps).
* **Export Compliance (Encryption)**:
  - Uses standard HTTPS / TLS communication provided by Apple's `URLSession` and `Network.framework`.
  - Exempt from US Export Administration Regulations (EAR) under Category 5, Part 2 (mass market encryption for general consumer software). Set `ITSAppUsesNonExemptEncryption` to `<false/>` in `Info.plist`.

---

## 4. App Store Connect Submission Blueprint

### 4.1 Required Metadata

| Field | Recommended Copy / Value |
|:---|:---|
| **App Name** | `News` (or `News: Private RSS Reader`) |
| **Subtitle** | `Local, Private Feed Reader` |
| **Primary Category** | `News` |
| **Secondary Category** | `Utilities` |
| **Keywords** | `rss,feed reader,atom,json feed,privacy,offline reader,apple silicon,news` |
| **Support URL** | `https://github.com/marspater/NewsApp-macOS/issues` |
| **Marketing URL** | `https://github.com/marspater/NewsApp-macOS` |
| **Privacy Policy URL** | `https://github.com/marspater/NewsApp-macOS/blob/main/PRIVACY.md` |
| **Copyright** | `© 2026 Mars Pater` |

### 4.2 App Review Information (Notes for Reviewer)

Paste the following message into the **Review Notes** field in App Store Connect:

> **App Reviewer Notes**:
> 
> Thank you for reviewing News for macOS.
> 
> 1. **No Account Required**: The app is completely local-first and does not require user registration, login, or cloud credentials.
> 2. **Pre-Loaded Sample Content**: On first launch, the app offers an opt-in curated catalog of 38 verified public news feeds. Simply select any category (e.g. Technology, World) to immediately populate the reader.
> 3. **OPML Import**: You can also import any standard `.opml` file via `File > Import Subscriptions...`.
> 4. **Network Architecture & Entitlement Note**:
>    - The app declares `com.apple.security.network.server`. This is used exclusively for an ephemeral **on-device loopback proxy** bound to `127.0.0.1`.
>    - It performs address resolution and pins connections to numeric public endpoints, preventing Server-Side Request Forgery (SSRF) and DNS rebinding attacks when parsing user-submitted RSS links. No external server or LAN listener is opened.
> 5. **On-Device Intelligence**: All topic categorization, event clustering, and summarization run 100% locally on-device using Apple's `NaturalLanguage` and `FoundationModels` APIs. Zero user data or article text is transmitted to remote AI endpoints.

### 4.3 Screenshot Specifications

Prepare 5 screenshots matching Apple's macOS App Store resolution standards:
* **Resolution**: `2880 x 1800` (16:10 Retina) or `2560 x 1600`.
* **Format**: `.png` (24-bit RGB, no alpha).

| Screen | Caption / Visual Focus |
|:---|:---|
| **1. Situation Board** | Today's finite Briefing with 45s Hero Carousel, World Tension trendline, and categorized story tiles. |
| **2. Clean Reader View** | Distraction-free typography, publisher attribution badges, and passage citation highlights. |
| **3. Event Overview** | Multi-source event clusters detailing timelines and diverse editorial perspectives. |
| **4. World Tension Dashboard** | Seven-day tension sparkline, driving international headlines, and cited causal factors. |
| **5. Subscriptions & Privacy** | Curated starter catalog, OPML import/export, local storage metrics, and keyword muting. |

---

## 5. Build, Archiving & Notarization Pipeline

### 5.1 Producing the Release Archive via Command Line

To create a clean release build and archive using `xcodebuild`:

```bash
# 1. Clean build artifacts
rm -rf build/ News.xcarchive News.app

# 2. Build Release App Bundle
./build_release.sh

# 3. Create Xcode Archive (for App Store Connect or Notarization)
xcodebuild archive \
  -scheme News \
  -destination 'generic/platform=macOS' \
  -archivePath "build/News.xcarchive"
```

### 5.2 Direct Developer ID Notarization (Outside App Store)

If distributing directly via website/DMG with Developer ID:

```bash
# 1. Package compressed disk image
./script/distribution/package_dmg.sh

# 2. Submit to Apple Notary Service
# (Requires credentials stored via xcrun notarytool store-credentials)
KEYCHAIN_PROFILE="notary-profile" ./script/distribution/notarize.sh

# 3. Verify Gatekeeper Acceptance
spctl -a -vv -t install News-arm64.dmg
```

### 5.3 App Store Connect Upload

To export and upload directly to TestFlight / App Store Connect:

```bash
# Export using App Store distribution profile
xcodebuild -exportArchive \
  -archivePath "build/News.xcarchive" \
  -exportOptionsPlist "script/distribution/ExportOptions-AppStore.plist" \
  -exportPath "build/AppStoreExport"

# Validate and upload via altool
xcrun altool --validate-app \
  -f "build/AppStoreExport/News.pkg" \
  -t macos \
  --apiKey "YOUR_KEY_ID" \
  --apiIssuer "YOUR_ISSUER_UUID"

xcrun altool --upload-app \
  -f "build/AppStoreExport/News.pkg" \
  -t macos \
  --apiKey "YOUR_KEY_ID" \
  --apiIssuer "YOUR_ISSUER_UUID"
```

---

## 6. Pre-Submission Release Checklist

Execute this checklist before submitting every release candidate:

### Build & Integrity
- [ ] `./build_release.sh` finishes with exit code `0`.
- [ ] Binary architecture is strictly `arm64`: `lipo News.app/Contents/MacOS/News -verify_arch arm64`.
- [ ] Strict code signature passes: `codesign --verify --deep --strict News.app`.
- [ ] Entitlements match `News.entitlements`: `codesign -d --entitlements :- News.app`.

### Testing & QA
- [ ] Full regression suite passes: `./test.sh` (100% tests green).
- [ ] Native UI QA suite passes: `./script/test_native_ui_qa.sh`.
- [ ] Design language linter passes: `./script/design_lint.sh` (0 new deviations).
- [ ] Swift code formatting passes: `./script/format.sh --check`.

### Apple HIG & Accessibility
- [ ] Standard window traffic lights are functional and unobstructed.
- [ ] All icon buttons have `.accessibilityLabel` and `.help` tooltips.
- [ ] VoiceOver reads story tiles with headline, source, and relative time.
- [ ] Reduce Motion properly stops carousel animation (`activeIndex = 0`).
- [ ] Increase Contrast renders crisp 0.5pt/1pt borders on cards and citation pills.

### Privacy & Manifest
- [ ] `PrivacyInfo.xcprivacy` is present in `News.app/Contents/Resources/`.
- [ ] `ITSAppUsesNonExemptEncryption` is set to `<false/>` in `Info.plist`.
- [ ] App Store Connect Privacy Questionnaire marked as **"Data Not Collected"**.
- [ ] Review Notes contain the required loopback proxy and on-device NLP disclosures.
