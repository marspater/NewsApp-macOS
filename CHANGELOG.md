# Changelog

## Unreleased — 10 October 2026

- The event overview's lead image loads through the protected, loopback-only image gateway like cards and reader figures, instead of a direct `AsyncImage` request that skipped DNS-answer validation and local-address blocking. It shares their decoded-image cache.
- UI and UX consistency fixes: search archive menu state is reset on launch; reader toolbar AI loading bubble alignment and animation stutter are resolved; publisher updates section is collapsed by default; France 24 bottom promotional boilerplate is stripped during content extraction; event card context menus follow the design language order with added source muting and native sharing; suggested sidebar rows are native selectable items with trailing add accessories; card descriptions retain full contrast in Increase Contrast mode; user-facing copy and browser iconography are standardized to "story", "News", and `safari`.
- UI polish: pressing Refresh shows the new stories instead of a "N new stories" button; results that arrive during a refresh you started replace the list, and an open story still keeps it still. List controls and search sit at the trailing edge of the toolbar on macOS 26 and 27. Search operator suggestions line up in two columns. Reading options use one label column (Text Size, Reading Style). Settings panes are 720 pt wide so all nine tabs fit without the overflow menu. Empty lists (no saved stories, no results, loading and failures) center their message in the visible list area under the title. Cards show short dates ("2 hr. ago" within a day, then "Oct 9", with the year only for earlier years) instead of the region's abbreviated format such as "2026 Oct 10"; the reader shows the full date. UI fixes from a code review: W steps through the reader's modes (Overview, Story, Web) so it matches the "(W)" hints, ⇧⌘R still switches Story and Web, and ← goes back to the list as the shortcuts window says; grid cards share one header height and align to the top of their row; the lead story's border and loading placeholder follow the image's rounded corners; Return adds a feed in the sidebar popover and in Settings, and Add is disabled while the field is empty; the Feed Catalog sheet closes with Esc; failed cache cleanups show a warning symbol instead of success green; Settings uses the reader's style names (Casper, Edition, Alto); empty Saved Stories and History no longer show a refresh spinner; Web view's Reload retries a page whose first load failed; story wording, Title Case and plurals are consistent across menus, buttons and Settings. The list status line moves its actions (waiting, muted, notices) to a second line when the window is narrow. The event overview's lead image is no longer cropped and drops its caption and credit when it fails to load; spinners use native sizes instead of being scaled.
- News Tension moves from its own window into the main window: with panel collection on, the foot of the sidebar shows the reading (for example "44° Warm", with a flame that flickers unless Reduce Motion is on), and clicking it opens a modal sheet with the 7-day reading on a 0–100 gauge, what drove the selected day and the 30-day trend. The bands (Calm, Mild, Warm, Hot, Boiling) are names for index ranges only and do not change scoring. Settings → Intelligence → Show News Tension opens the same sheet. The sheet leads with a short explanation of the reading (its change since the previous day, its 30-day average and the stories driving it). The paragraph is assembled directly from scored facts and attributed panel headlines, preventing unsupported model claims or cached generated prose when AI is off. The sidebar reading is rescored after every refresh and when a new UTC day begins.

- Event creation checks the judge between candidate partners. Settled pair verdicts are reused throughout the pass, so exhausting its budget cannot forget a DIFFERENT veto (#307).

- Source review notices use readable label colors and story terminology; subscription-row advisory actions remain separate controls for keyboard and accessibility navigation.
- Overview perspectives recognize reported speech from a named speaker without a direct quotation, such as "Foreign Secretary Ed Miliband said his country does not accept…" or "…told TF1 television on Thursday night that…". Leading time phrases and descriptive clauses are trimmed from the speaker; pronouns, generic "officials" and cut-off speakers are excluded. Overview analysis version 6 regenerates cached overviews on request (#313).
- Event overviews are written from publisher article text instead of feed summaries. Before generating, the app extracts up to four representative articles that have no text yet: at most two at a time, each cut off after four seconds, never twice for the same page. When the evidence is still too thin for a five-sentence draft, the deterministic overview is kept without asking the model (#308).
- Reader figure captions appear once: publishers that repeat a figcaption per breakpoint (The Guardian) no longer show the caption twice, and an image credit the caption already prints is not repeated beneath it.
- Event matching treats explicit model `DIFFERENT` verdicts and hard factual conflicts as vetoes, including when most members agree. Fragment coverage judgments cannot override them (#307).
- Add the experimental, read-only backend for earlier related-event candidates (#314), with bounded retrieval, direct actor/place/topic evidence, cancellation and stable ordering. Reader exposure remains pending reviewed wrong-link measurements.

- Reader text size persists across stories, with ⌘+/⌘−/⌘0 View commands and a Reading Options popover for text size and Casper, Edition or Alto. Reader and overview share the 720 pt column; citations and extraction fallbacks use shared notices, and original-page actions use standard buttons (#355).

### Changed

- Phase 4 content consistency: reader and event overview use shared typography tokens and scaled editorial styles; publisher eyebrows, AI labels, citation tags and in-content notices share components. Semantic system label/separator colors replace faded text and custom borders, and the design lint requires zero literal fonts, colors and code uppercasing in feature views.
- Phase 3 search now lives at the trailing end of the toolbar. Its existing archive-wide operators (read/unread/saved, source and category) are native search tokens, and source/category suggestions become chips once a value is entered. A newer chip replaces an earlier one for the same filter.
- Feed-add and OPML import confirmations use the scrolling list masthead with accessibility announcements instead of temporary sidebar rows; rejected additions and malformed imports use alerts. Empty, no-results and feed/query-failure states use system `ContentUnavailableView`, with Retry and technical details disclosed on demand.
- Story and event cards use the shared design tokens and components: publisher eyebrows uppercase for display only (VoiceOver reads the name), headlines use the card headline token, and the AI and Updated tags are one tag component with the sparkles symbol instead of a "✦" character; tag fills strengthen with Increase Contrast.
- Sidebar rows are native list rows: the system draws selection and unread/saved count badges, rows follow the System Settings sidebar size, and arrow keys move through them. The refresh indicator on Today uses the mini progress control instead of a scaled one.
- Event overview sections (key facts, sources, timeline, perspectives) follow the window's light or dark appearance. Their fill used to keep the appearance that was active when it was first drawn, so with the in-app Light override on a dark system, or after switching macOS appearance, the sections stayed mid-gray and their citation tags were hard to read. Story and event cards now strengthen their borders and dates with Increase Contrast, as the reader and overview already did.
- Clicking a sidebar row keeps keyboard focus in the sidebar, so the arrow keys move between sections as the phase 3 sidebar intended; before, focus fell back to the story list once the window title and toolbar search updated. Tab still moves between the sidebar, search and stories.
- Complete the native window chrome: Refresh stays visible during toolbar overflow on macOS 26.1+, New Briefing has a separate toolbar group and menu command, and queued updates dim in inactive windows. The reader window title names its publisher. Story sharing, reading mode/options, browser navigation and Add Feed are available from menu commands bound to the active window. ⇧⌘R switches Story/Web even when an overview is open; single-key W keeps its existing overview behavior.

- Menus: View gains as List, as Grid and Group Stories by Event. Actions on a story (read state, save, open in browser, Story or Web) move from Navigate to a new Story menu with the same shortcuts, except Switch Between Story and Web, which moves from ⇧⌘W (Close Window in tabbed apps) to ⇧⌘R. W still switches in the reader.
- Story list chrome: Group by Event, List or Grid, Refresh and New Briefing move into the window toolbar, so on macOS 26 and 27 the list scrolls under the system Liquid Glass toolbar with the automatic scroll edge (the forced soft edge is gone everywhere). The location title (26 pt, Today with its date) and status line scroll with the list; the duplicate in-content sidebar toggle is removed in favour of the system one. Queued updates float over the list as a glass button (bordered on macOS 15). Keyboard Shortcuts moves from a list button to Help → Keyboard Shortcuts. In full screen the reader's toolbar appears on hover.
- Design foundations (no visible change): the imitation frosted surface is removed, custom glass helpers use native Liquid Glass on macOS 26 and later with a regular-material fallback on macOS 15, and the design tokens named in docs/DESIGN.md exist. `./test.sh` first runs `script/design_lint.sh`, which fails when a view adds literal font sizes, colors, corner radii, materials, direct glass or `uppercased()` beyond the recorded baseline.
- Reader: one segmented Overview / Story / Web control in the toolbar replaces the separate overview picker and Reader and Web toggles (Overview appears only for events with an overview). The reader toolbar no longer draws an opaque background or forces a soft scroll edge, so on macOS 26 and 27 it uses the system Liquid Glass and stories scroll beneath it. W still switches modes.

- Settings: panes size to content instead of a fixed 680 × 490 window frame, extra outer padding around grouped forms is dropped, the last-opened pane is remembered across launches, and all literal font sizes are replaced with design typography tokens (lowering the design lint baseline by 24 deviations).
- Secondary windows and sheets: News Tension and the Feed Catalog adopt `navigationTitle` and hide duplicate toolbar titles with `toolbar(removing: .title)`. The Feed Catalog places Done in the standard toolbar confirmation action without custom sheet backgrounds or bottom button bars, and both views adopt design typography, micro-spacing and continuous container radius tokens.

- Upgrading from the pre-SQLite cache imports saved stories and read state again. The import used to stop at a nested-transaction error whenever legacy data existed, and it repeated that failure at every launch. Read entries whose story is no longer cached are skipped.
- Batch read and saved-state updates resolve ID aliases in bounded SQLite queries while preserving input order, ambiguous aliases and transaction rollback.

- Multi-source overviews use on-device plain-text synthesis with citations on introductory sentences and key facts. Unsupported sentences are dropped; weak or refused drafts retain the current excerpt overview. A few covered events warm in the background under the AI and energy settings. Classification and interactive analysis also use plain text to handle sensitive news without guided-output refusals.

- Waiting stories are filtered from notifications after importance rating. A rating computed before a publisher edits a headline is discarded.
- Imageless, unmuted stories look up declared publisher images from a bounded page prefix, including schema.org metadata. Briefing and grouped cards reuse the results; event cards choose the best usable lead across all members. Publishers without a usable image retain the card placeholder. Lookups run after clustering, so slow or unreachable publisher pages never delay notifications.
- When a publisher page declares no usable image, the card lookup takes the first qualifying figure from the article body in the same bounded page prefix. Logos, newsletter banners, tracking pixels, extreme aspect ratios and shared site images are still rejected (#312).
- Shared publisher site images (brand cards) found on story pages are remembered, so no later story keeps one regardless of lookup order. Schema v21 adds this record; existing images and reading state are preserved (#338).

- Stories are rated major, notable or minor on device. Minor stories wait out of Today, Unread, sections and the Briefing until four publishers cover them (the list says how many wait and can show them); unread ones that are still waiting a day later are removed and are not re-added by later refreshes. Without on-device AI nothing is hidden.
- Importance ratings follow three borderline rules (#309): broadcaster or industry business news is minor unless it affects a whole sector or national policy; incidents at military sites count by consequence (trespass arrests minor; damage, sabotage, terrorism charges or a real breach notable); nationwide staple price changes are notable, single-company or regional ones minor.

- The app supports English-language feeds only for now. The catalog no longer offers its Ukrainian, German, French, Italian, Dutch and Polish feeds, and existing subscriptions to those catalog feeds are removed at launch; custom feeds are kept. The entries stay in the code for a later release (#264).

- Only free, open sources: every catalog feed was opened in the app's own reader on 8 October 2026 (`./test.sh --catalog-reader-access`); none is paywalled or blocked. Onet is removed from the catalog, and existing Onet subscriptions end once at launch. Politico, The Hill, Fast Company, Dawn and Ukrainska Pravda are now marked readable; France 24 stays preview-only because most of its feed items are videos.

- The reader drops BBC newsletter promotions: banner images whose alt text describes a newsletter promotion, and signup paragraphs that link to a `/newsletters/` page. Editorial figures, captions and prose that merely mention a newsletter stay (#330).

- Story links that a feed publishes over `http://` (Africanews) are read over https instead of being refused, and embedded-video consent notices (France 24) no longer appear as article text.

- The New York Times home page feed is no longer a default subscription, and the earlier default subscription ends once at launch: nytimes.com answers automated article requests with HTTP 403, so its stories could only be read in Web view. Subscribing to it again by hand is kept.

- Search uses the system sidebar search field (Liquid Glass on macOS 26). Filter operators (`is:unread`, `is:read`, `is:saved`, `source:`, `category:`) are offered as suggestions while typing, and a search without results says so instead of suggesting a feed refresh.

- Refreshing from the toolbar, ⌘R or R shows the new stories when the refresh ends instead of queueing them behind the update button; the refresh icon spins while feeds load. The list header shows how many events are grouped and when feeds last refreshed, and the grouping button is filled while coverage is grouped.

- Reader: a page's own headline is no longer repeated as the first paragraph, the first paragraph after it takes the lead style, and tag strips such as "Topics: …" are dropped, including from stories stored earlier.

### Fixed

- Overview and importance evaluation reports reject reviewer sheets whose claim text, evidence, headline, summary or publisher changed despite retaining the same IDs. Labels remain editable, while stale sheets leave the last aggregate report intact (#308, #309).

- The migration regression clears its temporary preferences domain by its suite name, and the test script removes only that run’s UUID-named plist after the runner exits (#311).

- Event-corpus evaluation uses the production per-pass article and on-device judge budgets instead of unlimited overrides. A new targeted English diagnostic still falls below the clustering precision target; it does not establish release acceptance (#307).

- Attributed overview perspectives recognize paired curly quotation marks and both `said Speaker` and `Speaker said` after a quote. Statements retain their original passage text; vague speakers and syndicated duplicates remain excluded. Older cached overviews regenerate on request (#313).

- While tension collection is on, waiting minor stories from panel feeds are no longer deleted after a day, so past tension days keep the stories they were built from (#310). They stay hidden from the reading views as before.

- An overview made while the on-device model was skipped (AI setting, Low Power Mode, heat) or failed (refused, rate-limited) is kept only provisionally and regenerated on the next request, so a background warmup can no longer pin an event to its excerpt overview. Cancelling the background warmup no longer cancels an overview the reader joined. Overviews made while the model was skipped or failed, and reader summaries made after a failed model request (Apple Intelligence switched off, model still downloading, refusal, rate limit), are redone when next requested; a Mac that cannot run it keeps the excerpt versions. After a macOS update, which can replace the on-device model, stored overviews and summaries regenerate with the new model when next opened.

- Overview sentences preserve literal pipes and accept case/punctuation variants of a complete YES verdict; ambiguous answers still fall back. Earlier overviews regenerate with the corrected parser.

- Cached card images no longer flash the previous story when a view changes URLs. Fragment merges reuse exclusion reads and refresh their discovery terms. Duplicate publisher-image checks use an indexed lookup, including libraries already on schema v18.

- Event grouping recognises far more coverage of one story. Places are compared as countries ("American", "U.S." and "United States" agree; Madrid and Spain do not contradict), rising casualty tolls no longer split one attack, one dissenting member no longer keeps a matching report out of a larger event, and events of one story that formed separately are merged. Where the rules leave a pair open, the on-device model decides (when on-device AI is enabled), including paraphrased headlines found with on-device sentence embeddings. On the labelled tune split, English recall rose from 0.27 to 0.71 at precision 0.96; replaying the last 72 hours of a real library put 9 of 9 Nobel-prize reports, and every report of the Kramatorsk bus strike, into one event each.

- List cards keep their image inside its column; a wide image no longer runs under the headline, and headlines get their second line before the summary does.

- Stories from catalog publishers show the publisher's name ("The Guardian", "Al Jazeera") instead of a feed title such as "World news" or a slogan; stored source names are unchanged.

- Feed summaries decode every HTML entity, including zero-padded ones such as `&#039;`.

- Section banners (image paths naming a banner) are no longer used as story images or reader figures.

- Card images: images already shown appear at once when scrolled back into view instead of loading again, decoding no longer queues behind feed requests, The Guardian's feed images are recognised (the widest rendition is used), BBC images use a sharper rendition, and an event card without its own image shows one from other listed coverage.

- Search matches every typed word anywhere in a story, as it already did when a `source:`, `category:` or `is:` filter was present; previously a plain multi-word search only found the words adjacent and in order.

- Development builds report version 2.0.0, so Check for Updates can compare them with a published release.

- Stories linked to a publisher homepage keep independent bookmarks; removing one no longer unsaves other stories with the same generic link (#281).

- Cancelled reader tasks no longer replace the active reader’s event overview or apply lookup results after navigating to another article (#279).

- Update checks send GitHub API headers through the protected HTTP client and preserve HTTP failure status messages (#274).

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

- The opt-in `--curation-live` audit also lists every minor-rated story of the 72-hour window, records whether each one waits, and re-rates it once with a sampled, uncached model call (production rates greedily, so an identical call would always agree). `script/evaluation/importance_review.py` turns that into a blind private sheet (no waiting flag or re-rate shown) and an aggregate-only report: important stories the app would hide, with Wilson 95% bounds, and re-rate stability (#309). App behaviour is unchanged.

- The opt-in `--overviews-live` audit now generates until 30 drafts are accepted (`NEWS_OVERVIEWS_TARGET`), can skip an earlier run's events (`NEWS_OVERVIEWS_EXCLUDE`), records latency and why each draft fell back (refusal, format, weak draft), and measures how many covered events show two or more attributed perspectives and which extraction step stopped the rest. `script/evaluation/overview_review.py` prepares a private claim sheet for an independent reviewer and reports aggregate-only rates with Wilson bounds (#308, #313). App behaviour is unchanged.

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
