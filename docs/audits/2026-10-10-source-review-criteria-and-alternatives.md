# Source review criteria and alternative discovery — 10 October 2026

## Scope

Implements #416 (Phase 1 of #244): documented maintainer review criteria, review manifest schema, and automated validation tooling for periodically reviewing curated starter catalog feeds and discovering alternatives.

## Review Principles & Boundaries

1. **Separation of Operational Health and Editorial Verdicts**:
   - Technical deterioration (feed reachability, HTTP 429/500 failures, malformed XML, stale items, or teaser-only truncation) is tracked by `FeedHealth`. These are plumbing signals only and must never be recorded as editorial verdicts.
   - Editorial assessment evaluates publisher transparency, ownership changes, reporting independence, and original coverage versus clickbait or syndication slop.
   - Disagreement with event cluster majority is never evidence of unreliability; syndicated reprints are never independent corroboration.
   - Insufficient evidence is explicitly labeled `unknown`.

2. **No Silent Changes to User Subscriptions**:
   - The starter catalog is opt-in data.
   - Catalog updates, advisories, or retirements must never silently unsubscribe, mute, or substitute a reader's chosen feeds.
   - Subscriptions in `AppSettings.feedURLs`, bookmarks in `SavedStoriesManager`, and reading history in `ReadManager` remain preserved.
   - Changes surface transparent, dated review notices with optional, explicit reader choices.

3. **Human-Reviewed Evidence, Zero Black-Box LLM Scoring**:
   - No automated trust scores or ungrounded machine-generated reliability ratings.
   - Assessments record verified review dates, reviewer identity, public evidence links, specific structured reasons, and uncertainty ratings.

4. **English-Only Scope for Current Release**:
   - Alternative recommendations and topic gap discovery operate on the supported English catalog sets (PR #269, parked #264).
   - Parked non-English feeds remain intact in `FeedCatalog.allFeeds` as parked records.

## Structured Review Criteria

### A. Technical Assessment
- **Availability**: HTTPS reachability, adherence to conditional headers (304), absence of persistent HTTP 4xx/5xx errors.
- **Freshness**: Active publishing cadence within the normal window (recent within 3 days; quiet within 30 days).
- **Reader Accessibility**: Article pages open cleanly in native reader mode without blocking automated readers (HTTP 403, Cloudflare challenges, or hard subscription walls). Feeds where article pages refuse automated extraction are marked `previewOnly` or given a `readerInaccessible` advisory.
- **Text Completeness**: Full text, partial text, or summary teasers.

### B. Editorial Assessment
- **Ownership & Governance**: Public disclosure of publisher ownership, masthead, and editorial leadership. Changes in controlling ownership or corporate restructuring trigger a review.
- **Original Reporting vs. Syndication**: Genuine investigative or reporting output versus uncurated syndication-mill aggregation.
- **Editorial Corrections & Standards**: Published, accessible corrections policy and adherence to professional journalistic practices.
- **Independence**: Absence of undisclosed state propaganda or covert commercial sponsorship.

### C. Assessment Statuses & Uncertainty
- `status`:
  - `active`: Feed and publisher meet both technical access and baseline editorial standards.
  - `advisory`: Notable technical deterioration or documented editorial shift surfaced to readers.
  - `retired`: No longer carried in the starter catalog (e.g. hard paywall, broken feed, or low-quality slop).
- `uncertainty`:
  - `known`: Conclusive public evidence (official announcement, verified technical reproduction).
  - `provisional`: Initial report or observation pending full independent confirmation.
  - `unknown`: Insufficient verifiable evidence; no adverse judgment applied.

## Manifest Schema (`catalog-review-v1.json`)

The manifest is versioned and stored under `Tests/Fixtures/catalog-review/catalog-review-v1.json`:
- `version`: integer schema version (1).
- `reviewedOn`: ISO 8601 date (YYYY-MM-DD).
- `reviewer`: maintainer identifier.
- `feeds`: array of feed review entries:
  - `id`: matching a catalog feed in `FeedCatalog.allFeeds`.
  - `url`: normalized feed URL.
  - `status`: `active`, `advisory`, or `retired`.
  - `advisory`: optional object containing:
    - `date`: review date.
    - `reason`: `technical_deterioration`, `reader_inaccessible`, `paywall_introduced`, `ownership_change`, `syndication_shift`, or `standard_update`.
    - `summary`: concise, factual explanation without marketing or subjective bias.
    - `evidenceLinks`: array of public documentation/reproduction URLs.
    - `uncertainty`: `known`, `provisional`, or `unknown`.
    - `suggestedAlternativeFeedIDs`: array of valid alternative catalog feed IDs.

## Validation Tooling

`script/evaluation/catalog_review.py` runs during `./test.sh`:
1. Validates that all feed IDs and URLs in the manifest exist in `FeedCatalog.allFeeds` and are normalized HTTPS URLs.
2. Validates that every suggested alternative references a valid, offered catalog feed.
3. Enforces valid ISO 8601 calendar dates and evidence URL schemes.
4. Verifies that no private local paths or tracking mechanisms are introduced.
