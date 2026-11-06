# ``News``

A native, local-first macOS reader for RSS, Atom and JSON feeds.

## Overview

News fetches the feeds a reader subscribes to, stores stories and reading state in one SQLite library on the Mac, groups reports of the same event, and analyses stories on device. World Tension history is a separate file beside the library, and mute rules are in the app's preferences. There is no account, no cloud backend and no remote AI, and a release build has no telemetry.

These pages explain how the parts fit together and link to the types that own each job. The contract for implementation invariants stays in `docs/ARCHITECTURE.md`; security and privacy commitments stay in `SECURITY.md` and `PRIVACY.md`.

## Topics

### Essentials

- <doc:Architecture>
- <doc:PrivacyAndSecurity>
- <doc:OnDeviceIntelligence>
- <doc:SituationBoardAndBriefing>
