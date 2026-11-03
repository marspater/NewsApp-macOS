# Story country signal with a sub-national place veto (#737, 3 November 2026)

Follows [the 30 October measurement](2026-10-30-story-country-signal.md), whose best setting (K = 2, common countries excluded) left one wrong story group in 39 (2.6 %, against ≤ 2 %): the Uttar Pradesh and Karnataka legislative-council elections, joined by "India" alone. ADR-001 (#843) keeps the country signal off until a fresh holdout shows a recall gain with wrong story groups at or under 2 %.

## Candidate

`EventMatchPolicy.storyCountryPlaceVeto` (on whenever the country signal is on; `NEWS_STORY_COUNTRY_PLACES=0` lifts it to measure without it): a cross pair does not count toward the country signal's two thirds when both reports name places below country level and no word of one's places is among the other's (`EventMatcher.namesDifferentLocalPlaces`). A report naming only the country is not vetoed. The signal itself stays off by default.

## Fresh library holdout (3 November 2026)

- Library copy: `~/news-eval/library-2026-11-03.sqlite3` (SQLite backup of the installed app's library, read-only source, journal mode delete), 1,889 articles from 34 feeds, newest 2 Nov 16:56 UTC, SHA-256 `b07db06365dc21fdc75ce801e2789be5a7c416429f947a53e66b599ba9ab403f`. 1,626 articles were published after the 29 October holdout was drawn.
- Clustering: the copy re-clustered at matcher v15 (`NEWS_RELATED_RECLUSTER=1 --related-live`, work copy under `/private/tmp`, as the runner requires) made one pass and changed no event: the installed app already clusters with v15. Candidates (`--review-pairs --holdout-candidates`): 218 pairs, 100 borderline, 60 fragment pairs, 58 singletons, SHA-256 `82f70dec…2d3e`; identical to a draw from the copy as the app left it.
- Labels: an agent that did no matcher work labelled the pairs under the pair review protocol in CONTRIBUTING: 38 same, 43 related, 137 different, with 31 close-call notes. The coordinator's blind spot-check of 30 rows (the first twenty and ten singletons) agreed on 25; all five disagreements are related against different at the story boundary (an Iran-war explainer and the coalition-leverage analysis the labeller joined to their stories as related; three Pakistan–Afghanistan and Moscow pairs the labeller kept different under the tie rule), none same against different, and no label was overturned. The US midterm elections dominate the set as the Israeli election dominated 29 October's (explainers and previews joined to the election as same).
- File: `~/news-eval/holdout-2026-11-03/library-holdout-2026-11-03.json` (`0600`), SHA-256 `40708d895d4cb7b4a79df5c6fa856c48da6006d8c52f46325349a5771e0ac9ed`. Clock pin `NEWS_HOLDOUT_NOW=1793642173` (2 Nov 17:56:13 UTC, newest article plus one hour).

## Results

Matcher v15, pair cutoff 0.90, pair-model prefix off, clock pinned, each run re-clustering a temporary copy from scratch (2 passes, about 54 s). Strict event results are identical in every row (12 linked = 4 same, 5 related, 3 different; precision 0.333, recall 0.105): the signal only links stories.

| Setting | Story level (same + related / different) | Story precision | Story recall | Multi-publisher story share | Story groups | Wrong groups |
| --- | --- | --- | --- | --- | --- | --- |
| Signal off | 4 + 8 / 3 | 0.800 | 0.148 | 442 of 1,436 (30.8 %) | 7 | 0 |
| K = 2, with the place veto | 4 + 8 / 3 | 0.800 | 0.148 | 443 (30.8 %) | 7 | 0 |
| K = 2, without the veto | 4 + 9 / 3 | 0.812 | 0.160 | 444 (30.9 %) | 8 | 0 |

- With the veto, the signal changes one group: a Polish constitutional-crisis report joins the two-event Polish story. No labelled pair changes.
- Without the veto it also forms a US–Pakistan–Afghanistan group (a statement on terrorism from Afghanistan and Pakistan's rebuke of the Taliban), which links one labelled related pair. The veto blocks it because the two reports name different places below country level.
- Story groups were labelled one by one by the same independent agent (9 distinct groups across the three runs, `story-group-labels.txt`): all right, none wrong or unsure. The group only the run without the veto forms was a close call, labelled right, as its pair 81 is labelled related.
- No setting joins stories across countries (`cross_country`: 0 groups in each).
- The story-level wrong links (3) are the same in every row; they come from the event and story passes, not from the country signal. The observed 0 % wrong-group rate in these 7–8-group runs shows no regressions here, but such small samples do not establish whether the population rate meets the ≤ 2 % gate.

## Decision

No default changes. The country signal stays off and the matcher version is unchanged.

- **The signal's effect is small on both holdouts.** It moved the multi-publisher story share by 0.6 points on 29 October and by 0.1 on this set, against a 60 % target from a 31 % base. Country-only links are not the lever that closes #737's gap.
- **The veto's evidence is split, and both samples are tiny.** On 29 October it removes the one wrong group (two states' council elections). On this set it removes one group labelled right (a close call) and costs one labelled related pair. With 7 to 8 groups per run, "0 wrong" cannot show a wrong-group rate at or under 2 %; it only shows that none appeared.
- **What ships:** the veto as part of the evaluation knob (`NEWS_STORY_COUNTRY_PLACES=0` lifts it), so the next holdout measures both. #737 stays open.
- **Next lever:** event-level recall. On both sets most missing story links are reports the matcher leaves in separate events (strict recall 0.105 here), not stories that share only a country.
