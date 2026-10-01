# Changelog

## Unreleased — 1 October 2026

### Fixed

- Retain protected redirect destinations and verified same-origin canonical URLs as document aliases; resolve relative reader images from the final response URL.

- Scope incoming GUIDs to their configured subscription, preserving legacy article IDs while keeping colliding publishers and their read/save/notification state separate.

- Preserve observed article IDs and document URLs through a transactional alias migration; resolve old notifications, read/save actions and enrichment to the existing article, rejecting contradictory signals and retaining URL ambiguity.

### Changed

- Preserve inline publisher figures, captions and alt text in the native reader, with bounded image decoding and graceful unavailable-image states.
- Reuse the existing article for incoming GUID variants of the same document URL while retaining its durable identity, bookmarks and reading history.
- Preserve meaningful URL query parameters instead of stripping every parameter beginning with a tracking-key prefix.

## Unreleased — 30 September 2026

### Fixed

- Reuse fresh publisher image responses through native HTTP caching while preserving protected networking, byte bounds and publisher no-store rules.
- Deliver SOCKS rejection replies reliably: the network gateway half-closes and drains unread request bytes instead of resetting the connection.

- Keep undated stories visible using stable ingestion-time ordering, with matching archive/search cursors and retention.

- Preserve the visible library on database read failures and notify only for committed new article IDs across the full archive.
- Apply valid publisher URL/date corrections without replacing known metadata with missing or malformed values; keep undated stories stable across refreshes.
- Reconcile bookmark removal against saved URL-equivalent IDs and exclude empty links from bookmark equivalence.
- Retain notification navigation until storage is ready and resolve archived stories by stable ID or canonical link, without timing delays.
- Respect RSS GUID permalink fallback, persist folder-only OPML imports, avoid duplicate-feed refresh restarts, and read OPML files off the UI actor with a 5 MB bound.

- Resolve SonarCloud maintainability findings: propagate test errors, preserve JSON keys and stored preferences during naming cleanup, simplify branching and network callbacks, and compile the reader exclusion regex at build time.

- Compile boilerplate-cleaning regexes once and use the semantic control radius for shortcut badges (reviewed proposals #83/#84).
- Extract the arm64 SwiftPM app target with a stable toolchain and retain Swift plus Actions coverage in one advanced configuration.

- Repair historical enrichment schemas that prevented stored articles from loading; failed database initialization can retry.
- Keep cached stories visible during refresh and prevent stale query tasks from changing current loading/error state.
- Preserve publisher structure and remove recognized comments, newsletters, related links and promotional containers from Reader.
- Normalize summary entity tags, remove unambiguous surname duplicates and wrap labels without clipping.
- Query all archive sections and search directly from SQLite with stable keyset pagination.
- Retain multiple feed associations, preserve read/saved state and ordered intents, and roll back failed cache operations.
- Cancel removed-subscription and shutdown refresh work before ingestion; keep enrichment bound to the injected store.
- Report malformed feed, OPML, persistence and update failures accurately.
- Keep classification and analyzer fallback regressions deterministic without invoking the generative model.
- Use absolute Icon Composer paths and verify final signatures to prevent stale asset-cache outputs.

### Security

- Make WebKit navigation decisions explicit, restrict the network test probe to its fixture, require locked dependency resolution in CI and scope security-event write access to CodeQL jobs.

- Add a loopback-only native network gateway that rejects non-public DNS answers and pins connections to validated numeric IPs.
- Route feeds, extraction, images, update checks and protected Web previews through the gateway without direct failover.
- Block local/IP-only Web preview resources, including local redirects and alternate loopback forms. Disable publisher scripts and isolate preview storage; use the external browser for interactive sites.
- Reject scoped, reserved, transition and single-label destinations through the shared network policy.

### Changed

- Add layered glass sheets, a raised newspaper face and folded corner to the editable News app icon, with tuned light and dark appearances.

- Use native window toolbar controls, Liquid Glass search and supported soft scroll edges with accessibility fallbacks.
- Generate on-device summaries only on explicit expansion; lightweight feed ingestion stays deterministic.
- Build and verify Apple-silicon arm64 bundles with ad-hoc signing. CI no longer builds/tests Intel or packages distribution releases; notarization remains outside scope.

### Verification

- Full deterministic suite, controlled socket/WebKit regressions and optional BBC, Guardian, Ars and NASA checks passed locally.
- Both arm64 build scripts passed strict ad-hoc signature verification; live refresh preserved read/saved counts.
- Hosted CI status is tracked by the repository Actions badges; local checks are not a hosted CI result or release certification.
