# Publisher-content provenance — 4 October 2026

Fixes #164. Selective re-integration of #217 (`9d5f74f`), which merged into the `codex/finite-briefing` stack rather than main.

## Changes against current main

- Schema v16 (main already uses v15 for durable FTS keys) stores locally observed input versions for article titles, feed summaries and extracted bodies in `publisher_content_revisions`: observation time, changed-field mask and SHA-256 input hash. The latest twenty metadata rows per article are kept; old bodies are not copied. Initial snapshots and first extractions are distinguished from changes to existing publisher text, and a local cache purge invalidates analysis without recording a publisher update.
- SQLite triggers invalidate generated article-analysis fields and affected event overviews in the same transaction as the input change. Structured analysis records its input hash and content version beside the model identifier and analysis version; unversioned legacy analysis regenerates on the next request. Publisher bodies, saved stories, read history and settings survive the migration.
- Extraction, classification, article analysis and overview writes carry captured input hashes; storage rejects them when stored input has changed. Bookmarking an older snapshot registers identity without reverting stored publisher content.
- The reader discloses locally observed publisher updates, changed fields and observation times, and says explicitly that an update is not a verified correction. Observation time is not a publisher-supplied modification date.

Differences from #217:

- The coordinator keeps main's superseded-input checks and also requires matching article inputs before a request joins a running generation. It no longer rehydrates articles inside the actor (its only caller already passes stored members), so request ordering stays synchronous. A storage rejection now returns no overview instead of the rejected one.
- The reader starts from the stored article when a list or briefing snapshot is older, so guarded writes are not rejected for a stale snapshot. The overview is requested again when the active article's input changes (for example after first extraction) and returns by itself if the reader was showing an overview.
- Disclosure content is leading-aligned.
- `testOverviewGenerationCancellationAndSupersession` now stores its article edit, as a real edit is, before the superseding request.

## Validation

- `./test.sh`: passed, including `testPublisherContentProvenance` (unchanged refreshes, extraction versus update, analysis/overview invalidation, stale-write rejection for analysis, classification and overviews, read/save preservation, snapshot bookmarking, bounded history, cache purge, frozen overview snapshots rejected and current inputs regenerated, cancelled and completed v15 to v16 upgrade of a copied library with `quick_check` and `foreign_key_check`) and every earlier migration regression at the new schema version.
- `./build.sh` in an isolated staging copy: arm64, ad-hoc signed.
- Isolated native reader check: an uncommitted harness compiled the production `ArticleDetailView` through `script/native_performance_baseline.sh` with temporary SQLite and defaults. It stored an article, recorded a body update through `ArticleStore.updateEnrichment` (revisions v1 `snapshot`, v2 `publisher_update`, fields 4) and opened the reader from the older list snapshot. The reader showed the updated body and a collapsed "Publisher updated · date" disclosure. A synthesized click on the disclosure expanded it to "Changes observed on this Mac. An update is not a verified correction." and "Version 2 · Article body · date". No network, installed app or real library was used. VoiceOver was not exercised.
