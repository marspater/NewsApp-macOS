# Changelog

## Unreleased — 1 October 2026

### Fixed

- A new event-matcher version no longer detaches unchanged event members, usually the earliest report of a large event, by checking them against members that joined later; only members whose title or description changed are checked against their event again (#262).
- Preserve article sections around inline related widgets and exclude teaser cards whose text is split across several links (#246).

- The reader no longer rejects articles because of repeated page furniture, and stops at the article body instead of including related links and trending lists; on a live sample, page-extraction failures fell from 14 to 4 of 96 stories (#242).
- Feeds that put plain text with blank-line paragraphs in `content:encoded` (for example Економічна правда) no longer show the article as one paragraph; the reader now opens the publisher page with its structure (#115).
- Cancelling a refresh now stops feed parsing at the next element or item instead of extracting the rest of the feed, and an aborted parse is no longer reported as a malformed feed (#153).

- Avoid full-text content scans when joining search/event candidates or updating/deleting indexed articles. Schema v15 rebuilds the derived index with durable integer keys while preserving article IDs, saved/read history and event membership.

- Opening an article that belongs to an event no longer switches the reader to the event overview when it finishes generating, including out of the web view; the overview is offered in the toolbar. Closing a reader and quickly opening another article of the same event no longer cancels that article's overview.
- An event overview that cites the same passage as another event's stored overview, for example after "Not the Same Event" moves an article, is now stored instead of silently failing and being regenerated on every open.

- An event overview requested after a member article was edited no longer receives, or stores, the overview still being generated from the earlier text; the running generation is cancelled and replaced (#154).

- Skip FTS deletion/reindexing for unchanged searchable article fields during repeated refreshes; migrate existing libraries transactionally.

- Preserve inline publisher formatting and feed HTML structure, retain image credits and candidates, curate responsive media, stabilize image layout and add native reader text sizes (phase C).
- Keep an opened article's extracted headings, lists, quotes and figures when a later refresh of a summary-only feed brings only images; previously the reader then showed the saved text as plain paragraphs and never fetched the page again. Documents already affected are fetched again when opened (#115).
- Reader accessibility: the headline and publisher headings are announced with heading levels, the source line is read as one phrase, the citation highlight's dismiss button is its own labelled control, the headline is selectable, and Increase Contrast restores full-strength text and visible control borders (#123).

- Retain protected redirect destinations and verified same-origin canonical URLs as document aliases; resolve relative reader images from the final response URL.
- Forward TCP EOF through the protected proxy, so cancelling a refresh closes the upstream request while half-closed responses can finish draining.
- Reconcile confident historical same-document copies while preserving original rows, read/save histories and old-ID navigation; keep uncertain matches separate.

- Match substantial exact publisher text across URL/GUID variants while preserving independent reprints and uncertain identities.

- Scope incoming GUIDs to their configured subscription, preserving legacy article IDs while keeping colliding publishers and their read/save/notification state separate.

- Preserve observed article IDs and document URLs through a transactional alias migration; resolve old notifications, read/save actions and enrichment to the existing article, rejecting contradictory signals and retaining URL ambiguity.

### Added

- Add bounded, isolated native accessibility QA with offline reader images, rendered-tree/action checks and a separate manual VoiceOver fixture (#155).

- News Tension window (experiment): a Swift Charts history of the panel's tension index by UTC day, with coverage, the largest event contributions and the methodology. Days without enough coverage are shown as gaps, never zero, and the history starts when panel collection began (#159).
- A one-time `FirstCard` signpost and log line record when the first story card appears, with the time since process start, for launch profiling (#104).

- Add an opt-in isolated native rendered-card benchmark and integrated service budgets; distinguish unchanged refreshes from dense clustering work without modifying the real library.

- Add an optional Briefing: up to ten unread stories from the last 24 hours, mixed across sources and categories, frozen until a new briefing is requested, with reading progress and completion.
- Track locally observed title, feed-summary and extracted-body changes with compact publisher-input revisions. Invalidate generated article analysis and event overviews when input changes, reject stale background results, and show observed publisher updates without claiming verified corrections (#164).

- Show a sourced timeline in event overviews when the selected reports state at least two different explicit calendar dates. Each item reproduces the source sentence with links to every publication that printed it; dates appear exactly as precise as stated (a missing year stays missing), items dated after their article was published are labeled Planned, and relative dates such as "on Monday" are left out.
- Mute publishers and topics (Settings → Muting, or "Mute host" in a story's context menu). Hosts cover their subdomains; topics match whole words in headlines and feed summaries, ignoring case. Today, Unread, sections and search leave muted stories out before paging and say how many they hid, with "Show Muted Stories" and "Unmute All"; Saved Stories and History list everything, and muted stories never notify. Nothing is muted by default.
- Define news tension methodology v1 (docs/methodology/tension-index-v1.md, experiment, not shown): a fixed panel of 12 English catalog feeds from six regions, UTC days with a majority coverage rule where missing or insufficient days are never zero, unique events, and deterministic classification of type, reported scale and escalation from verbatim anchored quotes. No score until calibration.
- Add an opt-in starter catalog of 49 verified feeds in nine sets (world, politics, business, technology, science and health, culture and food, Ukraine, Europe, Asia/Middle East/Africa) with language, region, topic, publisher and availability metadata, reachable from Settings → Subscriptions → Browse Catalog. Nothing is subscribed automatically; custom RSS and removing any source work as before.

### Changed

- Refresh after the Mac wakes: timers stop during sleep, so a feed older than the refresh interval, or a refresh interrupted by sleep, is fetched once about ten seconds after wake. A refresh cut off by sleep is cancelled rather than recorded as feed failures, so healthy feeds are not backed off.
- Group coverage of the same event into one feed card ("5 sources · updated …") with every member publication one click or the E key away, and a toggle (G) back to individual publications. Matching is deterministic and conservative: a shared name or place, shared action terms, closeness in time and no contradicting quarter, year, weekday, headline figure, place or language; a newcomer must fit the whole event. Clustering runs after a refresh has published, off the main actor, only for new or changed articles.
- Keep the feed still while it is being read: new, removed and regrouped stories wait behind an explicit "N new stories" button (U) instead of moving cards under the pointer; queued updates respect Reduce Motion.
- Mark events as updated only for new reporting since the version the reader opened; opening an event marks no article read, and read/saved state stays per article.
- Add "Not the Same Event" to a member's context menu: a local exclusion (schema v14) that later refreshes and re-clustering respect.
- Find event-matching candidates from shared names and title words within a 48-hour window, the same detected language and events still active in the last 72 hours, capped per article. Nothing groups articles yet.
- Store events with stable IDs, article membership and membership versions (schema v13). Merges keep old event IDs working, splits get new ones, and neither changes article IDs or read/save state; no source text is copied into events. Nothing groups articles into events yet.
- Show operational health per subscription (Settings → Subscriptions and the catalog): whether the feed responds, how recent its newest item is and how much text it carries. Health is persisted with ingestion and described as plumbing only, never as a rating of accuracy or trustworthiness.
- Request feeds conditionally: stored ETag and Last-Modified validators let publishers answer 304 Not Modified, which leaves stored articles untouched. Validators are saved atomically with the ingested articles, cleared by cache purges and dropped when a server stops sending them.
- Honor `Retry-After` on 429/503 and back failing feeds off exponentially (10 minutes doubling to 6 hours), persisted per feed. Scheduled and manual refreshes both respect the wait, a host that pushed back is left alone, at most two requests run per host, and an offline device is not mistaken for failing feeds.
- End a refresh when new articles are collected and published: notification triage and background classification no longer hold the spinner or the next Cmd-R. Finished classification is not repeated by every refresh, background classification pauses under Low Power Mode and thermal pressure, and scheduled refreshes defer when the system asks.
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
