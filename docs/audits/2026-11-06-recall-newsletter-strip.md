# Newsletter strip for the pair model on the 3 November holdout (#737, 6 November 2026)

Follows [the recall levers audit](2026-11-05-recall-levers.md), whose next lever was to strip a newsletter edition's ` | <series>` title suffix and digest body from the pair-model input and re-measure setting g on the knob build. No default changes.

## Knob

`NEWS_PAIR_STRIP_NEWSLETTER=1` sets `EventMatchPolicy.pairModelStripsNewsletter`, read by the test runner (`Tests/StoryCorpus.swift`, `policyFromEnvironment`). `EventMatcher.newsletterStripped(title:description:)` drops a trailing ` | <series>` suffix of one to six words without a digit, the body lines that carry a sign-up or newsletter phrase (at most 200 characters) and the first paragraph's `. Plus …` teaser. Only the pair-model input changes; the deterministic features and the sentence embedding keep reading the full text.

## Method

Same holdout, library copy, clock pin and matcher as the recall levers audit: `~/news-eval/holdout-2026-11-03/library-holdout-2026-11-03.json` (218 pairs), a fresh `0600` copy of `recluster.sqlite3` per run, `NEWS_HOLDOUT_NOW=1793642173`, matcher v15, pair-model prefix off, `NEWS_EVENT_DIAGNOSE=1`. Setting g is `NEWS_VETO_SHARE=0.34 NEWS_PAIR_THRESHOLD=0.85 NEWS_BORDERLINE_FLOOR=0.5`. The baseline and g ran on `origin/main` 1a3a7ca, which includes the 47706ce veto fix; the strip runs on the knob build.

## Results

| Run | Strict same / related / different | Strict P / R | Story s+r / different | Story P / R | Multi-publisher share (of 1,436) | Groups |
| --- | --- | --- | --- | --- | --- | --- |
| a baseline, main 1a3a7ca | 4 / 5 / 3 | 0.333 / 0.105 | 12 / 3 | 0.800 / 0.148 | 442 | 7 |
| g, main 1a3a7ca | 13 / 6 / 3 | 0.591 / 0.342 | 21 / 3 | 0.875 / 0.259 | 451 | 6 |
| strip | 4 / 5 / 3 | 0.333 / 0.105 | 12 / 3 | 0.800 / 0.148 | 442 | 7 |
| g + strip | 13 / 6 / 3 | 0.591 / 0.342 | 21 / 3 | 0.875 / 0.259 | 451 | 6 |

- g on current main reproduces the 5 November g row exactly, so the 47706ce veto fix did not change what g admits on this holdout.
- The strip does what the feature dump predicted at the pair level. The Guardian First Thing edition against France 24's same report moves from pair model 0.027 (`borderline`) to 0.977 (`match pairModel`); against the related Al Jazeera report under g from 0.057 to 0.982. Two further pairs of The Hindu's ` | Explained` series also become `match pairModel`.
- No event joins change: every strict, story, share and group number is identical with and without the strip, under the baseline and under g. The matched edition pair stays `MISSED` because event admission, not the pair, decides: the edition already sits in a larger event whose cross-pairs do not clear the two-thirds rule, and the veto share of g does not change that.

## Gate verdict

Nothing changes, so the strip neither passes nor fails the CONTRIBUTING gate on its own; it does not move g past story `different` either. The knob stays off and is kept as an evaluation override, because it removes a measured pair-model blind spot that a later admission lever would otherwise hide.

## Next lever

The pair model is no longer what keeps a newsletter edition out of its event; admission is. The diagnose output names pair decisions only, so the next step is to print the admission verdict of a matched pair (which cross-pairs fail the two-thirds rule and why) and then measure an edition-aware admission: a digest edition that reports several events should join through its matched pair without its other items vetoing, and should not count toward the two-thirds rule of other members.
