# Historical document reconciliation — 1 October 2026

## Scope

Issue #112 extends the fingerprint foundation (#174) and persistent aliases (#108). Mars merged #174/#175 while this implementation was underway; publication is rebased onto current main, including #176. Its overview migration retains v8; historical reconciliation uses v9. No production database, installed app, user-owned checkout or published history was changed.

Open PR links were checked: #175 linked #111; #174 lacked a Development link to #110, which was added and verified through GitHub and the API. Because that link closes the implementation issue on merge, its unmet >=99% precision holdout gate was explicitly retained in open evaluation issue #102. Both PRs were then merged by Mars.

## Implementation

- Schema v9 groups only exact stored document URLs with matching substantial publisher-text fingerprints, including host/source/title/known-time guards. A present body must qualify itself; a shared teaser cannot override changed or short body text. Missing/homepage URLs, changed prose and uncertain histories remain separate.
- Preserve original article, enrichment and state rows. Snapshot pre-reconciliation read/save flags and timestamps, including the survivor's original timestamps; union current flags and latest known timestamps onto the survivor. Union feed associations and retarget observed ID aliases. An explicit original-row query remains available through `includingOriginals`.
- Normal lists, search, counts and reading caches exclude reconciled copies. Existing URL/content ambiguity tombstones are retained. Indexed exact historical URL/text evidence maps matching refresh variants to the survivor without reviving ambiguous URL-only navigation.
- Reconciliation runs in one migration transaction and retains stable survivor primary keys. Cancellation and failed alias updates roll back schema, state, history and identity writes. Stream candidates by exact URL with a 1000-distinct-fingerprint bound per URL; do not compare every archive pair. This is conservative reconciliation, not semantic/event clustering or a measured precision result.
- Saved-family originals survive article-content cache purges. Normal retention removes an expired read/unsaved family together, preventing hidden originals from reappearing when their survivor is removed. A citation to any family member protects the entire family. Retention remains intentional removal under the existing policy, not migration-time data loss.

## Verification

Copied v8 fixtures retain their untouched source file. Regressions cover confident copies versus changed text/short bodies/reprints/homepage links; original/enrichment reachability; state/history/feed preservation; old and observed ID routing; list/search/count/read-cache visibility; exact incoming variants; persistent ambiguity; saved-family cache protection; reopening; whole-family retention; quick_check and foreign keys. Cancelled and injected-failure copies retain schema v8 and original state/aliases. Older v1/v4/v5/v6 fixtures now remove v9 tables when reconstructing those schemas; their coverage remains enabled.

Full regressions, focused story checks, mandatory full-suite hook and isolated native arm64 build/signature checks run before publication. Final validation and hosted status are logged on the PR. No live publisher, GUI or installation verification is claimed.

Logs: `/tmp/news-history-focused.log`, `/tmp/news-history-tests.log`, `/tmp/news-history-build.log`, `/tmp/news-history-commit.log`.

## Limits

Only confident same-URL publisher text copies reconcile. Different URLs and insufficient or conflicting text remain separate; holdout evaluation remains #102. Original rows retain storage until normal retention removes their family. This preserves the histories the current schema records (one read and save timestamp per original), without inventing missing interaction events. Phase B is not declared complete from this slice.
