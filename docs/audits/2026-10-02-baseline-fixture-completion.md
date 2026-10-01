# Baseline fixture acceptance — 2 October 2026

## Scope and order

Complete the earliest remaining offline gates (#100, #101 and #107) before adding event clustering. Phase E and the previously reserved phase G remain owned elsewhere. This slice changes tests and evidence only; it does not change production normalization, merging, reader behavior or schema.

## Identity evidence

`testIdentityBaselineScenarios` runs in both the default and focused story suites. It parses synthetic RSS through FeedXMLParser and ingests into isolated SQLite databases:

- `page`, `article_id`, `post`, `lang` and `reference`: a tracking-only URL/GUID update reuses the document and read/save state; a changed meaningful value remains a distinct document despite identical headlines and teasers. Empty and repeated meaningful values survive normalization.
- Same-origin mobile and AMP paths remain different URL keys until protected extraction verifies a canonical page with matching substantial text/title. After verified alias registration, a new desktop feed entry resolves to the original ID and history. Path spelling alone is not equivalence evidence.
- Two publishers using identical substantial wire text, title, date, label and raw GUID retain separate documents and independent state through different host/subscription identity.

Existing tests cover protected redirect response destinations, canonical mismatch/unsafe/cross-origin rejection, GUID changes/collisions, overlapping feeds, publication-date changes, matching headlines of different stories, and copied-library reconciliation. A cross-origin mobile hostname is not automatically aliased by a canonical declaration; existing same-origin policy deliberately refuses it. A protected redirect can supply destination evidence.

These fixtures confirm known mechanisms and expected outcomes. They do not establish the cause of every duplicate in the user's library. No real library is inspected or mutated, and no holdout precision is claimed (#102 remains open).

## Reader evidence

The merged phase C suite has twelve synthetic structures: paragraphs, nested main/headings, break-separated div prose, mixed unwrapped text, strong/emphasis, links/code, block quote, ordered list, malformed omitted paragraph closings, hidden style, credited lazy figure and picture/srcset/noscript fallback. Default and focused runners both invoke it.

Explicit assertions now pin a missing-image text-only document, preservation of prose when declared image dimensions exceed the bound, and RSS publisher HTML with no fetchable page URL. Existing `testReaderFigures` covers DOM order/captions/alt, hidden/tiny/duplicate media, persisted reader documents, bounded raster thumbnail decoding and malformed image data. Existing paywall rejection and legacy-document tests remain enabled.

This completes offline fixture scope, not native VoiceOver/copy/OS accessibility acceptance (#123) or concrete user problem-page tracing (#115). No generated prose or copyrighted full publisher article is added.

## Validation

The focused story suite passed after adding identity scenarios. The full default suite passed with all final assertions on arm64, macOS 27.0.1, Xcode 27 and Swift 6.4 (Swift 6 language mode, macOS 15 deployment target). The mandatory commit hook remains enabled; publication status and its result are recorded on the issues. No app build or install is needed for this test/evidence-only slice.
