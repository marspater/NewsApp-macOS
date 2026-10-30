# Story country signal measured (#737, 30 October 2026)

#737 asked for country-only stories (Jordan church attack, France's 70,000 police, Ebola in two countries) to form one card each, the multi-publisher story share to rise toward 60 %, and wrong story groups to stay at or below 2 %, measured on the fresh library holdout with the authored sets unchanged.

## Candidate

A story-pass signal for events that share only a country (`EventMatchPolicy.storyCountryKeywords`, evaluation knob `NEWS_STORY_COUNTRY=K`, off by default):

- two active events, or a report alone and an event, are one story when two thirds of their cross pairs share a country, have no conflict (so no different act), share at least K keywords and reach the semantic veto's cosine (0.55);
- a country held by more than the common-actor share (5 %) of active events is excluded: it is the backdrop of many stories (a war's country, the US), not a link between two of them;
- a reader's exclusion vetoes the link as in the rest of the story pass.

## Results

Fresh library holdout (`~/news-eval/holdout-2026-10-29/`, SHA-256 `a0b681bc…3545`, clock pin 1793300435), matcher v14. Story groups (stories that join two or more events) were labelled one by one by a separate agent and spot-checked independently by the orchestrator on its own random sample.

| Setting | Story level (same + related / different) | Story precision | Story recall | Multi-publisher story share | Story groups | Wrong groups |
| --- | --- | --- | --- | --- | --- | --- |
| v14 (off) | 7 + 3 / 4 | 0.714 | 0.106 | 40.0 % | — | — |
| K = 2, every country | 61 + 7 / 5 | 0.932 | 0.723 | 42.6 % | 60 | 6 (10 %), 3 unsure |
| K = 3, every country | 23 + 5 / 4 | 0.875 | 0.298 | 41.0 % | 54 | not labelled |
| K = 2, common countries excluded | 14 + 5 / 4 | 0.826 | 0.202 | 40.6 % | 39 | 1 (2.6 %) |
| K = 3, common countries excluded | 11 + 5 / 4 | 0.800 | 0.170 | 40.3 % | 35 | not labelled |

Strict event results are unchanged in every row (6 same / 3 related / 3 different): the signal only links stories. Matcher regressions stay 24 / 0. Story regressions change only by fixing the Jordan church known gap (the King's statement joins the attack's story, s18).

- **Every country** links far more labelled pairs, but five of its six wrong groups join unrelated Russia–Ukraine war items that share only "Ukraine" (an analysis piece and a poll, strikes in different regions, the Swedish preparedness feature and a Dutch aid package).
- **Common countries excluded** removes those; the one remaining wrong group joins the Uttar Pradesh and Karnataka legislative-council elections (same country, same kind of vote, different states).

## Decision

No setting meets every target. The best one (K = 2, common countries excluded) raises story precision and doubles story recall on the labelled pairs and fixes the Jordan case, but it leaves 2.6 % wrong groups against 2 % and moves the multi-publisher share by 0.6 points against a 60 % target. The signal ships off by default as an evaluation knob so it can be re-measured on the next holdout. The remaining recall work, and whether it stays in v2, is the owner's call.

Next levers seen in the labels: a disjoint sub-national place ("Karnataka" against "UP") as a veto for the country signal, and the matcher's own event-level misses (two reports of Harry Kane's Ballon d'Or were two events, which the story pass then joined).

## Cross-country check (owner's request: an event about one country must not land in another's story)

`--library-holdout` with `NEWS_EVENT_OUTPUT` now flags every story group and every event whose members' headlines name disjoint countries (`cross_country` in `story-groups.csv`, and `cross-country-events.csv`), and prints the counts. Headline countries are a coarse signal, so each flagged case was read.

| Setting | Story groups with disjoint headline countries | Events with disjoint headline countries |
| --- | --- | --- |
| v14 (off) | 1 of 25 | 15 |
| K = 2, common countries excluded | 2 of 39 | 15 |

- **Stories:** no unrelated-country joins. The flagged groups are Flavio Bolsonaro leaving Brazil for the US (one story) and the Saudi–Houthi war (one conflict).
- **Events:** of the 15, about nine are one event reported from two countries' side (Ceuta migrants: Morocco and Spain; the RAF Fairford plot: UK and Iran; Russian diesel and US prices; the Israeli ban on a UK delegation). About six are real mix-ups inside one conflict or region: Kyiv firefighters joined with Kramatorsk, a Ukrainian evacuation joined with Russian strikes on Kyiv, three different Houthi/Saudi acts, Senegal's Youth Olympics opening with Kenyan athletes.

So a plain "disjoint countries conflict" rule would split the nine true events. The next country work is event-level: different named places inside one conflict (Kyiv against Kramatorsk) and different incidents under one live-blog series, each measured on the holdout before it ships.
