# October feedback: analysis and issues — 24 October 2026

## Context

After the future development plan (epics #571–#577) was logged, Mars sent 17 feedback items from daily use plus "more clustering, better logic", and answered: no labeling by Mars (Claude labels); Briefing needs sketches to choose from and DESIGN.md may change; one click opens a story. Every item below was traced to code (`path:line`, main checkout `2334b79`) and, for clustering, measured on a read-only copy of the live library (5,998 articles, schema v25). Deliverable: new sub-issues under the existing epics where they fit, two new epics (Q polish, R Briefing), epic M retitled and un-frozen, all on board #2.

## 1. Findings

### Clustering ("more clustering, better logic")

Library copy, last 3 days: 1,541 stories, 689 (45%) in an event; 668 multi-member events; `pair_assessments`: 1,405 match / 470 borderline / 56 related-act. The holdout (49 articles) is saturated at recall 1.0, so it cannot show what Mars sees. The library can:

| Symptom | Example (3-day window) | Mechanism |
|---|---|---|
| One story, several cards | Eagle's Nest fire: {Guardian, BBC, DW "arrest/suspect"} vs {Euronews, Arab News, Al Jazeera "fire engulfs"}; Jordan church attack in 3 events + 1 singleton; France "70,000 police" in 5 events | Act-class veto (`EventConflict.differentAct`, checked last in `pairConflict`) keeps "fire" and "arrest" apart by design (corpus convention: one act = one event); event admission needs every pair anchored and conflict-free; `mergeFragments` (EventClustering.swift:392-447) merges only rule-compatible fragments |
| Identical headlines not merged | CNA "OpenAI says its AI agents disabled their own safety monitors" ×2, borderline score 1.0; 9to5Mac "iOS 27.2" ×3 | No shared *specific anchor*: sentence-initial capitalized words become names only when the lemmatizer has no lemma (`isUntypedInitialName`, EventMatcher.swift:304-310); Title-Case headlines (`inTitle && titleCase`) get no capitalization names at all; NLTagger misses "OpenAI"/"iOS". Without an anchor neither rule match, semantic rescue nor the pair model (`needsPairModel` requires `sharedAnchors ≥ 1`, :631-633) can fire |
| Paraphrases split | Pope Leo's treatment: France 24 and BBC singletons, DW+CBC one event, Al Jazeera another; cosines 0.74–0.87 | Same anchor gap ("Pope" sentence-initial, BBC headline has no name or place); rescue needs `sharedSpecific ≥ 1` |
| Same-source duplicates | 12 same-title same-source pairs in 7 days (CNA, 9to5Mac) | Different GUID/URL → two articles; no title-level alias |
| Sub-stories legitimately apart | Ebola: Kenya deaths, Nigeria case, vaccine trial, Africa CDC meeting | Correct at act level; wanted as one *story* with a timeline |

Conclusion: precision engineering is done; what is missing is (a) a **story** layer above act-level events, (b) anchors for headline-initial, Title-Case, organization and product names, (c) fragment merging that can use the pair model, (d) a holdout drawn from the library. Mars will not label; Claude labels under the recorded protocol (memory: Mars delegates bulk pair review).

**Priority 1 (Mars, 24 Oct): with many subscriptions the same story arrives from many feeds and must show as one card.** M6–M10 run first, before any Q/R work except the three one-line breakage fixes (Q1, Q3, L10), and the story-level target is measured on the library copy, not the old holdout.

### Notifications (Mars, 24 Oct, in Polish)

| Item | Root cause / feasibility | Goes to |
|---|---|---|
| 18 | Banners arrive in pairs, one hides behind the other | Full mode posts up to 3 banners per refresh at once with no `threadIdentifier` (NotificationService.swift:85-117, :158/:179/:212), so macOS stacks them; summary modes still post per story | L2 (extended) |
| 19 | Notify only favourite / most-visited topics and important news; star a feed to get everything from it | Triage is a per-story score (0.15 + sentiment + entities + signal words, threshold 0.45) with no interest input; `briefingInterests` (DatabaseEngine.swift:3070-3085) already measures read/saved categories; no per-feed setting exists | L12 |
| 20 | Notification image full height, fading/blurring toward the edge | macOS has no custom notification layout; the attachment is a thumbnail the system places. Feasible by baking the effect into the PNG the app already renders (NotificationService.swift:203-249): alpha gradient plus `CIMaskedVariableBlur` toward the trailing edge. The system may still crop the thumbnail square. | L13 (+ Q for the look) |

### The 17 items

| # | Item | Root cause (verified) | Goes to |
|---|---|---|---|
| 1 | Overview sources expanded | `@State isSourcesExpanded = true` (EventOverviewReaderView.swift:58-59), not persisted | Q4 |
| 2 | "AI-generated summary", "automated estimate" redundant | Two `IntelligenceLabel`s stacked (ArticleDetailView.swift:401-410 and :1300-1303); sentiment line at :1342-1346 from `NLTagger(.sentimentScore)`; overview "Coverage tone" line :1023-1034 | Q5 |
| 3 | Second glyph before "Assembled" | `IntelligenceLabel("Assembled on this Mac…")` (:541) under a page eyebrow that already carries the sparkle (:342); `IntelligenceLabel` also forces `.headline` font (DesignSystem.swift:465-483) so the caption role at :542 is ignored | Q4 |
| 4 | Event card cannot be expanded (some events) | Grid card header image is `.clipped()` without `contentShape` (ArticleCardView.swift:163-170, lead :293-307): a loaded image overflows its 140 pt frame by 15–65 pt and, being later in the `LazyVGrid`, captures clicks on the footer of the card above. Fails only when the card below has a loaded image | Q1 |
| 5 | "Today" does not leave the reader | Only `onChange(of: selectedTopic)` clears `articlePath` (MainView.swift:93-101); reselecting the same row or ⌘1 is a no-op | Q2 |
| 6 | The Verge story truncated | Feed ships ~680-char teasers ending "… Read the full story at The Verge."; the teaser patterns (ContentExtractionPipeline.swift:1260-1263, :1364-1365, :1447-1448) require the phrase at the very end; 3 paragraphs / 620 chars pass the "complete body" rule, so no page extraction | L10 |
| 7 | "I don't want to hear about AI" | `MuteRules` is one phrase per rule, whole-word; no presets (MuteRules.swift:3-16); SQLite applies the same rule | L11 |
| 8 | Briefing redesign | Briefing is Today's card list with a masthead button (ArticleListView.swift:157-172, :686-691); `FiniteBriefing` gives 10 stories, source counts, categories; `mars/kagi-compact-layout` holds an unmerged dense Headlines layout | R |
| 9 | Cards without images | Fallback uses `visibleMembers` only (EventFeed.swift:130-143); World Tension panel members (The Hindu, Arab News, France 24) are hidden from lists, so a Euronews-led card sees one imageless member; the image finder skips the event because a hidden member *has* an image (DatabaseEngine.swift:3135-3163) | Q3 |
| 10 | Tension sheet layout; history-aware score | Sections stacked at `lg` with no grouping, literal strokes/opacities (TensionIndexView.swift:68-254, :193, :239, :362); the sparkle is `IntelligenceLabel("Assessed on device")` :185. Score: single model judgment per day; previous readings enter only as novelty headlines (WorldTension.swift:394-469); v1 EMA exists unused (TensionMethodology.swift:507-592); history is a 30-day JSON beside the DB | Q7, L9 |
| 11 | Light-mode overview readability | Perspective position text at reader body size in `secondaryText` (~50% black, EventOverviewReaderView.swift:959-961); attribution, dates, "Reported" in `tertiaryText` (~26%) at 10–11 pt (:949-955, :913-915, :766, :689) | Q6 |
| 12 | Three clicks to open | Click 1 may only activate the window (no `acceptsFirstMouse`); event cards open the Overview first (ArticleListView.swift:858-859) and the story needs a second click; the overflow bug (item 4) opens the wrong card | Q1, Q2 |
| 13 | Catalog category control | `Picker(.segmented)` with 9 long labels in a 680–720 pt sheet without width (FeedCatalogView.swift:63-72, :89-99); "Suggested Topics & Gaps" recomputes after subscribing and resizes the sheet | Q8 |
| 14 | Refresh vs "N new stories" | Rule is consistent (ArticleListView.swift:407-464, :532-556): Refresh fetches and applies live; the button applies a queued background snapshot. Only the affordance is unclear | Q9 |
| 15 | Launch animation | No launch transition; `MainView.handleAppear` fires `fetchFeeds()` before the cached snapshot lands; clustering and image lookup start immediately (FeedManager.swift:107-112, :274-287) | Q10 |
| 16 | Images load in view | Prefetch window of 30 uses raw `imageUrl`, not `bestCardImage` (ArticleListView.swift:70-84, :845-848); cancelled prefetch decodes are discarded (ArticleRemoteImage.swift:51-82); 1600 px decodes (~6 MB each) in a 192 MB cache hold ~30 images; no fade | K5 |
| 17 | Dock badge 3,454 | Badge = `ArticleStore.unreadCount` (MainView.swift:45-63) | L8 |

## 2. Issues to log

Conventions as before (one PR each, tests with the slice, CHANGELOG, board move, DESIGN checklist for UI, no AI attribution lines). Priority P0 = visible breakage or Mars's explicit asks.

### Epic M (#574, retitled "M · Matching: story-level grouping and measured matcher iteration", un-frozen)

| # | Issue | Scope | Acceptance | Effort | Pri |
|---|---|---|---|---|---|
| M6 (#579) | Library clustering diagnosis and a Claude-labelled holdout | Write `docs/audits/2026-10-24-library-clustering-diagnosis.md` with the table above and the counts; `--review-pairs` (M1) exports 200 borderline/singleton candidate pairs from the library copy; Claude labels them under a recorded protocol (same event / related act / different), Mars spot-checks 20; the file becomes the private "library holdout" for M7–M9 gates. | Audit in repo; holdout file outside the repo with SHA-256 recorded; protocol in CONTRIBUTING. | M | P0 |
| M7 (#580) | Headline names as anchors: sentence-initial, Title-Case, organizations, products (matcher v12) | Sentence-initial capitalized words count as names when NLTagger types them as noun/proper or when they are not dictionary words (drop the lemma-only test at EventMatcher.swift:305); Title-Case headlines keep NER names and multi-word capitalized runs; organization and product tokens with versions ("iOS 27.2", "GPT-5") become anchors; stored signals recompute (`storageVersion` 2). | Authored corpus TP ≥ 22 / FP 0; library holdout precision ≥ 0.97; the OpenAI, iOS 27.2 and Pope examples merge; `testEventMatcherRules` cases. | M | P0 |
| M8 (#581) | Story layer: one card per story | A *story* = connected component of events linked by `related-act` rows or by fragment compatibility within 72 h (schema v26: `story_id` on events, or a `stories` table); cards, Briefing, notifications and "Earlier in This Story" present stories; the overview becomes a story overview with acts as timeline sections; "Not the Same Event" works at story level; ARCHITECTURE and DESIGN updated. | Eagle's Nest, Jordan church, France police examples become one card each on the library copy; share of recent stories in a multi-source card ≥ 60% (from 45%); Claude reviews 100 story groups, ≤ 2 wrong; precision at pair level unchanged. | L | P0 |
| M9 (#582) | Fragment merge and pair-model gates | `mergeFragments` asks the pair model for cross pairs the rules leave borderline; admission tolerates one unanchored pair in events of ≥ 4 when the model confirms it; pair-model cutoff 0.9 → 0.8 (tune identical 44/0); the model may score anchor-less pairs at cosine ≥ 0.85 within 24 h. Each change measured separately. | Tune replay FP 0; library holdout precision ≥ 0.97 per change; authored corpus unchanged; merges counted before/after on the library copy. | M | P1 |
| M10 (#583) | Same-publisher duplicate items alias instead of two stories | Same source, same normalised title, within 24 h → v7-style alias to the existing article (identity resolution order unchanged for others). | 12 duplicate pairs in the 7-day library copy become one story each; existing identity tests pass. | S | P1 |

M1–M5 stay; M4 (model size) and M3 keep their gates. Previous "frozen" wording leaves the epic body.

### Epic L (#573) — new sub-issues

| # | Issue | Scope | Acceptance | Effort | Pri |
|---|---|---|---|---|---|
| L8 (#584) | Dock badge counts what matters | Badge = unread stories of today's Briefing edition + unread stories that passed notification triage (breaking) since the last launch; Settings › Notifications explains it; 0 hides the badge. | Test with a seeded store: 3,454 unread, 10 briefing, 2 breaking → "12". | S | P0 |
| L9 (#585) | History-aware World Tension reading (methodology v3) | Displayed reading = today's accepted assessment blended with the stored history: EWMA over the last 7 accepted days (reuse `TensionMethodology` smoothing, α from the calibration script) plus a momentum term for consecutive rises; the sheet shows "today", "7-day trend" and the band; history stays in the on-device JSON (raise cap to 90 days); methodology v3 doc; estimates never enter the EMA. | Calibration script reproduces documented bands on `historical-sample.json`; unit tests for EMA and momentum; `NativeWorldTensionQA` updated. | M | P1 |
| L10 (#586) | Teaser detection: trailing ellipsis and "Read the full story at …" | A final text block ending in "…"/"..." or a closing "Read the full story at <publisher>" / "Read more on …" line marks the feed body as a teaser; the 3-paragraph/600-char completeness rule does not override it; The Verge fixture; `ReaderDocument.currentVersion` bump so stored Verge documents re-extract. | Verge fixture triggers page extraction; existing teaser tests pass; `--catalog-reader-access` for The Verge shows full text. | S | P0 |
| L2b (#587, extends #545) | Add: post one banner at a time (serial, ≥ 2 s apart) with `threadIdentifier` = story id, `interruptionLevel` by score; summary modes also dedupe per event. | The pairs disappear: two new reports of one event → one banner; three events → three spaced banners. | S | P0 |
| L12 (#588) | Notifications by interest and importance; starred feeds | Triage = breaking signal (existing score ≥ 0.6) OR story in a top-interest category (from `briefingInterests`, top 3) with ≥ 3 publishers; everything else silent. Settings › Subscriptions: a star per feed ("Notify about every story") that bypasses the rule; Settings › Notifications shows the current top interests. | Seeded test: 100 new stories → ≤ 5 banners, all breaking or top-interest or starred; starred feed always notifies. | M | P0 |
| L13 (#589) | Notification image: full-height fade toward the edge | Render the attachment PNG as a tall crop (portrait, 2:3) with an alpha gradient and progressive blur toward the trailing edge (CoreImage `CIMaskedVariableBlur`), bounded size; fallback to the current square when the source is too small. Record how macOS 26/27 actually crops it. | Fixture renders; attachment size ≤ 10 MB; manual banner check recorded with a capture. | S | P1 |
| L11 (#590) | One-click "No AI news" mute preset | Settings › Muting gains "Mute Topic Sets" with one preset "Artificial intelligence" (≈ 25 whole-word phrases: AI, artificial intelligence, LLM, ChatGPT, OpenAI, Anthropic, Claude, Gemini, Copilot, GPT, generative, machine learning, …) stored as one rule group (`MuteRules.groups`, migration of UserDefaults keys); hidden count shown; one toggle removes it. | Toggle on hides AI stories in the library copy (count reported); "Dubai" and "Aid" unaffected; SQLite path and Swift path agree (`testMuteRules`). | S | P0 |

### Epic K (#572) — new sub-issue

| # | Issue | Scope | Acceptance | Effort | Pri |
|---|---|---|---|---|---|
| K5 (#591) | Card images ready before they scroll into view | Prefetch `bestCardImage` for each listed entry (the URL the card will show); keep a completed decode even when the awaiting task was cancelled; decode at card size (≤ 840 px) for cards, full size for the reader; raise the decoded cache to fit the window; fade placeholder → image under `AppMotion.state` (nil under Reduce Motion). | On the seeded library, scrolling 200 cards shows ≤ 5% placeholders at first paint (instrumented count); memory ≤ current. | M | P1 |

### Epic Q (#607) · Interaction and visual polish (milestone Q)

| # | Issue | Scope | Acceptance | Effort | Pri |
|---|---|---|---|---|---|
| Q1 (#593) | Grid card image overflow captures clicks | `.contentShape(Rectangle())` after `.clipped()` (ArticleCardView.swift:170, :307) or `allowsHitTesting(false)` on the overflowing image; same for any clipped figure in cards. | Chevron expands every event card; clicking a card's footer never opens the card below; UI test via `NativeUIQAChecks` click-through. | S | P0 |
| Q2 (#594) | One click opens; "Today" returns to the list | Single click on any card opens it (story or overview) and selects it; the window activates on the same click (`acceptsFirstMouse` on the hosting view); sidebar row click and ⌘1–⌘4 clear `articlePath` even when the section is unchanged (reuse the Esc/B back path, ArticleDetailView.swift:1144-1153); event card opens the overview with the lead story one click away. | Manual check recorded; unit test for the path reset. | S | P0 |
| Q3 (#595) | Event card image from every member | `EventFeedSummary` fallback uses all members (the finder's set), including hidden panel-feed members; the finder also runs when the representative lacks an image. | Milan and Jordan examples show an image on the library copy; `--images-live` coverage ≥ 99% unchanged. | S | P0 |
| Q4 (#596) | Overview: sources collapsed, one intelligence label | `isSourcesExpanded` default false, remembered per session; drop the "Assembled on this Mac…" label (fold the wording into the page eyebrow tooltip); `IntelligenceLabel` takes its font from the caller. | DESIGN §9 wording updated (Q0); appearance captures. | S | P1 |
| Q5 (#597) | Reader summary panel copy | One label "Generated summary" / "Extractive summary" (drop the second sparkle); remove the "language · automated estimate" line and the overview "Coverage tone" line (keep sentiment in data for Briefing interests only); "Key Takeaways" → "Key points". | Copy per DESIGN §17; tests for the label choice. | S | P1 |
| Q6 (#598) | Light-mode overview readability | Perspective position text in `primaryText`; attribution, dates and "Reported" in `secondaryText` at ≥ 12 pt; divider and rail opacities checked against WCAG AA in light mode; tokens only. | Contrast ≥ 4.5:1 for all overview text in light and dark (measured with the appearance matrix captures). | S | P1 |
| Q7 (#599) | World Tension sheet structure | Group sections into titled cards with consistent `md` inner spacing and `lg` between; "What's Driving It" rows aligned (publisher column + headline); "All Panel Headlines" as a table with C/P badge, publisher, headline; remove the sparkle label (plain "Assessed on this Mac" caption); replace literal strokes/opacities with tokens (lint baseline to 0 for the file). | DESIGN checklist; captures light/dark/Increase Contrast; lint baseline reduced. | M | P1 |
| Q8 (#600) | Feed catalog categories | Replace the segmented control with a horizontally scrolling `TagView` row (trackpad scroll, selection trait) or a menu `Picker`; fixed sheet width (`AppLayout.sheetWidth`); the gaps section no longer resizes the sheet. | Captures at 900 pt; all 9 categories reachable by trackpad and keyboard. | S | P1 |
| Q9 (#601) | Refresh and queued updates affordance | Refresh tooltip "Check feeds for new stories"; queued button "Show N New Stories" with tooltip "Stories that arrived in the background"; Help › Keyboard Shortcuts lists both; no behaviour change. | Copy per DESIGN §17. | XS | P2 |
| Q10 (#602) | Launch: one settle animation, heavy work after first frame | Show the cached snapshot in one spring transition (`AppMotion.navigation`, nil under Reduce Motion) once the first page and its card images are ready; `fetchFeeds` waits for the cached snapshot; clustering and image lookup start after the first frame; no per-card pop-in during launch. | Launch baseline first-card time not worse; captures show one transition; Reduce Motion path verified. | M | P1 |
| Q0 (#592) | DESIGN.md review and revision | Review the document against the current app and this feedback: one sparkle per page rule, generated-content copy ("Generated summary"), overview defaults (sources collapsed), click semantics (single click opens), launch motion, Briefing section placeholder for R, grouped-card guidance for the tension sheet; remove rules that no longer hold; Mars approves. | PR with the diff and a changelog of rule changes. | S | P0 |

### Epic R (#608) · Briefing redesign (milestone R)

| # | Issue | Scope | Acceptance | Effort | Pri |
|---|---|---|---|---|---|
Decision (Mars, 24 Oct, after three sketches shown in chat): **Situation board (A) with a hero carousel on top**: the most important events rotate with their pictures every 30–60 s; below, the tension strip with drivers, then dense story tiles with one cited key fact and publisher count, grouped by region/topic.

| # | Issue | Scope | Acceptance | Effort | Pri |
|---|---|---|---|---|---|
| R1 (#603) | Briefing spec and high-fidelity mock | Spec the chosen layout: hero carousel (top 3–5 stories by publisher count, image from any member, 45 s rotation, pause on hover/focus, manual arrows and dots, stops under Reduce Motion and shows the first only), tension strip (reading, 7-day trend from L9, three drivers), tile grid (region/topic groups, key fact from overview highlights, publisher count, time, read state), keyboard model, empty/complete states; one mock per appearance at 900 pt and wide. | Mars approves the mock. | S | P0 |
| R2 (#604) | DESIGN.md Briefing section and motion rule | New §8.4 Briefing: tokens, carousel rules (the only auto-advancing motion in the app, slow cross-fade, never under Reduce Motion, never while a story is open), tile anatomy, copy; amend §13 to allow it explicitly. | Mars approves. | S | P0 |
| R3 (#605) | Briefing shell and data | New `BriefingView` behind the sidebar item; data: 10 stories → story groups (M8 when landed, events until then), key fact per story from its overview highlights (deterministic, cited), tension reading and drivers, images via `bestCardImage` over all members (Q3), read state. | Renders on the library copy; j/k and arrows; VoiceOver labels; carousel timer verified. | L | P1 |
| R4 (#606) | Briefing polish and acceptance | Appearance matrix (light, dark, Increase Contrast, Reduce Motion, 900/1600 pt), Mars runs harnesses; "New Briefing"; empty and complete states. | Dated audit; checklist ticked. | M | P1 |

Order: (1) Q1, Q3, L10 one-line breakage fixes; (2) clustering, priority 1: M6 → M7 → M10 → M9 → M8; (3) L2, L12, L8, L11 (notifications, badge, mute preset); (4) Q0 and R1/R2 (design decisions, Mars approves) then R3–R4; (5) Q2, Q4–Q10, K5, L9, L13.

## 3. Logged on GitHub and the board (24 October 2026)

Issues #579–#608 created the same day: epics #607 (Q) and #608 (R), milestones Q and R, sub-issues linked to #572/#573/#574/#607/#608, board #2 Status and Priority set.

- Retitle #574 and rewrite its body (un-frozen; new sub-issue list). Create M6–M10, L8–L11, K5 as sub-issues of #574/#573/#572 (GraphQL `addSubIssue`), milestones M/L/K.
- Create milestones Q and R, epics Q and R with their tables, sub-issues Q0–Q10 and R1–R4.
- Board #2: all new items Backlog with Priority; Ready for Q1, Q3, L10, M6, M7, L2, L12, L8, L11, Q0, R1 (`gh project item-add` / `item-edit`, field IDs as in the first plan).
- Append the epic bodies of #572/#573/#574 with the new rows (`gh issue edit`).
- Record the library diagnosis as `docs/audits/2026-10-24-library-clustering-diagnosis.md` and this plan as `docs/plans/2026-10-24-october-feedback.md` on branch `mars/october-feedback-plan`, PR against `main` (the first plan's PR #578 is still open; this one is independent).
- Update memory: matcher un-frozen with Claude-labelled library holdout; Briefing redesign pending Mars's sketch choice; single-click opens.
- The three sketches were shown in chat and Mars chose A + hero carousel; R1 now produces the high-fidelity mock of that choice.

## 4. Verification

- `gh issue list` shows the new sub-issues under their epics (sub-issue progress bars); `gh project item-list 2` shows Status and Priority.
- Audit and plan docs render; PR opened; `./test.sh` via pre-commit on the docs commit.
- R1 artifact link delivered.

## 5. Epic ownership (24 October, after the first logging pass)

Different agents work different epics in parallel, so each file family has exactly one owning epic; an epic edits only the files it owns and asks on the other epic's issue for anything else. The "Owns" section of every epic lists the files. Moves made to get there: #534, #540, #541, #542 → M (matching and embedding code); #584 → Q (`MainView`); #548 → R (`FiniteBriefing`, Reading tab). #549 hands the `EventJudge` remnants to #580.

| Epic | Owns | Hands off |
|---|---|---|
| J #571 | `DatabaseEngine.swift` core, migrations, prune, `EnrichmentQueue`, migration fixtures | `DatabaseEngine+Events` and `Event*` (M); views (Q, R); CI (P) |
| K #572 | `ArticleRemoteImage`, `CacheManager`, the prefetch block of `ArticleListView`, benchmarks | clustering performance (M); click handling and launch transition (Q) |
| L #573 | `Overview*`, `WorldTension`, `TensionMethodology`, `ArticleIntelligence`, teaser rules in `ContentExtractionPipeline`, `NotificationService` and the notification branch of `FeedManager`, `MuteRules`, Muting and Notifications tabs | `Event*` (M); `TensionIndexView` layout (Q); Briefing rank (R); Dock badge (Q) |
| M #574 | `EventMatcher`, `EventClustering`, `EventCandidates`, `ActClass`, `EventJudge` removal, `SentenceEmbedder`, `PairScorer`, `DatabaseEngine+Events`, clustering launch in `FeedManager`, `StoryCorpus`, training and evaluation scripts, shipped models | cards and overview views (Q); Briefing (R); storage core (J); notifications (L) |
| N #575 | `NewsApp.swift` URL handling, intents, menu bar extra; `UpdateChecker`; Spotlight; `CFBundleURLTypes` after #566 | version stamping (P); permission timing (O); menus tables (Q) |
| O #576 | onboarding view, permission timing in `NewsApp.swift`, Storage tab backup/restore, diagnostics export, exporters | `FeedCatalogView` (Q #600 first); URL scheme and intents (N) |
| P #577 | build scripts (versions), CI configs, `format.sh`, runner scripts, `NewsTests.swift` harness and split, README/ARCHITECTURE/CONTRIBUTING, CHANGELOG cut | feature code; #570 after #549; #557 after #566 |
| Q #607 | `ArticleCardView`, `EventCardView`, `ArticleListView` (clicks, toolbar copy, launch transition), `MainView`, `SidebarView`, summary panel of `ArticleDetailView`, `EventOverviewReaderView`, `TensionIndexView`, `FeedCatalogView`, `DesignSystem`, design lint, `DESIGN.md` general (before #604) | matching data (M); Briefing views (R); notification and tension logic (L) |
| R #608 | `BriefingView` (new), Briefing branch of `ArticleListView`, `FiniteBriefing`, Reading tab, `DESIGN.md` §8.4 | story grouping (M #581); card components (Q); tension logic (L #585) |

Schema versions are reserved in order of landing: #581 took v26 (M, story layer, landed first); #536 takes v27 (J), #545 v28 (L).
