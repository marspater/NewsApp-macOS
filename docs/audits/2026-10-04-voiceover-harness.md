# Isolated native accessibility harness — 4 October 2026

Refs #155. This harness provides rendered accessibility and interaction evidence. It does not complete the manual VoiceOver acceptance criterion.

## Fixture and isolation

`script/test_voiceover_live_qa.sh` compiles the production views with a separate test entry point into an ad-hoc-signed arm64 bundle (`com.marspater.news.voiceoverqa`, macOS 15 deployment target). Each host uses temporary SQLite storage and a unique defaults suite, including SwiftUI `@AppStorage`. Feeds, AI generation and scheduled refresh are disabled. Fixture publications use reserved `.invalid` URLs; an environment image loader supplies a decoded in-memory image. The default application image loader still calls `SecureHTTPClient`. The overview fixture omits its optional decorative hero because that view uses a separate `AsyncImage` path; hero-image loading is outside this harness coverage.

No production bundle is installed or replaced. The harness does not toggle VoiceOver or other system accessibility settings. AppKit saved-window restoration is disabled in the fixture's volatile argument domain to avoid crash-recovery dialogs. Apple documents `ApplePersistenceIgnoreState` for [automated tests and debugging](https://developer.apple.com/library/archive/releasenotes/AppKit/RN-AppKitOlderNotes/).

## Repairs

- A synchronous `NSApplication.run()` owns the native main run loop; async setup starts from the application delegate.
- Nonblocking pipe reads handle partial lines, EOF, cancellation, wrong acknowledgements and monotonic deadlines. Compile and automated runtime watchdogs cap whole process groups at 300 and 120 seconds.
- AX messages have a 0.2-second timeout, and tree traversal has a three-second / 1,000-node budget. The inspector queries supported attributes and reports unmet prerequisites or missing state as failures.
- Fixture modes use fresh hosting views. Replacing a live navigation split view with a navigation stack in the same graph reproduced a SwiftUI accessibility stack overflow; independent fixture graphs avoid that invalid test transition.
- The harness invokes actual accessibility read/save actions and verifies production manager state and SQLite persistence. It expands event coverage and the Sources disclosure, follows a real citation and dismisses the resulting banner.
- Buffered-update checks insert three distinct rows and observe the notification from the production list buffer. The harness does not manufacture its own announcement.
- Reader scans cover top, middle and bottom positions. Both fixture images must decode. Heading roles/text are checked; numeric ranks are checked only when exported. Missing rank metadata is explicitly reported as unverified.
- The child host closes its database and removes fixture state before exiting. The inspector kills only a still-running child on failure and removes fixture state as a fallback.

## Commands and evidence

```sh
./script/test_voiceover_live_qa.sh --self-test
./script/test_voiceover_live_qa.sh --smoke
./script/test_voiceover_live_qa.sh --live
./script/test_voiceover_live_qa.sh --manual
```

Output goes to the printed temporary directory or `NEWS_VOICEOVER_OUTPUT`. `--manual` deliberately remains open until the fixture window closes; the Fixtures menu switches feed/source/overview and queues new stories. Automated modes have deadlines.

Validation on macOS 27.0.1, Xcode 27 / Swift 6.4, Apple silicon:

- Swift 6 compilation with warnings treated as errors.
- Protocol self-check: partial reads, multiple responses, EOF, deadline, cancellation, wrong acknowledgement and offline image creation.
- Smoke: feed, source reader and event overview rendered; two fixture images decoded.
- Manual fixture lifecycle: an external AX close-button press cleaned up and exited successfully. This checks closing the window, not spoken VoiceOver navigation.
- Live AX: **37 checks passed, 0 failed; 10 numeric heading ranks unverified**. The host cleaned up and exited within the five-second exit deadline.
- Full `./test.sh`: passed.
- Isolated `./build.sh`: passed; ad-hoc arm64 bundle verification completed. No installation or production app launch.

## Remaining acceptance

On this desktop, the reader exposes `AXHeading` nodes without numeric rank metadata. The harness reports these ranks as **unverified**, even when heading role/text checks pass. Do not infer H1/H2/H3 rotor behavior from absent metadata.

AX tree enumeration is not VoiceOver cursor order. Observing `announcementRequested` is not proof of spoken output. Run `--manual` with VoiceOver enabled and record cursor navigation, headings/actions rotor, pronunciation/pacing, actual read/save and citation interactions, and the spoken buffered-update announcement before closing #155. This automated audit leaves that issue open.
