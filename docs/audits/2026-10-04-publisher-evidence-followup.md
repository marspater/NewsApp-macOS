# Publisher timestamp, negative and URL evidence — 4 October 2026

Refs #102, #110, #126, #127. Base `28e45e3`, after #249–#251 merged. Evaluation-only tools and metadata; no production matching thresholds, source catalog, stored subscriptions, app library or installation changed. Publisher text stays private under `/Users/marspater/Documents/NewsHoldout-2026-10-03/` (0700 directories / 0600 files). This follow-up runs no fingerprint or event holdout predictions. The October 3 captures were inspected for support on both splits in #251 and are not acceptance evidence.

## Publisher dates

[Timestamp evidence](../../Tests/Fixtures/story-corpus/publisher-timestamps-v2.json) covers all 183 original observations, retaining response hashes, original date fields and captured feed dates. The protected client retrieved 175 of 177 unique original URLs; the two HTTP links were subsequently checked at their HTTPS counterparts, following the app's document URL scheme normalization.

- 116 feed timestamps agree with publisher publication time within one second.
- 39 agree with the page's modification time instead of original publication time.
- 20 differ from publication time: 12 by at most a minute, eight by more. Some feeds have coarser timestamp precision; not every discrepancy implies a wrong date.
- Six video pages provide upload-time evidence, retained separately from article publication time.
- Two Africanews pages remain unresolved: malformed `CEST` text in OpenGraph timestamps conflicts with JSON-LD publication dates. A successful fetch is not a verified publication timestamp.

The offline parser uses page-scoped JSON-LD and published/modified meta fields, checks saved response hashes and retains contradictory or unzoned data. It ignores unrelated nested recommendation dates. No captured feed timestamp or frozen v2 byte was rewritten. Production replay must keep the dates the app sees and report publication/update distinctions separately.

## Expanded source proposals

The [frozen supplement](../../Tests/Fixtures/story-corpus/publisher-review-supplement-v1.json) adds 52 document IDs and 62 proposed pairs: 30 same-event, 26 different and six same-document. Combined with v2, the pool has 235 IDs and 462 proposed pairs. Ten supplement IDs reference v2 observations. The supplement has 55 tune and seven holdout pairs; all approvals remain pending.

Nine fresh multi-source occurrence proposals cover the FP-9 announcement, reserve pontoon-crossing plan, Portuguese Lajes investigation, Haivoron drone-road incident, Shestakove car attack, Ukrainian deficit statement, counterstrike report, Medicare payment announcement and Irene Butter's death. Existing German speech, Latvian exit-poll and Northern Bridge proposals gain coverage. The newly identified pontoon counterpart to v2's singleton `doc-0273` is an explicit pending correction, staying in tune. Broad roundups, thematic features and unclear boundaries were omitted from new positives. The [merged event-boundary rules](../../Tests/Fixtures/story-corpus/README.md#event-boundary-rules) apply; the reviewer must confirm the counterstrike report's lead rather than treating an entire war or several actions as one occurrence.

Real negative evidence now includes:

- Apple's fiscal 2024 Q3, fiscal 2025 Q2 and fiscal 2025 Q3 releases: Q3 headlines repeat, but fiscal periods and results differ. Dates have day precision only; no midnight or precise release time is inferred. ([FY24 Q3](https://www.apple.com/newsroom/2024/08/apple-reports-third-quarter-results/), [FY25 Q2](https://www.apple.com/newsroom/2025/05/apple-reports-second-quarter-results/), [FY25 Q3](https://www.apple.com/newsroom/2025/07/apple-reports-third-quarter-results/))
- Distinct June/July FOMC statements with identical headlines and explicit 14:00 EDT release times, corresponding to 18:00 UTC. ([June](https://www.federalreserve.gov/newsevents/pressreleases/monetary20250618a.htm), [July](https://www.federalreserve.gov/newsevents/pressreleases/monetary20250730a.htm))
- Different strikes in Kharkiv oblast within two days: October 2 city glide bombs versus October 3 Shestakove car drone strike, with different places, weapons and casualties. The dedicated October 2 report was discovered through a captured roundup's actual link, then fetched independently.
- Identical-headline BBC science episodes, weekly Politico cartoon editions and two tagesschau bulletins within three hours. Multi-story editions are document-only negatives, not single-event assignments.
- Equal €50-million figures attached to different donors/actions, and the bridge strike versus announced pontoon construction.

Financial releases and weekly editions mostly fall outside the clusterer's 36-hour window. They cover real repeated language but cannot prove near-window false-merge rejection. Kharkiv, financing and action/response negatives provide separate operational cases.

Only Irene Butter's death adds a fresh event-positive occurrence to holdout. Most new events hash to tune; related Ukrainian statements/strikes stay with existing families. Holdout diversity remains insufficient. Do not change family names or move documents to manufacture support. The private `supplement-review-v2.md` separates captured feed text from later publisher-page text and keeps `supplement-pairs.csv` approvals blank; these proposals remain one copilot's source review, not independent gold.

## Full-text feeds and observed URL variants

A second October 3 production capture fetched 1630 observations from 51 of 52 requested URLs (catalog plus three publisher-advertised slash endpoints). Across this follow-up's two October 3 snapshots, **tuning only** has 1003 distinct captured observations and 111 fingerprint-eligible inputs (96 en / 14 uk / 1 de), covering 96 distinct eligible document URLs, but **zero different-URL matches**. Precision is undefined. Substantial feed text exists at NASA, KFF, Hackaday, Lifehacker, NOS, Dawn and others; text availability alone does not supply different-URL feed observations.

The [unscored investigation](../../Tests/Fixtures/story-corpus/publisher-url-investigation-v1.json) fetched publisher-advertised alternatives discovered from three article pages at each of ten feed publishers. Nineteen alternatives were observed and sixteen fetched:

- Nine resolve to the original final URL: NOS paths, KFF shortlinks and NASA post-ID shortlinks.
- Three Lifehacker trailing-slash alternatives already normalize to the same URL.
- Three Dawn slugged versus numeric paths remain distinct and have equal normalized production-readability text and page titles: useful canonical-identity review cases.
- One Ars/The Conversation cross-origin republication has different extracted text and is outside the same-host fingerprint contract.
- Three Hackaday `wp.me` probes returned HTTP 301 errors through the protected client; no readable-body equivalence is claimed.

Six same-origin NOS/Dawn path pairs enter the supplementary document-only sheet. These are publisher-advertised URLs with independently retrieved bodies, not generated tracking suffixes. They are not two feed-item observations. Copying a feed item and replacing its link would manufacture support, so none were added to native capture inputs. Canonical and redirect cases already have a production identity path in `ContentExtractionPipeline`; raw-feed fingerprinting and publisher-page alias validation measure different inputs.

#251 has now resolved the earlier gate-scope decision: it bounds false merges over distinct eligible holdout documents, retaining ≥99% precision when at least 100 candidates exist. It requires fresh captures from October 4, rather than treating inspected October 3 data as acceptance evidence. The page probes here do not change that gate, establish recall, or justify removing host, source-name, exact-time or text-kind keys from fingerprints.

A fresh unscored capture with the catalog and merged `fingerprint-feeds.json` is saved privately at `/Users/marspater/Documents/NewsHoldout-2026-10-04/fingerprint-captures/capture-1791070282648.json`: 2915 items from 88 of 89 requested feeds. Capture time was `2026-10-03T23:31:22.648532Z`, which is October 4 in the user's Europe/Warsaw timezone. SHA-256: `e3f832b355ceb3e0ecb46c69d2888bbf06cf70b38c3860ade8a72c6fed99f15d`. Its holdout has not been inspected or scored. This is collection evidence only, ready for the subsequent one-time fingerprint acceptance review.

## Validation

Live protected page/feed capture and offline production-readability extraction completed. Frozen metadata checks, date-parser regressions (publication versus modification, timezone, identity scoping and response integrity) and request-ID/count boundary checks run in `test.sh`. Full regression completion is recorded with the publication commit. No app build, installation, holdout score or hosted-CI pass is claimed by this audit.
