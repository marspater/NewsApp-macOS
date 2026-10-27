# Architecture

Native macOS, local-first RSS reader. This page is the contract for technology and implementation invariants. Workflow lives in [CONTRIBUTING.md](../CONTRIBUTING.md), design in [DESIGN.md](DESIGN.md), security in [SECURITY.md](../SECURITY.md), privacy in [PRIVACY.md](../PRIVACY.md), and App Store preparation in [XCODE_AND_APP_REVIEW.md](XCODE_AND_APP_REVIEW.md).

> [!IMPORTANT]
> Nothing leaves the Mac except feed, article and image requests through the protected gateway. No cloud backend, remote AI, telemetry or analytics SDKs, and no custom AI models except CoreML models this project builds, measures and ships itself (#520).

## Stack

| | |
|---|---|
| Language / UI | Swift 6, SwiftUI, narrow AppKit/WebKit. Minimum macOS 15; gate newer APIs, never raise the minimum casually. |
| Apple frameworks | Foundation, Network, SQLite3 (WAL + FTS5), NaturalLanguage, CoreML, conditional FoundationModels, OSLog/signposts, Swift Concurrency. |
| Packages (SwiftPM, static archive) | **SwiftSoup**: CSS metadata selection and bounded HTML5 repair. **FeedKit**: typed RSS/Atom/JSON models behind the app's own XML safety boundary. New dependencies need a requirement with no reasonable native answer. |
| Builds | arm64, ad-hoc signed, App Sandbox + Hardened Runtime. Intel/universal and notarization are out of current scope. |
| UI rules | Native keyboard/trackpad, accessibility, semantic tokens, restrained Liquid Glass ([DESIGN.md](DESIGN.md)). |

## System map

Five layers, colour-coded. Arrows are calls; the thick arrow to publishers is the only way out of the Mac, through the protected gateway.

```mermaid
%%{init: {"flowchart": {"curve": "basis", "nodeSpacing": 22, "rankSpacing": 44, "padding": 10}}}%%
flowchart LR
    subgraph Coord["Coordinators"]
        FM["<b>FeedManager</b><br/>orchestration<br/>lifecycle, sleep, wake"]
        NS["<b>NotificationService</b><br/>triage"]
    end

    subgraph UI["Views"]
        Main["<b>MainView</b>"]
        List["<b>Story list</b><br/>ArticleListView<br/>EventCardView"]
        Reader["<b>Reader</b><br/>ArticleDetailView"]
        Overview["<b>Event overview</b><br/>EventOverviewReaderView"]
        Tension["<b>World Tension</b><br/>TensionIndexView"]
    end

    subgraph Intel["Intelligence · on device"]
        EQ["<b>EnrichmentQueue</b><br/>bounded classification"]
        EC["<b>EventClusterer</b>"]
        EM["<b>EventMatcher v12</b><br/>MiniLM embeddings · pair model"]
        CEP["<b>ContentExtraction<br/>Pipeline</b><br/>reader v11 · SwiftSoup"]
        OV["<b>Overview builders</b><br/>cited sentences"]
        WT["<b>WorldTension</b>"]
    end

    subgraph Svc["Services · network"]
        FF["<b>FeedFetcher</b><br/>≤6 requests<br/>≤2 per host"]
        Parse["<b>FeedXMLParser</b><br/>FeedKit · JSONFeedParser"]
        HTTP["<b>SecureHTTPClient</b>"]
        GW["<b>NetworkBoundaryProxy</b><br/>IPAddressValidator"]
    end

    subgraph Store["Storage · SQLite v25"]
        AS["<b>ArticleStore</b>"]
        DB[("<b>DatabaseEngine</b><br/>+Events<br/>WAL · FTS5")]
    end

    Net(("<b>Publishers</b>"))

    FM -->|due feeds| FF
    FM -->|after publication| EC
    FM --> EQ & NS
    EC --> EM
    FF -->|conditional GET| HTTP
    FF -->|bodies| Parse
    Parse -->|one transaction<br/>per feed| DB
    Main --> List & Reader & Overview & Tension
    Reader -->|open story| CEP
    CEP -->|fetch page| HTTP
    HTTP --> GW
    GW ==>|public DNS<br/>pinned IP| Net
    Overview --> OV
    OV --> AS
    List & Reader --> AS
    AS --> DB
    Tension --> WT

    classDef ui fill:#E8F0FE,stroke:#3B6FD8,stroke-width:1.5px,color:#14264A
    classDef coord fill:#FFF3E0,stroke:#D9861C,stroke-width:1.5px,color:#4A2C05
    classDef intel fill:#F1E9FE,stroke:#7C4DDB,stroke-width:1.5px,color:#2B1755
    classDef svc fill:#E3F5EC,stroke:#23935F,stroke-width:1.5px,color:#0D3825
    classDef store fill:#FDEBEC,stroke:#CF4A4A,stroke-width:1.5px,color:#4A1212
    classDef ext fill:#ECEFF3,stroke:#5F6B7A,stroke-width:2px,color:#1E2630
    class Main,List,Reader,Overview,Tension ui
    class FM,NS coord
    class CEP,EQ,EC,EM,OV,WT intel
    class FF,Parse,HTTP,GW svc
    class AS,DB store
    class Net ext
    style UI fill:none,stroke:#3B6FD8,stroke-dasharray:4 3
    style Coord fill:none,stroke:#D9861C,stroke-dasharray:4 3
    style Intel fill:none,stroke:#7C4DDB,stroke-dasharray:4 3
    style Svc fill:none,stroke:#23935F,stroke-dasharray:4 3
    style Store fill:none,stroke:#CF4A4A,stroke-dasharray:4 3
```

## One refresh, end to end

The refresh ends at publication. Everything after it is follow-up work that never holds the refresh, its loading state or the next manual refresh.

```mermaid
sequenceDiagram
    autonumber
    participant FM as FeedManager
    participant FF as FeedFetcher
    participant DB as DatabaseEngine
    participant EQ as EnrichmentQueue
    participant EC as EventClusterer
    participant SC as StoryCurator
    Note over FM: fetchFeedsAsync — timer, background activity, wake or ⌘R
    FM->>FF: due feeds (≤6 requests, ≤2 per host)
    FF-->>FM: 200 / 304 / failure + Retry-After
    FM->>DB: one transaction per feed: articles + validators
    Note over FM: publish one library snapshot — refresh ends
    par follow-up, caller-owned
        FM->>EQ: notification triage, bounded classification
    and
        FM->>EC: clustering pass (off main actor)
        EC->>SC: lead-image lookup (≤30 stories)
    end
```

| Area | Owns |
|---|---|
| `Sources/App/` | `NewsApp` lifecycle, scenes, commands, notification routing · `AppContainer` DI · `AppSettings` defaults, feed URL normalization, mute rules storage · `ThemeManager` · `UpdateChecker` · `NewsSignposts` |
| `Sources/Views/` | `MainView` coordinator · `SidebarView`, `ArticleListView`, `ArticleCardView`, `EventCardView`, `FeedHealthLine` · `ArticleDetailView` + `ReaderSupportViews`, `ArticleWebView`, `WebPreviewPolicy` · `EventOverviewReaderView` · `TensionIndexView` · `ArticleRemoteImage` · `FeedCatalogView` · `SettingsView` · `DesignSystem` |
| `Sources/Storage/` | `DatabaseEngine` schema, WAL/FTS5 · `DatabaseEngine+Events` events, overviews, reading state, embeddings · `ArticleStore` · `MigrationCoordinator` · `ReadManager`, `SavedStoriesManager` · `CacheManager` (HTTP cache, separate from user state) |
| `Sources/Models/` | `FeedArticle`, `ArticleIdentity` · `FeedFetchState` validators and backoff · `FeedCatalog` · `EventOverview`, `EventFeed` · `FeedAdvisory`, `ArchiveSearchToken` · `MuteRules` · `FeedError` |
| `Sources/Coordinators/` | `FeedManager` orchestration, lifecycle, sleep and wake · `NotificationService` triage |
| `Sources/Services/` | `FeedFetcher`, `SecureHTTPClient` · `FeedXMLParser`, `JSONFeedParser`, `DateParser` · `IPAddressValidator`, `NetworkBoundaryProxy` · `OPMLManager` |
| `Sources/Intelligence/` | `ContentExtractionPipeline` · `ArticleIntelligence` · `EnrichmentQueue` · `EventCandidates` (+ `EventStoryRelation`) · `EventMatcher`, `EventClustering`, `SentenceEmbedder` · `Overview*`, `PassageFactExtractor`, `CoverageSentimentEvaluator` · `StoryImportance`, `EventJudge`, `PromptDefense` · `WorldTension`, `TensionMethodology` |
| `Tests/` | `NewsTests` runner and suites · `FeedKitSwiftSoupTests`, `EventEmbeddingTests`, `NotificationAttachmentTests`, `StoryCorpus` · `Native*` and accessibility harnesses (some open windows, opt-in) · `TestDefaults` |
| Platform | `News.entitlements` · `build.sh`, `test.sh` (skips the Swift runner for inputs that already passed; `NEWS_TEST_FORCE=1`), `script/build_test_runner.sh` (runner build, `NEWS_TEST_ATOM`), `script/ci_testsuite.sh` (one JUnit case per `Tests/*.swift` atom, `--lcov` for impact analysis) · `build_release.sh` (runs in every CI build), `script/version.sh` (bundle version from git tags), dormant `script/distribution/` · CI: three providers run on every push and pull request to `main`: GitHub Actions is the pipeline of record, CircleCI adds test-impact analysis, Codemagic runs the full suite, the format check and the release build; `.github/workflows/`, `.circleci/config.yml`, `codemagic.yaml` |

## Schema history

SQLite changes always ship as migrations that preserve WAL/FTS5, saved stories, read history and settings.

```mermaid
timeline
    title SQLite user_version
    section Identity
        v5 : ID and document-URL aliases
        v6 : GUIDs scoped to subscription URL
        v7 : Exact-content aliases
        v9 : Historical row reconciliation
    section Feeds and search
        v10 : Per-feed failures and backoff
        v11 : Feed health counters
        v12 : Null-safe FTS triggers
        v15 : Durable FTS keys
    section Stories
        v13 : events, event_members
        v14 : Clustering progress, exclusions, seen state
        v16 : Publisher content revisions
        v17 : Importance ratings
        v18 : story_images
        v19 : image_url index
    section Models and repair
        v20 : Model build stamp
        v21 : MiniLM article_embeddings
        v22 : Category and publisher repair
        v23 : Source newline cleanup
        v24 : article_features and pair_assessments
        v25 : event_inclusions
```

## Invariants

Open a section before changing that area. Each rule is load-bearing; tests cover most of them.

<details>
<summary><b>Layering, concurrency, lifecycle</b></summary>

- No UI concerns in database, networking or domain layers. No main-actor database work.

- Preserve actor isolation; bound batch concurrency and memory; avoid retain cycles.

- Cancellation propagates through feed, extraction and enrichment. Shared refresh work survives one waiter cancelling; explicit reset cancels it.

- Unstructured tasks need an explicit lifecycle owner.

- Ingestion stays cheap. Extraction and analysis run on demand or under bounded enrichment rules.

</details>

<details>
<summary><b>Article identity and storage</b></summary>

- Stored article IDs never change when publisher metadata changes. Homepage and missing URLs are never dedup keys.

- Resolution order: scoped GUID (v6) → document-URL alias (v5) → exact-content alias (v7) → historical reconciliation (v9) → publisher-title match (#583: same publisher, same folded headline of four or more words, published within 12 h of a stored story, compared in Swift over that publisher's stories of the window, no alias row; a recurring daily headline a day apart stays separate). URL/GUID evidence wins; conflicting aliases stay ambiguous (NULL target) and are never revived or guessed.

- v9 reconciliation needs an exact document URL plus substantial matching publisher body. Originals stay stored; lists/search/counts hide them; old IDs resolve to the survivor with unioned read/save state. `includingOriginals` retrieves them.

- Undated articles keep the `Date.distantPast` sentinel; ordering, paging and retention fall back to ingestion time. Upserts keep known values when incoming metadata is invalid.

- v15 FTS joins and triggers use `article_fts_rows` keys, never the hidden rowid (safe across `VACUUM`). v12 triggers skip identical refreshes.

- v16: publisher input (title, summary, body) is hashed; at most 20 revision rows per article, no body copies. A change invalidates article analysis and affected overviews; every write carries its input hash and is rejected if input moved. The reader labels local observations, never verified corrections.

- Multi-step writes use transactions.

- Retention: `FeedManager` runs `pruneOldArticles` once a day after a completed refresh, with the Settings › Storage age (default 30 days, 0 = never). Only read, unsaved stories older than that go; unread, saved and overview-cited stories and events with a stored overview stay. Clearing AI analysis removes enrichment, overviews, embeddings, stored matcher signals and tension history in one transaction; stories, events and pair decisions (ids and scores only) stay.

- Stories a cancelled refresh had already committed are notified by the next completed refresh; cancelling ends the loading state at once.

</details>

<details>
<summary><b>Subscriptions, refresh, networking</b></summary>

- Subscription URLs are stored after `AppSettings.normalizeFeedURL` (lowercase scheme/host, HTTPS, bare root slash removed). A non-root trailing slash is part of the address. Duplicate checks use slash-insensitive `AppSettings.feedKey`. Stored subscriptions are never rewritten: scoped GUIDs hash the exact string.

- `FeedFetcher` is the single refresh path: ≤6 requests, ≤2 per host. Backoff 10 min doubling to 6 h; `Retry-After` on 429/503 is a lower bound capped at 24 h. Local rejections, cancellation and fully offline batches are not failures.

- Requests are conditional. ETag/Last-Modified live in `feeds`, written only inside the ingestion transaction, short printable ASCII only; 304 touches nothing.

- Sleep cancels a refresh without recording failures. After wake (short network delay) one refresh runs if needed.

- Background classification skips Low Power Mode and serious thermal state; scheduled refreshes honor `NSBackgroundActivityScheduler.shouldDefer`.

- New-story notifications use IDs inserted by a committed transaction, skip muted stories, and resolve via SQLite by stable ID once storage is ready. Clustering runs first, so the reports of one event notify once, through the report that scores highest. Full mode sorts each story or event into a priority, starred or normal lane with its own limits, recorded in side tables so they hold across refreshes and relaunches (`docs/notifications.md`).

- All URLs, feed bodies, HTML, redirects and OPML are untrusted. Remote fetching goes through the protected gateway: public-DNS validation, numeric-IP pinning, response bounds, cancellation. URLSession and WebKit previews share it.

- Feed XML: depth 64, 500 items, entity declarations rejected (64 KiB prolog scan + callbacks), FeedKit gets reserialized DTD-free items ≤512 KiB and never fetches URLs. JSON feeds ≤10 MiB, trimmed to 500 items.

- Image requests honor HTTP freshness/no-store after destination validation; decoded images live in a session-only `NSCache`.

</details>

<details>
<summary><b>Reader extraction</b></summary>

- `HTMLDOMBuilder` scoring with a quality-checked preference for explicit publisher bodies chosen through SwiftSoup. Repaired nodes pass the same rules.

- Reader v11 removes page furniture by structure and wording, never per publisher:
    - `<h1>` is never body text. The `<p>` right after it, and a Guardian-style standfirst beside the explicit body, become `standfirst` blocks; a paragraph repeating the standfirst is dropped.
    - Phrasing elements (`span`, `a`, `time`, `strong`, …) never form paragraphs of their own, so a `<time>` stamp is judged as metadata.
    - Utility-hidden subtrees (`hidden`, `d-none`) are skipped unless a responsive class such as `md:block` shows them. Class tokens for author bios, follow-author prompts, `more-on`/most-read/top-stories rails, timestamps, recommendations and native ads are skipped; layout modifiers such as `article-with-sidebar` are not tokens and keep the body.
    - Headings that name navigation ("Most Popular", "Recommended Stories", "Related Articles", "Top Stories") are dropped; a trailing one takes the non-prose cards after it. A short author bio ("… is a space reporter at …") as the first or last text block goes.
    - A body under 5,000 characters that ends in its own "Read full article" or "Continue reading" link is `isComplete: false`, so the reader fetches the page instead of showing the feed teaser.
    - Debug a saved page with `NEWS_DEBUG_BLOCKS=1 ./test_runner --debug-extract page.html` from the repository root.

- Reader v10: short `<p>` sentences ("He was 34.") stay; `<br>` and paragraph breaks inside a block are kept as line breaks (source-formatting newlines stay spaces) without dropping inline formatting; nested lists become items one `level` deeper; data tables (≥2 × 2, short plain cells) become `table` blocks, larger than 8 × 40 a notice, layout tables are read as content; editorial asides become `standfirst` or `pullQuote`; social-post blockquotes become `embed` placeholders; `<sup>`/`<sub>` mark `baselineShift`; plain "(Updated: …)" stamps are dropped. New fields are optional and unknown kinds decode as paragraphs, so stored documents stay readable.

- Reader v9: scripts/styles end at their first closing tag; explicit bodies are judged with children and must hold ≥40% of scored prose; metering wrappers with ≥2 paragraphs stay; `x-cloak` and form controls are hidden. v8 drops timestamp-only blocks; v7 adds `subscriberOnly` (barriers, `isAccessibleForFree: false`, 401/402; 403 shows the same preview), JSON-LD `articleBody` and `__NEXT_DATA__` fallbacks, standfirsts, pull quotes. Older stored documents re-extract on open.

- Document v4 keeps inline runs, image candidates, credit and an explicit selected lead; without a selected lead, `ReaderDocument.selectedImage` falls back to the first usable extracted image. The JSON-LD lead image is read before scripts are stripped; feed parsing accepts image file extensions, `data-src`/`data-original`, and `content:encoded` images without body text. Only a document with publisher text (`ReaderDocument.hasPublisherText`) replaces extraction; feed media never overwrites stored text.

- Extraction records the protected final URL and at most one same-origin canonical URL, only after matching text and title. Canonical declarations alone never merge identities.

- Render sanitized HTML. WebKit previews disable publisher scripts and block local resources. Never log secrets, article contents or full sensitive URLs.

</details>

<details>
<summary><b>Events and clustering</b></summary>

- An article belongs to at most one event (v13), by surviving stored ID. Events never copy source text. Each member-set change bumps the membership version once.

- Merges forward the absorbed ID one hop; splits give moved members a new ID. Neither touches article rows or read/save state. Events cap at 100 members.

- Candidates (`EventCandidateFinder`): ≤8 terms per article as FTS5 phrases (headline names, then headline words, then names from the description), ≤2× `EventCandidatePolicy.limit` rows, ±48 h window, 72 h active lifetime. Candidates are not matches.

- `EventMatcher` v12: `EventFeatures.matchingText` (plain headline + first 600 plain description characters) is the one text both the deterministic features and the sentence embedding read. A pair needs dates within 36 h, a shared specific anchor (a country alone is not enough) and no conflict in language, period, year, weekday, act, distinguishing figure or place. A headline's primary clause before "after"/"following" guards against background-clause merges only when it names an act; a clause that only counts consequences ("Three dead after …") does not. A word of a typed person name is never canonicalized to a country. Grey-zone pairs use MiniLM cosine (`SentenceEmbedder` model version 2: uncased, accent-stripped WordPiece; v21 embeddings recompute per version). Semantic rescue (v9) links a pair the rules miss when it shares a specific anchor, has no conflict and its cosine is ≥ 0.70: the cutoff was chosen on the tune split (24 October 2026; 0.65 produced the first false pairs) and confirmed once on the English holdout (precision 1.000, recall 0.447 → 0.579). The 0.55 veto also applies to rule matches (skipping it merged four authored negatives), the >12 h strict rule stays (dropping it merged two), and the pair score keeps `max(rule, cosine)` (no measured effect); a common-actor guard exists only in developing-story links. Admission: one matching pair, ⅔ compatible members (rounded up), the mean-score threshold.
- Pair model (v11, #525): a borderline pair with no conflict and at least one shared name, place or country goes to the project's own cross-encoder (`PairScorer`, `pairscorer.mlmodelc`: all-MiniLM-L6-v2 fine-tuned on pairs mined from library copies by `--export-pairs`, both orders averaged, cached per text pair). At probability ≥ 0.9, chosen on tune, the pair is a match that stands in for the shared specific anchor in admission (`modelConfirmed`); hard conflicts, exclusions and the semantic veto still refuse it, and fragment merges are settled by the rules before the model is asked. Without the model the matcher decides as v10. A retrained model bumps the matcher version. Both neural paths (semantic veto and rescue, pair model) run only when neither report is recognized as a language other than English; other pairs are decided by the rules alone, and no embedding is computed for such reports (#553).
- Act class (`ActClass`, v10, #522): the lemmas of the act clause (the primary clause before "after", "following", "over", "amid", else the whole headline) map through a small checked-in cue table to one of vote, protest, attack, agreement, personnel, ruling, sanction, disaster, crash, or to the consequence classes casualties and rescue; two act cues or none give `unknown`, which never vetoes. Two known, different acts are two events (`EventConflict.differentAct`); a consequence report stays compatible with the incident that could have caused it and conflicts with bloodless acts (agreement, personnel, sanction; votes and rulings use the casualty words politically). A crash and an attack never conflict, and "attack" counts only as a noun. The cue table is the project's convention written down, not a model; a wrong class costs recall with a visible related-act link, never a merge.
- Stored signals (v24 `article_features`): `EventFeatures` as JSON under `EventFeatures.storageVersion`, written by the clusterer on first use and read by every later pass and by `EventStoryRelation`; a changed title or description, a version bump or clearing AI analysis drops them (the same trigger now also drops the embedding). Publication dates are always taken from the row, never from the stored record.
- Clustering order (#541): a pass reads pending rows newest first, so the stories a reader sees first are grouped first after a matcher bump or a large import; the fragment-merge pass indexes active events by their terms (specific anchors and keywords) and compares only events that share two, the same candidates the pairwise intersection found, in the same order.
- Pair decisions (v24 `pair_assessments`): the clusterer records each assessed pair it matched, judged a related act (the act conflict is the only one, with a shared specific anchor and two shared keywords), found borderline or vetoed while sharing evidence (an anchor or two keywords; reason = the conflict), after each batch and only while the article reads as the pass saw it, keyed low id first, with the matcher version, score, and the `features` JSON (`EventPairFeatures`: cosine, pair-model probability when asked, conflict, shared-evidence counts; #551) and no text. `--review-pairs` exports the rows of a library copy with headlines and corrections for the review protocol in CONTRIBUTING. Related-act rows feed "Earlier in This Story" next to the lexical relation's links (earlier events only, ≤3 in all) and are the audit trail for later matcher work; a fitted decision head was measured and not adopted (#524).
- `Tests/Fixtures/story-corpus/matcher-regressions-v1.json` is an authored English corpus replayed through the real clusterer on every test run with a true-positive floor and a false-pair ceiling; it is regression evidence, not the acceptance gate (the private holdout is).

- Clustering is fully on device; no external LLM. The on-device event judge (Foundation Models) was removed in v12 (#580); `EventJudgeReport` remains as the importance rater's input.
- Headline names as anchors (v12, #580; `EventFeatures.storageVersion` 2): a word written with an inner capital ("OpenAI", "iOS", "SpaceX") is a name wherever it stands; a capitalized word at a sentence start, or in a Title Case headline, is a name when the text also writes it capitalized mid-sentence or the lemmatizer does not know it; a product followed by a version is one anchor ("ios 27.2"); "Pope" is an anchor and "Pope Leo" also yields it; a place conflict needs fewer than three shared specific names, so one place the tagger mistyped cannot veto a pair that shares teams and players. Library holdout: recall 0.182 → 0.318 at unchanged wrong links; authored corpus and private tune replay unchanged.

- `EventClusterer` runs after publication and at launch, off the main actor, ≤2,000 articles per pass. Version upgrades revalidate active events; the earliest subgroup keeps the ID. One transaction moves members and invalidates overviews; rollback leaves work pending.

- v14 `event_exclusions` ("Not the Same Event") and `event_state` (seen version, only grows). Opening an event never marks articles read.
- v25 `event_inclusions` ("Same Event" on an "Earlier in This Story" row, "Same Event as…" on a story row of an expanded event card, #524): the related event merges into this one and every pair across them is recorded; the clusterer treats a recorded pair as a match whatever its signals say (`EventMatcher.forced`), so revalidation and re-matching keep it, and the inclusion is transitive: a report that matches one side counts as the same event as the other side, so later reports still join. A combine never exceeds the 100-member cap. Separating a member drops its inclusions and excludes it only from the side it was combined with; including it again drops those exclusions: the newer correction wins.

- Regression comparisons follow the 17 October decision in [the release simplification plan](plans/2026-10-17-release-simplification.md). Earlier measurements stay in dated audits.

</details>

<details>
<summary><b>Overviews and developing stories</b></summary>

- Overviews are generated on request or for the visible event, on `EnrichmentQueue`, never in the refresh path. Opening an article of an event with ≥2 sources requests one.

- `OverviewGenerationCoordinator` shares a run only for the same membership version, input hash and publisher inputs; changed inputs cancel it; only the latest inputs commit. `cancel(eventID:)` stops it for all callers.

- A reader clears the visible event only if it set it (`clearVisibleEvent(owner:)`); after each storage suspension it rechecks its article and input.

- Production overviews are deterministic publisher sentences with per-source citations (`fallbackExcerpts` provenance). Analysis version 9. Up to four representatives without text are extracted first (≤2 concurrent, 4 s each). Citation rows key on overview ID + citation ID.

- The overview reader shows introduction → Highlights grouped by publisher (`ClusteredHighlightGroup`) → timeline rail → perspective cards → numbered sources; superscript citations open the cited passage. Sentences come from `PassageFactExtractor.segmentedSentences`, which rejoins `NLTokenizer` splits at abbreviations (`St.`, `U.S.`, `Dr.`) and inside open quotes; `OverviewComposer` evidence counting uses it.

- Timelines (`OverviewTimelineBuilder`): a verified quote with exactly one explicit date, shown at its stated precision; relative dates are not resolved; fewer than two dates means no timeline.

- "Earlier in This Story" (`EventStoryRelation`): English, earlier event within 7 days, a shared uncommon typed actor (not in >5% and ≥10 of last week's events), a shared place, two shared topic terms, ⅔ member support. ≤80 FTS rows, ≤40 candidates, ≤3 links. Writes nothing. [Audit](audits/2026-10-20-developing-story-links.md): 1 wrong of 45 after the common-actor rule.

</details>

<details>
<summary><b>Briefing, feed list, muting, images</b></summary>

- Briefing is a daily edition: ≤10 unread, unmuted reports from a 24 h window, ≤500 candidates, ≤2 per publisher, 1 per event. Frozen in preferences across windows until the edition hour (default 7:00) or New Edition. Order: stored importance, publisher coverage, interests from ≤200 recent read/saved stories, then diversity, recency, stable ID. Selection never calls a model.

- Importance never hides or expires stories; refresh never rates it.

- The feed groups an already filtered page (`EventFeedGrouping`). `FeedUpdateBuffer` holds a shown list; additions and regrouping wait behind an explicit update. Saved Stories and History stay ungrouped and unmuted.

- Muting (`MuteRules`) is the reader's own: hosts (cover subdomains) and whole-word topics on headline + feed summary. Applied in SQLite before `LIMIT` via `news_muted_source` / `news_muted_topic`.

- Lead images (`StoryCurator`, after a clustering pass): ≤30 imageless shown stories, `fetchArticleHead` reads ≤256 KiB. An image declared by two stories is a site default and dropped.

- Panel-only feeds are excluded from normal lists before paging; the tension corpus keeps them.

</details>

<details>
<summary><b>Intelligence, catalog, World Tension</b></summary>

- `NaturalLanguage` + conditional `FoundationModels`, fixed 12-category taxonomy, plain-text model contracts with strict parsing and extractive fallbacks. v20 stamps the macOS build; a model change invalidates generated summaries, not publisher excerpts.
- Two prose surfaces call Foundation Models, the reader summary and World Tension; ingestion, classification, search and clustering never do (clustering uses the bundled MiniLM CoreML model and the project's own pair model, never a language model). `NewsTextModel.onDevice` maps every `LanguageModelSession.GenerationError`, and on macOS 27 every `LanguageModelError` and `SystemLanguageModel.Error` (the types that SDK actually throws; built only with it), to one outcome: `Rejected` (guardrails, refusal, context window, unsupported language, undecodable output) is final, so the extractive summary stands and a refused World Tension input keeps its keyword estimate as the day's saved reading until the headlines change; `TemporarilyUnavailable` (model off, downloading, busy, rate limited) keeps a provisional result (an unsaved estimate for World Tension) that is redone when next requested. Only the outcome label is logged, never text. Story text the language recognizer reads as non-English gets the final extractive summary without a model call (#550). Publisher category hints match whole words only.
- One energy rule (`IntelligencePolicy.allowsEnergy`): background classification, overview warm-up, story images and World Tension pause in Low Power Mode and from the serious thermal state on. Clustering keeps running with the rules alone (#534): no embedding is computed and the pair model is not asked. A pair without a stored vector is not merged (the semantic veto has not cleared it) and a borderline pair is not confirmed; the rows involved are marked one matcher version behind, members already matched are not revalidated, and the next pass with energy reads them again. Hard conflicts, exclusions and pairs with stored vectors decide as usual.
- World Tension: the reading shown is methodology v3, the 7-day exponentially weighted average of accepted assessments (α = 0.25) plus up to 9 points of momentum for consecutive rises; estimates are shown as they are, stored readings keep the assessed scores, and 90 days are kept (`WorldTensionSmoothing`, `docs/methodology/world-tension-v3.md`).

- Persist only intelligence that product behavior needs; keep model identifiers, analysis versions and deterministic fallbacks.

- `FeedHealth` is operational only (availability, freshness, text quality), never a rating of accuracy or trust (`FeedHealth.disclaimer`).

- The starter catalog is opt-in data: nothing auto-subscribes; entries record `FeedCatalog.verifiedOn`. Only free, open sources that open in the reader; others go to `AppSettings.retiredFeeds`. English only (`FeedCatalog.supportedLanguages`); other-language entries stay parked (#264). Re-verify with `NEWS_LIVE_CATALOG_CHECK=1 ./test.sh` and `./test.sh --catalog-reader-access`.

- World Tension (`WorldTension`, methodology v2) reasons over bounded headlines with lexical grounding. `TensionMethodology` and [the v1 methodology](methodology/tension-index-v1.md) change together; it computes no score until weights are calibrated (#158).

</details>
