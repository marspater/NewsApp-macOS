# Editorial evaluation protocols (W5, W6, W7) — draft, 13 November 2026

Status: **draft for review. Not frozen.** The numeric gates in section 6 are proposed values; the protocol freezes only when I have agreed them and recorded that on #714. No label is collected and no acceptance run is made under this document before then.

This covers the acceptance evaluation of Angelia's three editorial experiments that are merged without a production caller: passage novelty (#997, W5), event momentum (#998, W6) and diversity-aware selection (#999, W7). Personalization (#1001, W9) is out of scope: it needs real use, an opt-in surface and a privacy text first.

## 1. Two kinds of run, never mixed

| | Harness smoke test | Acceptance evaluation |
|---|---|---|
| Purpose | The code routes, counts and scores as designed | The feature is good enough on real news to wire |
| Data | Authored and synthetic fixtures in the repository (`Tests/Fixtures/editorial/`, the Phase 0 corpus of `script/evaluation/build_corpus.py`) | Real-news sets under `~/news-eval/`, labelled as below |
| Runs in | `./test.sh`, CI, the `script/test_editorial_*.sh` commands | By hand, on my Mac, one measurement at a time |
| Result | Pass or fail of the checks | Measures in the run ledger, verdict against section 6 |
| Can it accept a feature? | No | Yes, and only this |

A smoke-test number is never quoted as accuracy. The audits of 5 and 6 November (`2026-11-05-editorial-evaluation.md`, `2026-11-06-editorial-novelty.md`, `-momentum.md`, `-ranking.md`) are smoke evidence. An acceptance run names its dataset in the ledger; a smoke run is logged, when logged at all, with a `dataset` that starts with `fixture-`.

## 2. Rules shared by the three evaluations

- **Source of real news.** Dated read-only snapshots of the development library (`com.marspater.news.dev`), taken as `script/today_lead.sh snapshot` takes them. The installed app's library is read only when I pass `--real-library` myself.
- **Unit of the split.** The event, together with every syndicated copy of its reports. No event and no wire copy group appears on both sides of a split.
- **Tune and holdout.** Each set is split once, by event, into tune and holdout, in time order: the holdout's events all start after the tune's last event. Parameters are chosen on tune only, by a selection rule written down before the tune run. The holdout is sealed: it is run once per frozen parameter set, its rows are not read, and only its aggregate measures leave `~/news-eval/`.
- **Labels.** A first pass and an independent second pass label every item without seeing the system's output or each other's labels. Disagreements go to a third read; an item no two reads agree on is dropped from scoring and counted. Agreement is reported as Cohen's kappa. A first pass may be drafted by a model; the label then keeps that provenance, and the second pass is mine or another person's. No set is called human gold unless a person made both passes.
- **Leakage.** Labels are used for scoring and for tune selection only, never by retrieval, embedding or candidate selection. A run that defers or refuses an item counts it as such, not as a negative.
- **Clock.** Every replay pins its clock and uses only reports available at that clock (fetch time), with publication time as the activity time.
- **Ledger.** One line per completed run, with `dataset`, `commit`, verdict and the measures of section 7. No article text, no headline, no reading from a sealed holdout.

## 3. W5 · passage novelty (#997)

**Question.** When a new report joins an event, does the selected sentence state something the event's earlier reports did not?

**Item.** One (event, new report) pair at a pinned clock, with the event's earlier reports as the baseline.

**Label classes.** Each item gets one:

| Label | Meaning |
|---|---|
| `new-fact` | The report states at least one checkable fact absent from every earlier report of the event. The labeller marks the sentence or sentences that carry it |
| `repetition` | Everything checkable in the report is already in an earlier report, reworded or not |
| `new-framing` | No new fact; new quotation, reaction, analysis or context |
| `off-event` | The report does not belong to the event (a clustering error) |
| `unsure` | The labeller cannot decide; excluded from scoring and counted |

`new-framing` is scored as not novel. `off-event` items are excluded from precision and reported as their own count, so clustering errors (#737) are not charged to novelty.

**Arms.** One system arm (the `EditorialNovelty` route and its selected sentence) against the labels. Two reference arms on the same items: "always novel" (every report's first entity-anchored sentence) and lexical-only (the FTS5 gate without the semantic step).

**Metrics.** Net-new precision (selected sentences that lie inside a marked `new-fact` span, over all selected sentences); false-novelty rate (items labelled `repetition` or `new-framing` that surface a sentence, over all such items); recall on `new-fact` items; route counts (repetition, novel, no anchored sentence, low-priority fallback, deferred); route mismatches by class. Hardware measures (vector-cache hit rate, first and later batch time, energy) are a separate run on an idle Mac in Release and do not enter the quality verdict.

**Decision rule.** Accept for wiring when, on the holdout, precision, the false-novelty rate and the usefulness gate (recall and surfaced sentences, so that abstaining almost everywhere cannot pass) all meet section 6 and the system arm beats both reference arms on precision. Otherwise the issue stays open, or I retain it as an experiment and say so on #997.

## 4. W6 · event momentum (#998)

**Question.** Does the acceleration signal mark the windows in which independent reporting of an event really surged, and stay silent otherwise?

**Item.** One (event, window) pair. Windows are bucket-aligned, of one fixed length (section 6), and non-overlapping within an event.

**Window definitions.**

| Label | Meaning |
|---|---|
| `burst` | Within the window, independent reporting of the event rises clearly above its own preceding level because something happened: a new development that several independent origins report |
| `quiet` | No such rise. This includes steady coverage, a slow weekend, and one wire report republished by many outlets |
| `syndication-only` | A rise in rows that comes from copies of one or two origins; scored as `quiet`, reported as its own count |
| `unsure` | Excluded from scoring and counted |

The labeller sees the event's reports in publication order with publisher and origin, not the MACD series.

**Named authors.** Whether a report with a named staff author counts as the publisher's own origin (wire identity audit, #1057) is a policy input to the independent-origin count. Section 6 records it; both settings are not tried on the holdout.

**Arms.** The `EditorialMomentum` acceleration flag, against two references: a raw report-count threshold in the same window, and a distinct-origin count threshold. Each arm's threshold is chosen on tune by the same selection rule.

**Metrics.** Burst precision and recall, false-positive rate on `quiet` windows (with `syndication-only` shown separately), share of rows with unknown origin, and replay time per event. Production insert and update latency is measured only after acceptance, when a storage path exists.

**Decision rule.** Accept when the false-positive rate and the recall on the holdout meet section 6 and the flag is not worse than either reference on false positives at equal or better recall.

## 5. W7 · diversity-aware selection for The Lead (#999)

**Question.** Does temporal MMR improve the editorial variety of The Lead while preserving the relevance of the existing Lead ranking?

This first evaluation tests MMR on a ranking that already means something. A new relevance formula, including Kairos · measured momentum's MACD signal, is a separate comparison after W6 is accepted: on the 12 November snapshot only 7 of 183 candidates carried positive momentum, so a momentum base would mostly have measured a tie-break. Moving the target to the Briefing board would also be a different question and is not part of this protocol.

**Snapshot.** A dated Lead snapshot under `~/news-eval/today-lead-snapshots/<day>/`, with the clock at its newest story and the pool the app assigns from (`NEWS_TODAY_POOL=page`). The arms rank the same candidate pool, with the same sentence vectors and the same event membership.

**Arms.**

| Arm | Definition |
|---|---|
| `current` | The shipped Lead selection as shown, including its actual eligibility, tie-breaks and display rules (slide cap, photo rule) |
| `base` | Athena · attention's existing Z2 editorial score (reporting breadth, assessed importance, semantic salience and its bounded activity contribution), with publisher affinity and preferences neutral and no diversity penalty |
| `base+mmr` | Exactly the same scores and eligible candidates as `base`, with `EditorialRanking`'s temporal MMR applied, at the parameters frozen on tune |

The same display constraints apply to both experimental arms. Z2's activity component stays as it is. A report of unknown origin stays unknown; no origin is assumed.

`current` and `base` need not differ. Each run reports their overlap at the display depth and their rank correlation over the pool. Where they coincide, that is a control: `base+mmr` against `base` isolates MMR. What cannot then be claimed is an improvement from changing base relevance.

**Judgement.** The blind sheet of `script/evaluation/lead_review.py`: every story in the top 20 of at least one arm, shuffled, with headline, summary and publisher and no arm, place or score; `lead` or `not` per reader. For redundancy, each reader also marks, per day and per arm's shown list presented without its arm name, every slot that repeats a story already covered by an earlier slot of that list. Two independent human readers, on at least the number of holdout days in section 6.

**Metrics.** Precision at 5, 10 and 20 per arm, per reader and day and pooled; NDCG@10 with `lead` as grade 1; intra-list diversity at the display depth (one minus mean pairwise cosine similarity of the shown stories' vectors); reader-labelled redundant slots per arm; distinct events and publishers shown; overlap between arms; kappa between readers; selection time over the pool. Differences are reported with 95% intervals over days.

**Decision rule.** `base+mmr` passes when all of these hold on the holdout days:

- the lower 95% confidence bound of its precision minus `current`'s, at the display depth, is above the non-inferiority margin of section 6;
- its mean intra-list diversity exceeds `current`'s by the margin of section 6, and it also shows a gain over `base`;
- reader-labelled redundant slots fall by the relative share of section 6 against `current`. If `current` shows no redundancy, that improvement claim is unavailable and is reported as such.

Insufficient evidence is inconclusive, not passed. A pass recommends a Lead trial to Epic Z (#932); it changes no shipped default by itself, and Z's validation stage decides when a trial can run.

The harness that produces the arms lives in the evaluation tests and scripts only; nothing under `Sources/` changes for it.

## 6. Numeric gates — proposed 13 November 2026, not yet agreed

These are acceptance targets for my approval, not accuracy established by the smoke tests. The protocol freezes when I record my agreement on #714.

The priorities are deliberate: Kairos · novelty detection should rarely call repetition new; Kairos · measured momentum may miss some bursts to avoid false urgency; Athena · attention should buy variety with very little lost relevance.

| Gate | Proposed value |
|---|---|
| W5 minimum holdout | 400 scored reports, including 150 `new-fact` and 200 `repetition` or `new-framing`, across 80 events |
| W5 net-new precision | at least 95% |
| W5 false-novelty rate | at most 3% |
| W5 usefulness | recall at least 50%, with at least 100 surfaced sentences; deferred eligible items stay in the recall denominator |
| W6 window and holdout | 1-hour windows; 100 `burst` and 300 `quiet`, including 100 `syndication-only`, across 80 events |
| W6 false-positive rate | at most 5% on `quiet` overall, and separately on `syndication-only` |
| W6 burst recall | at least 70% |
| W6 named author establishes an independent publisher origin | No: a name alone is insufficient (#1057: 8 of 93 named-author event members were in cross-outlet verbatim-copy groups) |
| W7 display depth | 5 stories |
| W7 holdout | at least 30 days, two independent human readers |
| W7 precision non-inferiority margin | 3 percentage points below `current`, absolute: the lower 95% bound of `base+mmr − current` above −0.03 |
| W7 diversity gain | mean intra-list diversity at least 0.05 higher, absolute, than `current`; also a gain over `base` |
| W7 redundancy | at least 20% relative reduction in reader-labelled redundant slots against `current` |
| Minimum reader agreement | Cohen's kappa at least 0.60, calculated before adjudication |
| Unsure and unresolved exclusions | at most 10% per evaluation; above that, the rubric is revised before acceptance |
| Uncertainty | 95% intervals on every gated measure, accounting for repeated items within events; a gate is met only when the interval supports it, otherwise the result is inconclusive |

## 7. Measure names

Added to `docs/TOOLING.md` with this document: `novelty_*`, `burst_*` and `lead_arm_*`. The existing `lead_precision_at_5*` names keep their meaning (the Z2 shadow run's three rankings) and are not reused for W7's arms.
