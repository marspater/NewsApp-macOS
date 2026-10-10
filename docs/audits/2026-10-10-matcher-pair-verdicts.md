# Matcher pair verdicts — 10 October 2026

Refs #307. This closes a reproduced admission-path gap; it is not release precision acceptance.

## Cause and correction

New-event formation resolved the seed against each candidate, then compared candidate partners with raw deterministic `isCompatible` assessments. It never asked the judge about an open partner pair. A SAME star could therefore create one event without settling the edge between its partners. Existing-event admission also began from raw assessments, and later calls could forget a settled DIFFERENT once the pass's judge budget ran out.

The clusterer now resolves candidate partners through its existing pair resolver. Settled assessments are retained by unordered article-ID pair for one pass and consulted during existing-event admission, pair confirmation and fragment merging. A cached verdict costs no further judgment and remains authoritative after budget exhaustion. Nil/unavailable judgments keep the deterministic fallback. The cache holds at most the pass's settled pair budget (normally 150); whole-coverage judgments still share that same budget. The new partner loop checks cancellation before each potentially suspended comparison.

Matcher version is 4. Thresholds, judge instructions, 150-judgment/2,000-article budgets, exclusion handling and event size limits are unchanged. No schema migration, install or production data edit is needed. Existing unchanged event members retain their memberships after the version bump; this does not automatically repair historical groups.

## Reproduction and checks

A deterministic integration regression uses three existing synthetic reports and forces confirmation through the injected policy. The controlled judge calls the seed SAME with both partners and calls the partner edge DIFFERENT. It has exactly three judgments available. Before the fix, the regression failed: only two pairs were settled, so the partner edge was omitted. After the fix, all three pairs are settled once; the rejected partner cannot share the new event or rejoin after the budget runs out. The companion control returns SAME for all three pairs and retains one event.

- `./test.sh --story-regressions`: original-code reproduction failed as expected; corrected code passed.
- Full `./test.sh`: passed after the correction, including deterministic matcher/fragment, budget, exclusion, cancellation, persistence and corpus-adapter checks.
- Isolated optimized arm64 `./build.sh`: passed, with strict ad-hoc signature verification and valid bundle metadata. No app launch or installation is claimed.
- Development-only judge-off replay of the existing fresh diagnostic: passed, 88 reports; 215 TP / 54 FP / 423 FN. Precision 0.799 (Wilson 95% 0.747–0.843), recall 0.337 (0.301–0.375), one impure event. These counts equal the earlier judge-off diagnostic: deterministic fallback behavior is preserved, and its false merges remain. No live judge-on accuracy measurement is claimed; judge-on behavior above uses controlled verdicts.
- The replay output-directory prerequisites were corrected before scoring; those setup failures produced no predictions. Inputs and original receipts were preserved.

## Evidence limits and remaining work

The earlier 88-report diagnostic is a targeted sample with proposed copilot labels, not accepted independent gold. Its judge-on run exceeded production budgets. The existing false-pair packet includes distinct acts sharing contextual wording, along with agreement/license and multi-strike/outage boundaries still needing Mars. No current sample false merge is attributed to this particular bypass without a recorded pair-decision trace.

The existing fresh diagnostic may be reused as development data only. Its original inputs, labels and receipts remain unchanged; a private copy changes only split metadata to `tune`. No new or scheduled collection and no sealed historical holdout read/replay are performed. Pairwise intervals do not imply independent event-level generalization. A separate adequate frozen acceptance set, correct production budgets and Mars's acceptance are still needed for the >=0.97 gate.

Independent #308/#309 review remains a separate Agent 1 responsibility once Agent 2 hands over frozen review inputs. This slice makes no synthesis/rating changes and supplies no self-reviewed claim-accuracy acceptance.
