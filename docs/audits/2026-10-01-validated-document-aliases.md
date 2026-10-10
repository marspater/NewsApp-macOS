# Validated canonical and redirect aliases — 1 October 2026

## Scope

Issue #111 builds on merged GUID/URL aliases (#108/#109). Started a focused branch from current main `2c57782`; the separate fingerprint PR #174 remains with Mars to merge. No history rewrite of a published branch, installation or production data changes.

## Implementation

- Extraction uses the protected client's final response URL, validates its destination again and rejects HTTPS downgrades even when initial HTTP is allowed. Relative reader media resolve against this final URL.
- Readable fetched document URLs become typed identity evidence. Evidence construction is private to the extraction file; parsed HTML and offline DOM extraction do not produce validated identities.
- A page's canonical declaration is only a candidate. At most one canonical in the page head is considered; it must be a credential-free document URL on the exact final origin. The protected client fetches it with existing destination, redirect, byte and timeout limits. Substantial bounded extracted prose and a nonempty page title must match after Unicode/whitespace normalization. Cross-origin, homepage, conflicting, failed or changed candidates are ignored.
- The reader passes evidence to ArticleStore. SQLite binds it to the already observed requested URL of the existing stored article, then records aliases in one transaction. Existing conflicting rows become persistently ambiguous; there is no stored-row merge or primary-key rewrite. Alias failure rolls back the entire evidence batch. Content persistence remains separate; optional alias failure is reported and does not leave content caches stale.
- Cancellation prevents identity evidence from escaping extraction or being partially committed. Canonical verification is on demand, not a feed-ingestion fetch. A failed optional probe retains readable source content.

## Verification

- Full `./test.sh` and focused story regressions passed. The mandatory commit hook also runs the full suite before publication.
- Tests exercise protected URLSession ingestion with deterministic mock HTTP responses, DOM extraction, actual ArticleStore persistence and subsequent URL/GUID variant ingestion. Public destination DNS validation remains active; there are no live publisher requests in these fixtures.
- Cases cover relative canonicals/images after a final response URL change, one-probe bounds, unsafe/private/file/credential URLs, cross-origin declarations, homepages, mismatched titles/bodies, failed responses, multiple declarations, blocked final destinations, HTTPS downgrades and cancellation.
- Persistence cases cover stable IDs/read/save state, evidence bound to the correct requested article, conflicting historical rows, persistent ambiguity, reopening and injected second-alias failure rolling back the earlier write.
- Isolated arm64 `./build.sh`, Info.plist lint, strict deep signature verification, architecture inspection and diff checks passed. No GUI, installation, real database migration or live publisher verification is claimed. Hosted results remain on the PR.

Logs: `/tmp/news-canonical-focused.log`, `/tmp/news-canonical-tests.log`, `/tmp/news-canonical-build.log`, `/tmp/news-canonical-commit.log`.

## Limits

Only the fetched final destination is recorded, not every intermediate redirect hop. Exact-origin and matching title/prose rules intentionally reject uncertain canonical mappings; no cross-origin canonical or canonical chain is followed as identity evidence. One optional probe may add protected-client timeout latency to opening an article. Existing conflicting rows are retained for #112; holdout evaluation remains #102 and Phase B is not complete. Mars handles GitHub merging.
