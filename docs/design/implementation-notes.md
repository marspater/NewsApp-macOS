# Implementation notes

Platform workarounds, AppKit bridges, known bugs and OS-version restrictions behind the rules in [DESIGN.md](DESIGN.md). A note here explains how a rule is met; the rule itself stays in the design documents.

## AppKit-backed views and accessibility labels

**Symptom.** With an accessibility client reading the window (VoiceOver or automation), opening a story whose lead image had a credit or was still loading crashed the app: `EXC_BAD_ACCESS` (stack guard) with `AccessibilityNode.accessibilityLabel()` and `NSAccessibilityGetObjectValueForAttribute` repeating until the main-thread stack overflowed.

**Cause.** `accessibilityLabel` set directly on an AppKit-backed view (`ProgressView`, or `Text` with `.textSelection(.enabled)`), or such a view combined into a labelled element. SwiftUI and AppKit resolve each other's label without end. Found and fixed in #466 (`cba4bbd`).

**Pattern.** Hide the view with `.accessibilityHidden(true)` and label a plain container with `.accessibilityElement(children: .ignore)`.

**Affected versions.** #466 records none. It was reproduced on the macOS release in use in October 2026. Check again on each major macOS release before relaxing the rule.

**Regression protection.** `script/design_lint.sh` rejects such labels across a modifier chain and self-tests that check on every run. `NewsSmokeUITests.test07AccessibilityTreeWithImageCredit` and `test08AccessibilityTreeWithImageStillLoading` (#466) open a fixture story whose lead image has a credit and one whose image never finishes loading, then read every element label in the window, so the loop crashes the test. Fixtures: `Tests/Fixtures/ui-smoke/feed.xml` and `AppContainer.fixtureImageLoader` (an image URL containing `stall` never finishes at reader size). **Versions.** CI runs them in the UI Tests step of `ci.yml` on `macos-26` and on CircleCI `test-macos`; compiled locally only (`build-for-testing`) on macOS 27.2 with Xcode 27.0. The tests have not been run on macOS 27, and none was confirmed to fail with the labels restored.

## Notifications

- **Target delivery.** The panel has to survive every window state: it sets `canHide = false` and stops dismissing on `didHide` and last-window close. `UNUserNotificationCenter.add`, the `willPresent` path, `removeDeliveredNotifications` and the attachment renderer go. `requestAuthorization` and `notificationSettings()` stay.
- **Focus gate.** With the system path gone, `INFocusStatusCenter` is the only way to honour Focus. It is available from macOS 12 and requires the person's authorization (`requestAuthorization`); Apple's page names no entitlement. Whether it works in this sandboxed build is unverified. Verify it before removing notification-center delivery.
- **Current delivery, until the target lands.** News active with a window on screen: the story's entry is filed without the system banner and the app draws its own. Behind another app with a window on screen: the app draws and adds nothing (#926), because `willPresent` runs only while News is active and macOS cannot file an entry without its own banner outside it. Hidden, minimized or without a window: the system draws. Grouped and summary banners stay with the system.
- **Banner photo.** Core Image alpha fade and progressive blur (`maskedVariableBlur`), baked once per banner in `NotificationImage`.

## Glass and rendering

- `ImageRenderer` draws glass blank, so an offscreen capture of a glass surface is not evidence of how it looks.
- `backgroundExtensionEffect()` applies to an image touching both column edges. On an inset card it bleeds the image into the toolbar while the inset leaves the toolbar edges uncovered.
- The search item uses a narrow AppKit bridge to bound its width; SwiftUI keeps search focus, tokens and system glass.

## Hit testing

A clipped figure takes `contentShape(Rectangle())` after `clipped()` (or `allowsHitTesting(false)`), so an image that overflows its frame cannot take the click meant for the card above it.

## OS-version restrictions

| API | Availability | Note |
| --- | --- | --- |
| `visibilityPriority(_:)` | macOS 26.1 | `.low` and `.high`; the relative initializers need macOS 27 |
| `accessibilityShowBorders` | Back-deployed from macOS 11 | No availability check. Replaces `accessibilityShowButtonShapes` |
| `swipeActionsContainer()`, `.reorderable()` | macOS 27 | Behind `if #available(macOS 27, *)` |
| Liquid Glass APIs | macOS 26 | Gate with `if #available(macOS 26, *)` |

## Visual references

The images in `docs/mocks/today/` and `docs/mocks/briefing/` were exported from their design canvases on 9 November 2026 with `WKWebView` at 2× and saved as JPEG at 1×. They show the mock's CSS imitation of glass, not real Liquid Glass. Illustrative photos and headlines are placeholders.
