# Publisher-content provenance — 2 October 2026

Fixes #164.

Schema v15 stores locally observed input versions for article titles, feed summaries and extracted bodies. Each version records a local observation time, changed-field mask and SHA-256 hash; the latest twenty metadata rows are retained, without old publisher-body copies. Initial snapshots and first extractions are distinguished from changes to existing publisher text. A local cache purge invalidates analysis but does not fabricate a publisher update.

SQLite triggers invalidate generated article-analysis fields and affected event overviews in the same transaction as the publisher-input change. Structured article analysis carries its input hash and content version alongside the existing model identifier and analysis version. Extraction, classification, article analysis and overview generation reject results if their captured publisher inputs changed. Overview requests rehydrate stored articles, including when a reader holds an older snapshot. Bookmarking registers aliases while preserving newer stored publisher content.

The reader exposes a native disclosure listing locally observed publisher updates, changed fields and observation dates. It explicitly distinguishes updates from verified corrections. Observation time is not a publisher-supplied modification date. A feed-only update preserves an already extracted reader body; a later explicit reload can observe its newer version. No polling service, full historical body archive, correction verification, cloud generation or new dependency is added.

Migration records existing publisher data as a baseline and clears unversioned generated analysis so it can regenerate. Publisher bodies, saved stories, read history and settings survive. This can increase on-device analysis work on the next summary request.

`testPublisherContentProvenance` covers unchanged refreshes, initial extraction, subsequent updates, analysis/overview invalidation, stale-write rejection, read/save preservation, bookmarking older snapshots, bounded metadata, cache purges and a copied v14 library upgrade. Existing migration regressions also exercise earlier schema versions. Validation against `455a2d4`: full `./test.sh` passed and `./build.sh` passed (arm64, ad-hoc signing, isolated staging); the commit hook additionally validates the final cache-invalidation regression. Native reader interaction remains unverified because the desktop automation tool timed out during fixture app selection. No installation or real user data changes.
