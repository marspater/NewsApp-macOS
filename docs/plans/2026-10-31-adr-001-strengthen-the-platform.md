# ADR-001: Strengthen the platform before expanding it

**Status:** Proposed
**Date:** 31 October 2026
**Deciders:** Mars Pater

## Context

As of 31 October, v2 is merged on main `e18620d`. That includes the 30–31 October pass over #778–#799 and #816–#819, CI on main is green, and #835 (Briefing) is the only open PR. The app runs on:

- Swift 6, SwiftUI and AppKit.
- One SQLite library (WAL, FTS5, hand-written migrations, now schema v28).
- On-device intelligence: NaturalLanguage, Core ML, Foundation Models, vDSP.
- Two third-party packages: FeedKit and SwiftSoup.

The open v2 defects are not missing features. They are broken promises in what already exists:

- **Trust boundaries:** #808 (redirect safety keyed by a task number that sessions share), #793 (prompt delimiter sanitising), #810 (update checks contradict the documented network egress).
- **Background work that outlives its reason:** #805 (Clear AI Analysis does not stop running work, so cleared data comes back), #792 (overview warm-up and the reader cancel each other), #786 (refresh overwrites newer read or save state), #814 (bookkeeping outside transactions), #811 (the cache-clearing commands disagree), #812 (Spotlight survives a restore), #820 (cleared categories are not reclassified this session).
- **Verification gaps:** #804 (tests exercise local copies), #840 (the native UI QA script does not compile), #801 (Briefing E2E is not in CI), #839 (list refresh costs left after #828).

The post-v2 roadmap (Epics U, V, W, X; `docs/plans/2026-10-28-next-features-roadmap.md`) adds search, annotations, dossiers, a map and widgets, and every one of them writes derived data in the background. Each new feature that inherits the #805/#792 pattern adds another place where stale results can overwrite current ones.

## Decision

1. **No new storage engine, remote AI service or substantial dependency for v2 or the U/V/W horizons.** SQLite stays the store, and on-device frameworks stay the intelligence. A new dependency needs its own ADR with a measured reason (for example, a vector index only if an exact vDSP scan measurably misses its latency budget for U2).
2. **One write-validity contract for background intelligence work.** Every background result is saved only if the inputs it was computed from are still current: a stamp captured when the work starts and checked inside the write transaction. This generalises what already works in three places:
   - `expectedInputHash` on enrichment saves;
   - `membership_version` on overviews (#789);
   - `inputHash` on World Tension readings.
   Clearing commands (#805, #811) bump a per-kind generation, so in-flight work is refused at commit instead of having to be cancelled perfectly.
3. **Phase 0 before new horizons.** Fix the trust-boundary and lifecycle issues above. Finish or drop #835 against the agreed design (widget row under the carousel; it is a draft built from a drifted mock). Then add a release acceptance gate. U1 Quick Look stays allowed early, as the roadmap already says.

## Options Considered

### Option A: Keep cooperative cancellation, fix each site

| Dimension | Assessment |
|---|---|
| Complexity | Low per fix, rising with every new feature |
| Cost | Smallest diffs now |
| Scalability | Each new writer must remember every cancel path |
| Team familiarity | High: the current pattern |

**Pros:** no new concept, and each fix ships alone.
**Cons:** #805 and #792 exist because cancellation is cooperative and a finished computation still writes. Every U/V/W writer repeats the risk.

### Option B: Input stamps checked at commit (recommended)

| Dimension | Assessment |
|---|---|
| Complexity | Low to medium: one helper plus a column or key per kind; reuses the existing hash and version guards |
| Cost | A few days across enrichment, overviews, notifications, embeddings and features |
| Scalability | New writers adopt one rule; a correct write is the default |
| Team familiarity | High: three subsystems already do it |

**Pros:**
- A stale write is refused even when cancellation loses a race.
- Clearing becomes a generation bump plus a delete.
- It gives #792 a shared input identity, so warm-up and reader agree which report set is current.

**Cons:**
- Every derived table needs its stamp.
- Refused writes waste the compute that produced them.
- Tests must cover the race.

### Option C: Persistent job table with a scheduler actor

| Dimension | Assessment |
|---|---|
| Complexity | High: a new subsystem with a schema, retries and a recovery path |
| Cost | Weeks, and it touches every coordinator |
| Scalability | Best observability and retry control |
| Team familiarity | Low |

**Pros:** queue depth, failures and retries are visible, and work survives a relaunch.
**Cons:** it does not by itself stop stale writes (it still needs Option B's check), and it is a large refactor during stabilisation.

## Trade-off Analysis

Option B fixes the root cause shared by #805, #792 and #820 at the commit point, which is the one place every writer passes through. Option A treats symptoms, and Option C adds machinery that still needs B underneath. B's cost is a stamp per derived kind, and most kinds already carry a hash or version. Retry and observability (Option C's real benefit) can come later as a local diagnostics view, without a job table.

## Consequences

- **Easier:**
  - Clear and Reset commands become trustworthy.
  - New U/V/W writers get correctness by following one rule.
  - Tests can assert "stale input, no write" directly.
- **Harder:**
  - Each derived table migration must include its stamp.
  - A long computation may be discarded after finishing.
- **To revisit:**
  - A job table, if retries or relaunch survival become requirements.
  - GRDB, only if the hand-written SQLite layer becomes the bottleneck, as its own ADR.
  - A vector index, only after U2 measures exact-scan latency on a real library.

## Action Items

1. [ ] Trust boundaries:
   - #808: key redirect state per task object, not by `taskIdentifier` (`SecureHTTPClient` keys `states[task.taskIdentifier]`).
   - #793: pass untrusted text as structured input, not by escaping delimiters in strings.
   - #810: align update checks with the documented egress.
2. [ ] Add the write-validity helper. Adopt it in enrichment (#805, #820), overviews (#792) and notification bookkeeping (#814, inside one transaction). Make Clear All Caches and Clear AI Analysis share one list of derived tables (#811).
3. [ ] #786 and #787 with #785 (one PR, as noted on #785). #812: rebuild the Spotlight index after a restore.
4. [ ] Verification: #804, #840, #801. Re-measure #839 against the #828 baseline harness.
5. [ ] #835: rework to the agreed widget-row design, or close it and restart from #780.
6. [ ] Release acceptance gate, written down and run before tagging:
   - migration and restore on a library copy;
   - parser and network security tests;
   - the matcher holdout with no precision regression;
   - notification deduplication;
   - Reader and Briefing E2E;
   - accessibility and visual captures;
   - performance budgets;
   - privacy manifest and docs consistency.
7. [ ] Docs truth (#569):
   - README still says EventMatcher v11 and World Tension v2;
   - `docs/ARCHITECTURE.md` says matcher v15 but still has a stale "matcher v12" at line 284;
   - the 28 October roadmap still uses the J–T v2 boundary and says V1 annotations take schema v28, which now means v29.
8. [ ] Matcher (#737): keep the current admission rules until a fresh holdout shows a recall gain within the ≤ 2% wrong-group ceiling. Do not trade precision for the 60% multi-source target.
