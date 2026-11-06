# ``News``

A native, local-first macOS reader for RSS, Atom and JSON feeds.

## Overview

News fetches the feeds a reader subscribes to, stores everything in one SQLite library on the Mac, groups reports of the same event, and analyses stories on device. It has no account, no cloud backend, no remote AI and no telemetry.

These pages explain how the parts fit together and link to the types that own each job. The contract for implementation invariants stays in `docs/ARCHITECTURE.md`; security and privacy commitments stay in `SECURITY.md` and `PRIVACY.md`.

## Topics

### Essentials

- <doc:Architecture>
- <doc:PrivacyAndSecurity>
- <doc:OnDeviceIntelligence>
- <doc:SituationBoardAndBriefing>
