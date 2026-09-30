# Production readiness audit — 28 September 2026

Base: fetched `origin/main`, `939180c`. Clean main required no replayed commits. This pass covers reader interaction and layout, navigation, ingestion, enrichment, persistence, import/export, networking and update paths. It is a source review plus the deterministic suite and selected live UI checks, not a release certification or exhaustive security assessment.

## Implemented

| Priority | Finding and consequence | Repair |
| --- | --- | --- |
| P1 | Reader subscribed to `detail*` notifications that no menu command posted. Command-J/K and other menu actions did nothing in detail. | Subscribe to the existing app commands; delete the unused parallel notification names. |
| P1 | Read/save managers observed the injected store but wrote to the global store. Tests and alternate containers could write to real storage. | Retain and use the injected store for writes; isolated in-memory regression. Replace the read-cache test's shared manager. |
| P1 | Save/remove persisted a toggle rather than the requested state. Repeated removal could save a story again. | Explicit idempotent SQLite/store saved-state writes; repeated-removal regression. |
| P2 | AppContainer and NewsApp each created a FeedManager, installing duplicate background schedules. | Reuse the container's manager in the app scene. |
| P2 | Keyboard-open captured Unread/auto-hide context after marking the selected story read, removing it from its own navigation context. | Mouse and keyboard use one open function which captures context first. |
| P2 | Generative analysis started whenever a reader opened, despite the summary being collapsed. Unstructured tasks complicated dismissal cancellation. | SwiftUI-owned tasks; analysis only when summary is expanded; navigation/dismissal cancels work. Preserve database model/version metadata. |
| P2 | A global scroll-wheel monitor could dismiss the reader when gestures happened elsewhere in the app. Arrow shortcuts also competed with normal scrolling. | Remove global gesture interception and unmodified arrow navigation. Keep toolbar, menu and J/K navigation; ignore command/control/option chords in local handlers. |
| P2 | JSON plain-text summaries were HTML-stripped, deleting comparisons and decoding literal entities. | Preserve summary text; retain HTML cleanup for legacy description. Regression failed before the fix and passes after. |
| P2 | Searching in the sidebar while reading left results hidden behind the detail screen. | Return to results when search changes. |
| UI | Duplicate toolbar, hard-coded offsets, oversized edge-to-edge image and scattered actions. | Native window toolbar with navigation, mode, save/share and reading options; headline-first bounded reading column, inline uncropped image, existing typography themes. |

## Screenshot-driven reader repairs

- Preserve publisher headings, paragraphs, quotes, numbered/bulleted lists and code as typed reader blocks. The renderer uses a bounded reading column and semantic heading accessibility; it does not invent article sections.
- Exclude comment, newsletter, related-link, topic and promotional containers before candidate scoring. BBC `data-block` furniture is covered alongside generic publisher attributes; inline citations and legitimate commentary remain eligible.
- Normalize entity tags, collapse unambiguous surname aliases, reject oversized labels and wrap tags instead of horizontal clipping. Unsupported raw categories are hidden. Native entity detection can still produce imperfect names; this is not semantic entity resolution.
- Replace the heavy summary glass card with a quiet surface; retain native Reader/Web controls with explicit labels. Hide the layout picker's visual label while preserving its accessibility name, fixing the vertically broken “Article layout” text.
- SQLite schema 4 stores optional versioned reader documents and complete feed associations alongside plain text. Migration preserves read/saved state; feed teasers cannot overwrite structured extracted bodies. Legacy articles re-extract on opening, with cached fallback on failure. Analysis version 2 invalidates older cached analysis on demand.

## Follow-up repairs — 29 September 2026

- **Native chrome:** standard unified window toolbar replaces the hidden titlebar and AppKit overrides. Soft native scroll-edge effects explicitly enabled. Search reuses native Liquid Glass with reduced-transparency fallback. Reader/Web are native toolbar toggles with labelled accessibility states; selected mode uses the system accent.
- **Cache safety:** cache operations use rollback on failure and preserve article headers, read history and saved bodies. Settings show errors rather than unconditional success. Bulk mark-read checks SQLite preparation/step results. Read/save failures surface an alert and reconcile optimistic state.
- **State consistency:** queued read/save intents retain click order while pending writes cannot be overwritten by intermediate snapshots. Saved-only analysis updates are propagated. Reader resolves the current store snapshot before its original seed.
- **Search/history:** both query persisted SQLite data with cancellable tasks and a Load More control. Search covers the archive and supports the existing source/category/read/saved operators. FTS prefix syntax corrected; ordering is stable across expanded result limits. The shared search parser lives with the article model.
- **OPML:** malformed XML produces no partial imports. Import/export dialogs expose file errors; malformed imports produce an app alert without changing subscriptions.
- **Feed ingestion:** each result retains its originating feed URL; refresh ignores results from removed subscriptions and checks cancellation before ingestion. Background enqueue tasks are retained and superseded tasks cancelled.
- **Isolation:** injected stores do not read or mark real legacy migration state unless given an explicit migration coordinator. Container tests inject stores/settings/managers and disable background schedules; the cache test no longer clears the shared network cache.
- **Updates:** every new check clears previous release availability and URLs. HTTP 404 reports no published release, not “up to date.” Release links reject credentials and non-HTTPS ports.
- **Web navigation:** document navigation reuses ingestion scheme/port/HTTP-preference/DNS checks on the network actor rather than blocking the UI actor; Explicit HTTP opt-in is preserved. Document delegates do not provide redirect/subresource transport enforcement.

## Current scope and remaining limitations

- Development builds target Apple silicon only and use ad-hoc signing for verification. Developer ID signing, notarization and Intel execution are outside the current scope.
- Protected Web previews deliberately disable scripts and block IP-only, single-label, localhost and mDNS resources. Interactive publisher pages remain available through the external browser control. This is destination protection, not a third-party tracking blocker.
- Extraction remains heuristic across publishers; markup changes may require new fixtures. Full VoiceOver, accessibility-settings and minimum-window QA remain part of later polish.

## Completion pass — 30 September 2026

- Archive lists use persisted queries in **every** section, with shared category keywords and keyset cursors (publication timestamp/id or FTS rank/id). Loading additional pages no longer rereads displayed prefixes. Stable tied-date/rank regressions cover archives exceeding 500 stories. Failed list queries offer Retry rather than presenting a false empty archive.
- Schema 3 adds a many-to-many article/feed table and backfills existing provenance; feed-scoped mark-read uses this table without multiplying article rows. Shared-story regression verifies both originating feeds.
- Schema 4 repairs older enrichment tables missing analysis columns. Live launch uncovered this historical upgrade gap; a real-shape schema-1 regression now removes those columns and verifies migration preserves body/read/saved state and restores current queries.
- Feed managers retain the actual refresh task, cancel it on subscription changes and shutdown, and stop timers/scheduling. Cancellation checks inside database ingestion roll back transactions. Deterministic delayed-delivery tests cover removed subscriptions, shutdown and cancelled writes. Enrichment uses the manager's injected store/queue; container and views use the same read/save managers.
- Reader document version 2 invalidates previously cached furniture. BBC `uploaderEmbed` contact blocks are excluded structurally; the ordinary Newsbeat promotion requires its exact two media links, preserving editorial references to the programme.
- Full deterministic suite passes. Optional live checks pass for the two BBC regressions plus Guardian, Ars and NASA. Before the scope correction, `./build.sh` and `./build_release.sh` passed. That earlier verification bundle contained arm64 and x86_64 slices, preserves macOS 15.0 deployment, Hardened Runtime and the original sandbox entitlements, and passes strict signature verification. Final temporary DMG verification, ZIP extraction/signature verification and checksums pass. Signing is explicitly ad-hoc; no notarization occurred.
- Source publication status is recorded in Git history. Existing repository application and distribution artifacts are preserved.

## Design assessment

The reader now uses the platform toolbar, giving content one uninterrupted surface. Serif headlines, selectable publisher text and system semantic colors remain. Summary work is a deliberate action; unavailable reader content retains its diagnostic and Web fallback. Native controls expose labels through accessibility. Visual checks do not replace a full VoiceOver, contrast, minimum-window-size or accessibility-settings audit.

## Validation and release gates

- Full `./test.sh`: passes, including parser, read-store routing and idempotent saved-state regressions.
- `./build.sh`: arm64 app build succeeds with Swift 6 and macOS 15 deployment target, in a temporary staging directory. Existing repository app and distribution archives are preserved.
- Live staged app: reader opens; native toolbar replaces the duplicate panel; Command-J moves to the next story and resets scrolling. Reading options menu and explicit summary expansion were also exercised. The final staged bundle was launched and its reader verified.
- Screenshot follow-up: full tests and staged app build pass. Live BBC and Ars reader sections were checked; final BBC output excludes its promotional/topic/related blocks. Tags visibly wrap and Reader/Web labels are explicit. Schema-1 migration, structured document persistence, feed refresh preservation and FTS retrieval pass deterministic tests. Existing live read/saved state was checked against a pre-migration SQLite backup.
- Later UI polish still needs VoiceOver, accessibility-settings and minimum-window checks. Intel and notarization are explicitly outside the revised development scope.
- These checks preceded repository publication; no deployment was performed.

## Follow-up evidence

- Deterministic checks cover malformed OPML, cache rollback via an isolated SQLite failure trigger, preserved read history, rapid ordered save/read changes, saved analysis snapshots, archive queries beyond 500 recent stories, FTS prefixes, feed provenance and failed/404 update checks.
- Live macOS 27.0.1 staged app: progressive blur visible across the top toolbar, Liquid Glass search visible, native Reader icon selected in blue. Native controls correctly become subdued when the window is inactive.
- Existing repository app/release artifacts are preserved; verification artifacts remain local.

## Network and fetching repair — 30 September 2026

- **Empty library root cause:** a historical schema-3 enrichment table lacked columns required by current queries; the previously running app lacked the schema-4 repair. A read-only backup of the real database was migrated and queried in isolation, returning its 470 stored stories. The repaired live app now uses schema 4. Failed database setup closes the handle so a subsequent attempt can retry; initialization exposes failures instead of reporting readiness.
- **Connection boundary:** the native loopback SOCKS5 gateway resolves each destination, rejects any private/reserved answer and connects only to a validated numeric IP. No second DNS lookup occurs upstream. Only CONNECT and ports 80/443/8080/8443 are accepted. Listener startup fails closed; concurrency, DNS work, buffers and idle time are bounded. TLS and certificate validation remain with URLSession/WebKit.
- **All production clients:** feeds, extraction, images and update checks use protected URLSession networking. WebKit uses the same non-failover proxy, an isolated data store, disabled scripts and native content rules. Controlled testing first demonstrated WebKit's implicit loopback bypass, then verified the rules prevent it, including a public-resource redirect to loopback. Local/single-label host forms are rejected by shared validation as well.
- **Regression proof:** deterministic tests cover mixed public/private DNS answers, numeric pinning, command/port denial, native URLSession relay, WebKit CSS/images, redirects, decimal/hexadecimal/octal/short/encoded/credential-bearing local URLs and reserved/transition addresses. Optional live checks prove a real DNS alias resolving to loopback is blocked and a stopped proxy cannot fall back to a separately verified reachable public host. Guardian, Ars, NASA and both BBC extraction regressions pass through the protected client.
- **Live app proof:** the final app launched with 200 visible recent stories. Refresh retained cached rows instead of showing a false empty library. The existing archive grew from 498 to 511 articles during verification; read/saved counts stayed 66/3. An already-read Ars article opened in Reader and loaded its actual publisher page in the protected Web preview, with the script restriction visibly labelled.
- **Build correction:** both scripts explicitly compile arm64 and use ad-hoc signing. Absolute Icon Composer input/output paths prevent Apple's asset compiler cache from writing into a previous staging directory and invalidating its sealed assets. Both final bundles retain compiled icon assets and pass strict signature verification.

## Current verification artifacts

- Development app: `/tmp/news-protected-current-nj00xf0f/News.app`; log `/tmp/news-protected-current-build.log`. The exact running executable path was verified.
- Optimized arm64 verification app: `/tmp/news-arm64-verification-66poadrl/News.app`; log `/tmp/news-arm64-verification-build.log`.
- Full deterministic suite: `/tmp/news-protected-final-tests.log`; live network/publisher checks: `/tmp/news-protected-live.log`. Both pass. `git diff --check` passes.
- Both bundles are arm64-only, ad-hoc signed, sandboxed and preserve macOS 15 deployment. No notarization, Intel build, package publication or `/Applications` installation was performed in this scope.
- Existing repository app/release artifacts remain preserved. Only source and documentation are published; temporary verification bundles are not releases.
