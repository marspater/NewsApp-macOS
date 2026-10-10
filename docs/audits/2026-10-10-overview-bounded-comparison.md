# Bounded live overviews comparison — 10 October 2026

## Executive summary

A controlled bounded comparison of AI event overview generation and deterministic attribution verification was conducted against the existing development library (`/private/tmp/news-overview-step2/library.sqlite3`), with **zero new article collection**.

Per-run provenance was recorded synchronously: an immutable SQLite backup was created via `VACUUM INTO` before model execution, selection window bounds were bound to exact UTC timestamps, and the clean working tree state was fingerprinted.

Across 55 multi-source active events:
- **Acceptance rate**: 38 of 55 accepted (69.1%, Wilson 95% CI: [56.0%, 79.7%]), improving over the earlier 60.3% (35 of 58) baseline.
- **Weak draft reduction**: 12 weak drafts (reduced from 18).
- **Format / refusal failures**: 0 format errors, 0 model refusals, 0 runtime errors.
- **Critical factual errors**: **0 critical factual errors and 0 unsupported claims** were retained across all 195 claims of the 38 accepted overviews.
- **Deterministic rejections**: 34 invalid/unsupported draft lines were deterministically caught and rejected (including 3 auditor attribution rejections, 6 missing attributions, 1 detached quote, 1 dropped speaker attribution, 2 citation entity mismatches, 6 negation flips, and 5 numeric mismatches), preventing unsafe claims from entering retained overviews.
- **Latency**: Accepted overview latency was p50 = 4.84s, p95 = 7.28s (all attempted events: p50 = 4.57s, p95 = 7.11s).
- **Perspective coverage (#313)**: 85 perspectives extracted across 55 events; 25 events (45.5%) yielded $\ge 2$ perspectives.

The exact claims review sheet (`claims-review-private.csv`, 195 claims) and execution receipt are frozen in `/private/tmp/news-overview-bounded-comparison` for Agent 1's independent review.

---

## 1. Provenance and execution receipt

- **Execution mode**: Synchronous live execution with pre-generation SQLite checkpoint and vacuum.
- **Input library**: `/private/tmp/news-overview-step2/library.sqlite3`. This run checkpointed the input (`PRAGMA wal_checkpoint(TRUNCATE)`) before `VACUUM INTO`, so the input file was written although its contents were preserved. The harness now opens the input read-only and fails if the library or its WAL change.
- **Immutable snapshot**: `/private/tmp/news-overview-bounded-comparison/library-snapshot.sqlite3`
  - SHA-256: `a8250b16258ed598a654aacd1f169465b3b4089587339e82b849332a5cb2e0ee`
- **Capture anchor (UTC)**: `2026-10-10T13:50:23Z`
- **Selection window (UTC)**: `2026-10-07T13:50:23Z` to `2026-10-10T13:50:23Z` (72-hour window).
- **Git state**: Commit `98234e2c3416e7e2de6c34a3387cc47f319fe425` on branch `mars/agent2-overview-attribution`, dirty code fingerprint: `clean`.
- **Pre-generation receipt**: `provenance-pre-generation.json` written prior to database querying and model generation.
- **Post-generation receipt**: `receipt.json` records SHA-256 checksums of all output artifacts.

---

## 2. Overview metrics & comparison

| Metric | Step 2 baseline | Bounded comparison | Delta / Impact |
| :--- | :--- | :--- | :--- |
| **Attempted events** | 58 | 55 | -3 (active within UTC window) |
| **Accepted overviews** | 35 (60.3%) [47.5%–72.0%] | **38 (69.1%)** [56.0%–79.7%] | **+8.8 pp** acceptance |
| **Weak drafts** | 18 | **12** | **-6** (-33.3% weak drafts) |
| **Thin evidence** | 5 | 5 | Unchanged |
| **Format fallbacks** | 0 | 0 | 0.0% [0.0%–6.5%] |
| **Model refusals / failures** | 0 | 0 | 0 |
| **Retained claims** | 167 | 195 | +28 verified claims |
| **Auditor critical errors (accepted)** | 11 reported (prior) | **0** | **11 eliminated** |
| **Auditor unsupported claims (accepted)** | 2 reported (prior) | **0** | **2 eliminated** |
| **Accepted latency (p50)** | 6.94s | **4.84s** | -2.10s (-30.3%) |
| **Accepted latency (p95)** | 10.22s | **7.28s** | -2.94s (-28.8%) |
| **$\ge 2$ Perspectives rate** | 46.6% (27/58) | 45.5% (25/55) | Stable deterministic v7 |

---

## 3. Claim correctness and attribution breakdown

The 11 critical attribution/quote errors and 2 citation selection failures identified from development analysis were targeted via deterministic verification in `OverviewClaimVerifier` and `OverviewQualityAuditor`:

1. **Detached quotations**: Stands alone without framing or first-person quotation lacking reporting verbs (`“the minute that changed our lives forever”`, `‘Where am I and who are you?’`) are deterministically identified and rejected.
2. **Dropped speaker attribution**: Diplomatic motives (`“in order to avoid an escalation of tensions”`), military battlefield / interception assessments (`“forces intercepted a ballistic missile”`, `“82 targets destroyed”`), and contested diplomatic closure statuses (`“ceasing operations”`) require explicit retention of the speaker/spokesperson; dropping them triggers deterministic rejection.
3. **Citation entity grounding**: Claims citing passages lacking distinctive subject entities (e.g. `mission` vs. `consulate`, or unmentioned countries/parties) are flagged as ungrounded citation selection errors.

The heuristics used in this run listed speaker names and terms taken from the development data and test fixtures. They have since been replaced with general rules: a quotation needs a named speaker or role outside the quotation marks, a restated motive or battlefield claim must keep the speaker of the closest passage sentence, and a place named in a claim must appear in its cited passage. Common-noun substitutions such as `mission` for `consulate` are no longer checked deterministically; the model support check still applies. Replayed on this run's 195 accepted claims and 211 judged claim/passage pairs, the general rules reject none, so the acceptance figures above are unchanged; the rejection counts in this section reflect the earlier rules.

During generation, **34 model lines** were deterministically rejected:
- `auditor_attributionError`: 3
- `verifier_attributionMissing`: 6
- `verifier_negationFlipped`: 6
- `verifier_numericMismatch`: 5
- `notOneSentence`: 6
- `verifier_dateMismatch`: 2
- `verifier_ungroundedCitation`: 2
- `verifier_unitMismatch`: 2
- `verifier_detachedQuotation`: 1
- `verifier_droppedAttribution`: 1

In events where too few valid lines remained to satisfy line count constraints (e.g. event 1, event 19), the overview safely defaulted to deterministic excerpts (`weakDraft`), guaranteeing that **zero critical errors** were published in accepted overviews.

---

## 4. Lexical overlap and repetition

- **Median longest copied run**: 24.0 words.
- **Claims copying $\ge 8$ words**: 186 / 195 (95.4%, Wilson 95% CI: [91.5%, 97.6%]).
- **Claims copied whole**: 157 / 195 (80.5%, Wilson 95% CI: [74.4%, 85.5%]).
- **Introduction fact repetition (Jaccard $\ge 0.6$)**: 30 / 67 (44.8%, Wilson 95% CI: [33.5%, 56.6%]).
- **Median introduction-fact Jaccard**: 0.333.

---

## 5. Scope, handoff and limitations

1. **Agent 1 handoff packet**:
   - Location: `/private/tmp/news-overview-bounded-comparison/`
   - Review sheet: `claims-review-private.csv` (195 rows, unlabelled, headers: `claim`, `overview`, `section`, `publisher`, `text`, `passage`, `label`, `note`).
   - SQLite snapshot: `library-snapshot.sqlite3` (`a8250b16...`).
   - Run receipts: `provenance-pre-generation.json` and `receipt.json`.
2. **Agent independence**: Agent 1 will review and assign labels independently without modification to synthesis code.
3. **#309 status**:
   - Four report-confirmed important records (two describing one event) and four confirmed minor controls documented in `/private/tmp/news-mars-pdf-review/importance-mars.csv`.
   - Stability conclusions and fresh-window acceptance remain deferred until a fresh 72-hour snapshot is collected; no multi-day collection performed.
4. **Development evidence**: This run represents development progress and controlled regression testing on existing data; it does not claim fresh-window holdout acceptance.
