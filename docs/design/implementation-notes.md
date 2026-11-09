# Implementation notes

Platform workarounds, AppKit bridges, known bugs and OS-version restrictions behind the rules in [DESIGN.md](DESIGN.md). A note here explains how a rule is met; the rule itself stays in the design documents.

## AppKit-backed views and accessibility labels

**Symptom.** With an accessibility client reading the window (VoiceOver or automation), opening a story whose lead image had a credit or was still loading crashed the app: `EXC_BAD_ACCESS` (stack guard) with `AccessibilityNode.accessibilityLabel()` and `NSAccessibilityGetObjectValueForAttribute` repeating until the main-thread stack overflowed.

**Cause.** `accessibilityLabel` set directly on an AppKit-backed view (`ProgressView`, or `Text` with `.textSelection(.enabled)`), or such a view combined into a labelled element. SwiftUI and AppKit resolve each other's label without end. Found and fixed in #466 (`cba4bbd`).

**Pattern.** Hide the view with `.accessibilityHidden(true)` and label a plain container with `.accessibilityElement(children: .ignore)`.

**Affected versions.** #466 records none. It was reproduced on the macOS release in use in October 2026. Check again on each major macOS release before relaxing the rule.

**Regression protection.** `script/design_lint.sh` rejects such labels across a modifier chain and self-tests that check on every run. This is a static check: no runtime test exercises the crash path yet. A UI test that opens a story with a credit and a loading image while reading the accessibility tree is the missing piece.

## Notifications

- **Delivery.** The panel (`StoryBannerPresenter`) is the only path: `canHide = false`, and nothing dismisses it on hide, miniaturize or window close. `UNUserNotificationCenter` is used for `requestAuthorization` and `notificationSettings()` only; there is no `add`, `willPresent` or attachment renderer. `BannerGate` reads permission, alert style, previews and Focus before each banner, and a click brings News's window forward through `MainWindowMarker` and a reopen (`NSWorkspace.openApplication`).
- **Focus gate.** `INFocusStatusCenter` is the only way to honour Focus. Probed on 9 November 2026 in a sandboxed, ad-hoc-signed app: it works with `NSFocusStatusUsageDescription` in `Info.plist` and no entitlement (without the key, macOS aborts the app on the request); authorization came back authorized and `isFocused` non-nil. `isFocused == true` was not observed. It is asked next to the notification permission.
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
