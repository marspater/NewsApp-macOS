# Phase C: reader and images — 1 October 2026

## Run plan and boundaries

Handle phase C as one run: trace extraction → feed parsing → storage → reader; retain inline formatting and image attribution; curate publisher media; stabilize images and adapt typography; run offline regressions, native QA and a staged build; publish one linked PR. Phases E and G are owned by other agents and remain outside this implementation. Image HTTP-cache work (#161) remains separate. Do not merge PRs or install over the user's app.

## Implementation

- Reader document v4 adds optional inline runs, image credit/dimensions, bounded image candidates with origin, and an explicit selected lead URL. Existing v2/v3 JSON and publisher text remain readable; valid older stored documents can be read offline without mandatory extraction. No database schema change.
- HTML parser retains strong/emphasis/code/links, resolves relative links structurally, excludes executable/credential URLs, and renders one selectable native attributed Text per block. Publisher headings are retained; none are invented. Explicit break-separated long prose and mixed unwrapped text preserve their boundaries and DOM order.
- RSS/JSON HTML uses the same structured extractor before storage. Atom XHTML is serialized from parser events rather than flattened; plain content and failed extraction retain existing text fallbacks. Audio enclosures cannot become image candidates.
- Figures retain separate captions, photographer/agency credit where provided, image origin host, alt text and known dimensions. Feed media and Open Graph dimensions are retained where provided. Attribution does not imply image rights.
- Bounded srcset/picture candidates, data-src/data-original/data-lazy-src and noscript image fallbacks are supported. URL resolution and existing protected HTTP/ImageIO limits remain in place. Hidden/tiny media, logos, tracking-like paths, ad containers and duplicate URLs are excluded.
- Candidate ranking prioritizes title overlap in publisher caption/alt text and body association over image size. This is a deterministic publisher-association heuristic, not semantic verification. Missing suitable media yields a text-only card.
- SQLite curation counts recurring URLs within a publisher across at least three distinct document URLs, including stored candidate arrays. Lists/search reuse the same curation, off MainActor, once per source per result batch. The most recurrent 64 URLs are considered; valid recurring editorial photographs can be suppressed. No similarity model or cross-publisher reputation score.
- Card image slots retain the same height through loading/failure/success. Reader images reserve a known bounded aspect ratio and fit the whole image. Standard/Large/Extra large native menu options scale body/lead/title/heading/caption typography, spacing and column width; narrow windows constrain the column naturally.

## Verification ledger

Offline coverage includes twelve controlled page structures, plus RSS CDATA/JSON HTML/Atom XHTML and feed-media fixtures. Cases cover DOM order, explicit breaks, mixed text, inline formatting, relative/unsafe links, credits, unquoted attributes, responsive/lazy/noscript images, missing/decorative media, malformed and hidden HTML, paywall rejection, v3 compatibility, JSON round trips, SQLite persistence, clearing a rejected image, recurrence and source isolation. Existing figure/ImageIO/legacy migration/read-save/FTS coverage stays enabled.

Native QA uses the real ArticleDetailView in `/tmp/news-phase-c-ui`, an in-memory database, separate defaults/app identity and synthetic image data through a harness-only URLProtocol. It does not validate live publisher images or HTTP cache reuse. The harness does not ship in production.

Final command results, native observations and remaining gates are recorded in the PR and project issues. Passing source/AX checks do not constitute a full VoiceOver interaction audit. No production library, installed app or OS accessibility preference is changed.

Observed native QA: light/dark reader, 520/900/1400-point window widths, Extra large text, figure alt text/caption/credit, heading accessibility roles, and keyboard save/unsave passed in the disposable app. Window high-contrast appearance was exercised; this is not a complete OS Increase Contrast audit. Clipboard copy, full keyboard traversal, VoiceOver interaction and OS Reduce Motion remain acceptance gates in #123.

`./test.sh --story-regressions` passed. `./test.sh --reader-live-pages` passed for the existing BBC fixtures: c6jdvmy1287yo (2,773 prose characters, 17 blocks, 3 candidates) and cm750pyz5r0eo (5,151 characters, 38 blocks, 6 candidates). These two live pages establish extraction behavior, not broad publisher coverage. The twelve varied page structures are controlled offline fixtures.

After rebasing onto `0324b81` (including merged E defenses and historical reconciliation #177), `./test.sh` passed in full. Explicit `includingOriginals` retrieval now bypasses display-only image curation, with a regression preserving stored media metadata. The arm64 ad-hoc bundle built successfully; strict signature verification and Info.plist validation passed. A compiler warning about a trailing closure was corrected before publication. No installation or distribution validation was requested.
