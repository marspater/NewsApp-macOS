# Evidence head and where recall is lost (#737, 9 November 2026)

Follows [the semantic veto audit](2026-11-06-recall-semantic-veto.md) and the 6 November route on #737. **The candidate fails; no default changes and no matcher code is proposed.** This change adds only the `--pair-signals` export. The measured candidate is recorded on branch `mars/737-evidence-head` (0406cb5).

Main at 64ae7a4, matcher v15. Receipts are private under `~/news-eval/clustering-737-2026-11-09/`; this file carries counts only. Labels are single-pass agent labels, unreviewed by Mars.

## Sets

| Set | Source | Pairs | Role |
| --- | --- | --- | --- |
| Development | 3 November holdout, SHA-256 `40708d89…`, pin 1793642173 | 218 (38 same / 43 related / 137 different) | CONTRIBUTING's four conditions; one read of the candidate |
| Stage 1 | 6 November library, drawn without matcher output | 396 usable (108 same / 106 later / 182 topic or unrelated); 285 inside the replay windows at pins 1793915517 and 1793664000 | fit; replay is in-sample for the head |
| Validation | 29 October library, drawn 9 November by the Stage 1 recipe, the retired holdout's 335 articles excluded; candidates SHA-256 `ea20e665…cf93`, labels `1a5e1113…bb63` | 299 (54 same / 111 later / 134 topic or unrelated; one pair dropped for sharing an article with Stage 1); 268 inside the replay window at pin 1793300435 | out of time; never fitted on |
| Single reports | 150 random single-source reports of the development library, five nearest other-publisher reports each | 150 | ceiling estimate |

The blind 6 November set was not opened.

## Findings

**The development set measures one band.** Its 100 `borderline` pairs come from the matcher's undecided pairs at score ≥ 0.6: cosine 0.55–0.70, under the pair-model cutoff by construction. AUC of `same` against the rest there: cosine 0.43, pair model 0.52, the best combined head 0.61.

**Ceiling.** 17 of 150 single reports (11 %, 95 % interval 6–16 %) have a same-occurrence report from another publisher; 12 more have only a later development. On the development library a perfect matcher would raise the multi-publisher share from 30–31 % to about 38 % (35–42 %). The estimate holds for that library only: the 29 October library already stands at 38 % with the current matcher. Top-five retrieval can miss a counterpart; 14 close calls.

**Baselines on matcher-independent pairs.**

| Replay | Strict same / later / other linked | Strict recall | Story same+later / other | Multi-publisher event |
| --- | --- | --- | --- | --- |
| Stage 1 (two pins) | 67 of 100 / 14 of 66 / 3 of 119 | 0.67 | 89 of 166 / 3 | 259 of 924; 421 of 1,397 |
| Validation | 18 of 51 / 6 of 97 / 0 of 120 | 0.35 | 47 of 148 / 0 | 1,201 of 3,165 |

Both draws are stratified by shared headline words, so paraphrased pairs are scarce in them. Strict recall differs widely between the two periods and labellers; neither number is an estimate for the feed.

**Where the 33 missed Stage 1 `same` pairs stop.** Pair decided `match` but refused admission: 13, twelve of them by a conflict from one other member (`titleNumbers` 6, `weekday` 4, `semanticDivergence` 4, `places` 2; some pairs have two). Pair-level veto: 7 (`semanticDivergence` 4, `titleNumbers` 2, `places` 1). `differentAct`: 4. No stored decision: 9, of which 3 are rule matches the greedy placement never compared inside one event, 3 carry a conflict, 2 share names but fail the rule, and 1 was never a candidate. Pair model below the 0.90 cutoff: 0. Candidate search finds 99 of 100.

**Signals on the 396 Stage 1 pairs** (AUC, `same` against `later` / against the rest): shipped pair model, both orders averaged, 0.82 / 0.91; MiniLM cosine 0.88 / 0.95; `NLEmbedding.sentenceEmbedding` 0.79 / 0.87; `NLContextualEmbedding`, mean pooled, 0.75 / 0.87; logistic head on cosine and time gap, five-fold out of fold, 0.95 / 0.97. The pair model scores 100 of 108 `same` pairs and 57 of 106 `later` pairs at or above 0.90, and 31 of 400 pairs cross 0.90 when the texts swap. A three-way fine-tune of the cross-encoder on the Stage 1 labels alone reaches 0.83 / 0.92 from the shipped pair weights.

**Precision on the development set.** All 8 wrong strict links are pairs the pair model did not confirm, carried in by other members. The 3 `different` pairs are one event of four shopping-deal round-ups joined by three rule matches.

## Candidate

An evidence head: `same` against the rest, logistic over the cosine and the time gap (capped at 96 h), fitted on Stage 1. For two publishers within 36 h, a probability at or above the cutoff makes the pair a match, overriding `titleNumbers`, `weekday`, `places`, `headlinePlaces` and `differentAct` and the shared-name requirement. Weights −7.7861, 13.4012, −10.2524; cutoff 0.78, the lowest with out-of-fold precision ≥ 0.95 (79 of 108 `same`, 4 others), frozen before validation. The fitting script first read that rule as "this and every higher cutoff keep 0.95", which one high-scoring `later` pair turned into 0.99 (6 of 108 `same`); the rule was changed to the plan's wording before validation was scored. At 0.78 the tune replay (44 / 0 / 49), the authored matcher regressions (24 / 0) and the story regressions are unchanged; at 0.05 they break (42 / 7 on tune, 26 / 6 authored), so the setting reached them.

The plan on #737 named the falsifiers before any run.

| Falsifier | Result |
| --- | --- |
| Validation pair precision at the frozen cutoff under 0.90 | **Fired: 0.75** (33 `same`, 11 others, all 11 `later`; AUC 0.959) |
| A false pair on tune, the authored corpus or the matcher regressions | Not fired |
| Validation replay gains fewer than 3 strict `same` or adds more than 1 `topic`/`unrelated` link | Not fired (+4, +0) |
| Strict `different` rises on the development set | Not fired |

| Replay | | Strict same / later / other | Story same+later / other | Multi-publisher event |
| --- | --- | --- | --- | --- |
| Validation | baseline | 18 / 6 / 0 | 47 / 0 | 1,201 |
| | head | 22 / 6 / 0 | 51 / 0 | 1,235 |
| Stage 1 (in-sample) | baseline | 67 / 14 / 3 | 89 / 3 | 680 |
| | head | 73 / 16 / 3 | 99 / 3 | 712 |
| Development | baseline | 4 / 5 / 3 | 12 / 3 | 433 |
| | head | 5 / 5 / 3 | 19 / 3 | 464 |

Development, strict precision / recall 0.333 / 0.105 → 0.385 / 0.132; story 0.800 / 0.148 → 0.864 / 0.235. One read. The second planned run (the head's veto share for `titleNumbers` and `weekday`) was not run.

## Verdict

- **CONTRIBUTING's four conditions: fail.** Strict `same` does not fall, strict `different` does not rise and story recall rises; story `different` stays at 3, as planned for: it is the deals card, which nothing here touches.
- **Pre-registered falsifier: fired.** On out-of-time pairs a quarter of what the head calls one occurrence is a later development of the same story. The validation labels come from a second labeller with its own conventions and 48 close calls, so the drop from 0.95 to 0.75 mixes model and labeller.
- The replays added no `topic` or `unrelated` link on any set.

## Reading

No signal at hand separates one occurrence from a later development: on validation the rules match 25 `same` and 13 `later` pairs, the head 33 and 11; on Stage 1 the pair model passes 100 and 57. Every lever since 25 October has moved along that line. Whether a later development inside an event card is an error is a product rule before it is a model problem.

Open for Mars: the acceptance gate (the development set cannot register recall and one card decides its fourth condition); the 60 % target against the ceiling; whether admission may outvote a single member's `titleNumbers` or `weekday` veto, the largest measured loss; review of the Stage 1 and validation labels.
