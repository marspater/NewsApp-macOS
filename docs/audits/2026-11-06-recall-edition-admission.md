# Edition-aware admission on the 3 November holdout (#737, 6 November 2026)

Follows [the newsletter strip audit](2026-11-06-recall-newsletter-strip.md), whose next lever was to print the admission verdict of a matched pair and then measure an edition-aware admission. No default changes.

**Finding: the admission verdicts rule out the digest mechanism, and the knob fails the gate.** No edition's other items veto a matched pair and no edition's count decides a two-thirds rule in any of the four matched misses. The knob links no new `same` pair and loses one story link.

## Knobs and diagnose

- `NEWS_EVENT_DIAGNOSE=1` on `--library-holdout`: a `same` pair decided `match` that stays apart now prints each article's event with its size, whether each article would enter the other's event, the rules that refuse it, and the first twelve refusing cross-pairs with conflict, shared names, score, cosine and pair-model score. The verdict describes the final membership. The clustering pass is greedy, so it may have refused against fewer members.
- `NEWS_EDITION_ADMISSION=1` sets `EventMatchPolicy.editionAdmission`, read in `Tests/StoryCorpus.swift`, `policyFromEnvironment`. An edition is a title `EventMatcher.newsletterStripped` recognizes: a trailing ` | <series>` of one to six words without a digit. `EventMatcher.admissionPairs` hands `eventScore` the edition's best matched pair alone when the joining report is an edition, and drops edition members from a report's cross-pairs unless only editions are there. Fragment merges compare a host's other reports only. A reader's "Same Event" still counts.

## Method

Same as the strip audit: `~/news-eval/holdout-2026-11-03/library-holdout-2026-11-03.json` (218 pairs), a fresh `0600` copy of `recluster.sqlite3` per run, `NEWS_HOLDOUT_NOW=1793642173`, matcher v15, pair-model prefix off, `NEWS_EVENT_DIAGNOSE=1`. Setting g is `NEWS_VETO_SHARE=0.34 NEWS_PAIR_THRESHOLD=0.85 NEWS_BORDERLINE_FLOOR=0.5`; strip is `NEWS_PAIR_STRIP_NEWSLETTER=1`. Every row ran on this branch, which contains #1052. Pair numbers are 0-based in JSON order, as in the recall levers audit; `labels.txt` is 1-based.

## Results

| Run | Strict same / related / different | Strict P / R | Story s+r / different | Story P / R | Multi-publisher story share (of 1,436) | Groups |
| --- | --- | --- | --- | --- | --- | --- |
| baseline | 4 / 5 / 3 | 0.333 / 0.105 | 12 / 3 | 0.800 / 0.148 | 442 | 7 |
| knob | 4 / 4 / 3 | 0.364 / 0.105 | 11 / 3 | 0.786 / 0.136 | 443 | 7 |
| g + strip | 13 / 6 / 3 | 0.591 / 0.342 | 21 / 3 | 0.875 / 0.259 | 451 | 6 |
| g + strip + knob | 13 / 5 / 3 | 0.619 / 0.342 | 20 / 3 | 0.870 / 0.247 | 451 | 6 |

The baseline and g + strip rows reproduce the strip audit, so the diagnose and the knob's off path change nothing.

`--matcher-regressions` and `--story-regressions` are identical under defaults, the knob alone and g + strip + knob: matcher precision 1.000 (TP 24, FP 0), recall 0.923 (FN 2), no false pair; story regressions 18 event pairs and 26 story pairs, known gaps 3 event and 7 story, nothing unexpected.

### The one pair the knob moves

Pair 93, `related`, is the only labelled pair that changes, in both knob rows: it leaves one event and one story. World News "Majority of funds stolen in cryptocurrency hack replenished, Binance says" no longer shares an event with The Hindu's "What we know about Binance's multi-billion-dollar crypto hack | Explained". The Hindu's piece is an explainer, not a digest, but its suffix marks it as an edition, so it stops counting and World News lands in another Binance event. Across the window, only Binance events change between the runs with and without the knob.

### The detector over-fires

The window holds 22 editions by this rule out of 1,436 reports, and 7 of them are in an event with or without the knob. From their titles, one is a multi-story newsletter (The Guardian's First Thing). The others carry bylines, column names or series names: Guardian columnists, The Hindu's `Explained`, CBC's `About That`, Polygon's `Shelf Quest`.

### Admission verdicts under g + strip

Four of the 25 missed `same` pairs are decided `match`, and two of 34 at baseline. The other misses are `borderline` (16, baseline 26), have no stored decision (3, baseline 4), or are `related-act` (1) or `vetoed` (1), so no admission rule can reach them.

| Pair | Reports | Verdict |
| --- | --- | --- |
| 28 | The Guardian First Thing (edition) / France 24 | The edition is already in the 14-member Stevens event. France 24 is refused it: 6 of 14 veto (`weekday` 4, `semanticDivergence` 2), two-thirds 8/14 needs 10. `weekday` is not outvotable, so no veto share admits it. The edition is refused France 24's 2-member event by Politico (`semanticDivergence`, cosine 0.38). Under the knob the edition would be admitted (0.66) but stays in the event it already fits. |
| 52 | World News / The Verge | No edition. World News is in a 2-member event and is refused The Verge's 8-member event: `places` 3/8, no shared name 3/8, two-thirds 5/8 needs 6. The Verge would be admitted to World News's event (0.68), but it already sits in the larger event it fits. |
| 130 | BBC News / The Guardian | No edition. The Guardian's report holds no event and is refused BBC's 3-member event: `semanticDivergence` 2/3, no shared name 1/3, two-thirds 1/3 needs 2. |
| 150 | France 24 / Al Jazeera | No edition. Al Jazeera's report holds no event and is refused France 24's 8-member event: `semanticDivergence` 4/8, no shared name 1/8, two-thirds 4/8 needs 6. |

Pair ids (`a` / `b`, all `feed-guid:`):

- 28: `04496a1b55cad8684035a191ae5740d805d37f36c572c20e4c95f043f729739f` / `f0bdb7ce658d27b1d98e36d8146b647aa3a0304aee3fb4e46849192005117612`
- 52: `02eb2185a4e4e3af88be21b5ac6c413f816db4a288cebd93a72c638bf1101b3d` / `3c3d700d1b62bac89907620f602d77f11193f67d9e08401cda750df11fd60dde`
- 93: `38d40da49c028b2f5e5b1f539d7be4cd581b69c3e7cf8c40feddad83979b0284` / `a37078b85016173663bd99f7fc53f371de17555df53c5e0bcb173149d4b65f8c`
- 130: `34e13ab1a65a2be88695c5bf10d3ca2ec00165a52c8dc0153ac8d4cd365f62bd` / `9005869065cfec4181016e21fd66db7ebc38af10066adf4db430441558874d1b`
- 150: `bc64410edb2511408d78f570fe3d639f186c98fc067c6f2f828c6b57e8de8a4b` / `e14fff6cd8d181ee7211d23898f6522966fd483a165e79d087b484749653aad0`

The strip audit's reading that the edition "already sits in a larger event" was right, but the blockers are France 24's own conflicts with that event's other reports, not the digest. Under g + strip the edition's place in that event also carries linked pairs 5 and 43 (`same`) and 21 (`related`), so moving the edition toward France 24 would lose more than it gains.

## Gate verdict

**Fail.** Against the CONTRIBUTING gate, measured from the baseline:

| Gate rule | Knob | g + strip + knob |
| --- | --- | --- |
| Strict same must not fall | holds, 4 → 4 | holds, 4 → 13 |
| Strict different must not rise | holds, 3 → 3 | holds, 3 → 3 |
| Story different must fall | **fails**, 3 → 3 | **fails**, 3 → 3 |
| Story recall must rise | **fails**, 0.148 → 0.136 | holds, 0.148 → 0.247, but below g + strip at 0.259 |
| Matcher and story regressions unchanged | holds | holds |

All of the recall in the last column comes from g. The knob only lowers it. The knob stays off and the matcher version is unchanged. #737 stays open.

## Next lever

Do not narrow the edition detector for this holdout: with a digest-only detector the knob still reaches no matched miss, because pair 28 is the only one with an edition and its blockers are other reports. Two findings are worth measuring instead:

- The semantic veto at event admission: `semanticDivergence` refuses pairs 28, 130 and 150, and pair 150's four vetoes sit at cosine 0.52 to 0.55 against the 0.55 cutoff. Measure `NEWS_SEMANTIC_VETO=0.5` on top of g; it is a global cutoff, so the false links in the gate decide it.
- `borderline` misses: these are 16 of 25 under g + strip and 26 of 34 at baseline, against 4 and 2 for matched pairs. Admission cannot reach them, so the larger recall lever remains the pair decision. Story `different` also needs its own lever: no run here moves it from 3.
