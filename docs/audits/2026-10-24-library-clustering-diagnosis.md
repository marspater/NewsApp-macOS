# Library clustering diagnosis — 24 October 2026

Refs #579 (M6), #574. Read-only copy of the live library taken with `sqlite3 .backup` on 24 October 2026 (schema v25, 5,998 articles, matcher v11, `main` at `2334b79`). Numbers are SQL counts on the copy; headline examples are quoted from it. The private holdout is not used here: at 49 articles it stands at recall 1.000 and cannot show what the reader sees in a library fed by twenty subscriptions and the World Tension panel.

## Counts, last 3 days

| Measure | Value |
| --- | --- |
| Stories published in the last 3 days | 1,541 |
| Of which in an event | 689 (45%) |
| Events with two or more members | 668 |
| Single-member events | 28 |
| `pair_assessments` rows (whole library): match / borderline / related-act | 1,405 / 470 / 56 |
| Same-title, same-source pairs in 7 days (duplicate items) | 12 |
| Largest sources in the window | Arab News 219, The Guardian 174, BBC News 158, Al Jazeera 144, The Hindu 106 |

## What the reader sees as one story, shown as several cards

| Story | Cards in the copy | Why the matcher keeps them apart |
| --- | --- | --- |
| Fire at Hitler's Eagle's Nest | {Guardian "Suspect arrested over fire…", BBC "Arrest made after fire…", DW "…catches fire, police say"} and {Euronews "Fire engulfs…", Arab News "Fire devastates…", Al Jazeera "German police detain suspect after fire…"} | Act-class veto (`EventConflict.differentAct`, the last conflict checked in `pairConflict`): arrest vs fire are two acts by the corpus convention "one act, one event". The related-act link exists but only surfaces as "Earlier in This Story". |
| Jordan church attack | 96B849F2 (Al Jazeera, BBC ×2, The Hindu "seven killed"), C0FDCE79 (Guardian "nine killed", Al Jazeera "who was behind", The Hindu and Dawn condemnations, Arab News survivor), 8F7A8ADB (King Abdullah orders response, US embassy ×2), plus a singleton (Al Jazeera "King Abdullah orders firm response") | Attack, condemnation and response are three acts; event admission requires every pair anchored and conflict-free; `mergeFragments` (EventClustering.swift:392-447) merges only rule-compatible fragments. |
| France deploys 70,000 police | CBC + The Hindu in one event; DW, Africanews, France 24, CNA each alone; "France braces for new protests" alone | Fragments that share "France", "police", "70,000" and "protests" but fail the all-pairs admission; "deploy" vs "protest" acts. |
| Pope Leo's cancer treatment | DW + CBC one event; Al Jazeera another; France 24 and BBC singletons; cosines between them 0.74–0.87 | No shared specific anchor: "Pope" is sentence-initial and typed as a common noun, "XIV" is not a name, the BBC headline ("Pope does not need further treatment after lung cancer surgery") has no name or place. Semantic rescue needs `sharedSpecific ≥ 1`. |
| OpenAI safety monitors (CNA, identical headline twice) | Two articles, pair stored as borderline with score 1.000 | Sentence-initial "OpenAI" becomes a name only when the lemmatizer has no lemma (`isUntypedInitialName`, EventMatcher.swift:304-310) and NLTagger does not tag it; without an anchor neither rule match, rescue nor the pair model (`needsPairModel` requires `sharedAnchors ≥ 1`) can fire. Also a duplicate item from one publisher. |
| iOS 27.2 (9to5Mac ×3) | One in an event, two singletons | Same anchor gap; product tokens are never anchors. |
| Ebola | Kenya deaths (4 publishers), Nigeria first case (2), vaccine trial (2), Africa CDC meeting (2), five singletons about Nigeria's case and screenings | Sub-stories are correctly separate acts; the reader wants one story with a timeline. The Nigeria singletons share "Nigeria", "Ebola", "case" with event 46386891 and still do not join. |

Correct separations in the same window, for balance: France protests vs Milan protests; the Paris shooting vs the Jordan church shooting; Real Madrid vs Bayern live blogs (borderline 0.76, not merged).

## Reading

1. Precision engineering is complete: no wrong merge was found among the pairs read for this diagnosis, and the authored corpus and holdout both stand at zero false pairs.
2. The missing recall has four mechanisms, none of them a threshold: the act-level event definition shown directly as cards (#581), anchors lost for headline-initial, Title-Case, organization and product names (#580), fragment merging that cannot use the pair model and an all-pairs admission rule (#582), and duplicate items from one publisher (#583).
3. The old holdout cannot gate these changes. #579 draws a holdout from this library: borderline rows with score ≥ 0.6, singletons sharing a keyword with an event within 36 h, and fragment pairs sharing two terms, labelled by Claude under the protocol in CONTRIBUTING with Mars spot-checking twenty.

## Reproduce

```sh
sqlite3 "file:$HOME/Library/Containers/com.marspater.news/Data/Library/Application Support/com.marspater.news/news.sqlite3?mode=ro" ".backup copy.sqlite3"
sqlite3 copy.sqlite3 "select decision, count(*) from pair_assessments group by decision"
sqlite3 copy.sqlite3 "select coalesce(em.event_id,'-'), a.source, a.title from articles a left join event_members em on em.article_id=a.id where a.title like '%Eagle%Nest%' and a.published_at > strftime('%s','now','-3 days') order by em.event_id"
```

## Library holdout (#579)

Drawn from the same copy with `--review-pairs --holdout-candidates` and labelled by Claude under the pair review protocol in CONTRIBUTING (Mars's 20-pair spot-check pending: the first twenty borderline candidates in the recorded order). The file stays outside the repository: `~/news-eval/holdout-2026-10-24/library-holdout-2026-10-24.json` (`0600`), SHA-256 `bbb4ded1d9c635444053b63ae638ddba3f3e3f6c0a014caa012155c67a1710b9`; the candidate export `holdout-candidates.csv` sits beside it.

| Class (drawn in SHA-256 order of the two ids) | Pairs | `same` | `related` | `different` |
| --- | --- | --- | --- | --- |
| Borderline decisions scored ≥ 0.6 | 100 | 39 | 20 | 41 |
| Singletons sharing a specific anchor and a keyword with an event member within 36 h | 59 | 4 | 4 | 51 |
| Pairs of active events sharing two terms (earliest members) | 60 | 1 | 1 | 58 |
| Total | 219 | 44 | 25 | 150 |

These are hard pairs by construction: everything the rules nearly matched or nearly merged. The old holdout (49 articles) has none of them.

**Baseline, matcher v11** (`--library-holdout`: the copy re-clustered from scratch inside the 72-hour window, 2 passes, 57 s):

| Measure | Value |
| --- | --- |
| Pairs linked | 15: 8 `same`, 4 `related`, 3 `different` |
| Precision (`same` among linked) | 0.533 |
| Recall on `same` | 0.182 (8 of 44) |
| Recent stories in a multi-publisher event | 587 of 1,556 (38%) |

**Matcher v12 (#580)** on the same holdout: 21 pairs linked (14 `same`, 4 `related`, 3 `different`), precision 0.667, recall 0.318 (14 of 44); the seven wrong links are the same seven as under v11 (no new wrong link), 598 of 1,556 recent stories (38%) in a multi-publisher event. Authored corpus 22 / 0 and private tune replay 44 / 0 / 49 unchanged. Newly linked: the CNA OpenAI pair, both iOS 27.2 pairs, two of four Pope Leo pairs, Real Madrid vs Leipzig report and live blog, and a Taiz pair; still missed: Storm Austen (anchors shared, cosine 0.69 and pair model 0.86 just under their cutoffs), the PHP explainers, the France protest live blogs and the CNA Pope report whose lead names three countries.

**Same-publisher duplicates (#583)** on the same copy (`--duplicate-replay`, 18 same-publisher same-headline pairs of the last seven days): 10 become one story, every genuine duplicate (0 to 2.6 h apart: CNA, France 24, Arab News, Al Jazeera); 8 stay two: seven "Cartoon by Amjad Rasmi" items 23 h to 16 days apart and one Arab News analysis reposted 14 h later, outside the 12-hour window chosen so the daily cartoon stays separate.

**Gates sweep (#582)**, each change alone against this holdout at matcher v12 (14 true / 7 wrong links, 598 of 1,556 recent stories in a multi-publisher event):

| Change | Linked `same` / wrong | Multi-publisher share |
| --- | --- | --- |
| Pair model off | 8 / 7 | 31% |
| Pair-model cutoff 0.95 | 14 / 7 | 38% |
| Pair-model cutoff 0.85 | 14 / 8 | 38% |
| Pair-model cutoff 0.80 (the issue's proposal) | 15 / 8 | 39% |
| Rescue at cosine ≥ 0.65 for pairs sharing two specific anchors | 15 / 9 | 39% |
| … at ≥ 0.60 | 15 / 16 | 39% |
| Anchorless pairs at cosine ≥ 0.85 to the model | 14 / 7 | 38% |
| Compatibility only for matching pairs | 6 / 2 | 37% |
| Unanimous admission (`compatibleShare` 1.0) | 11 / 5 | 38% |
| Same-publisher pairs compatible only when matching | 13 / 6 | 38% |

Nothing is adopted. The loosenings buy at most one true link for one or more wrong ones (cutoff 0.80: 15 / 8; cutoff 0.85: 14 / 8; two-anchor rescue at 0.65: 15 / 9, at 0.60: 15 / 16); the cutoff at 0.95 and the anchorless gate change nothing (14 / 7); the tightenings remove one or two wrong links for one to eight true ones (same-publisher rule 13 / 6, unanimous admission 11 / 5, compatibility only for matching pairs 6 / 2). The model at 0.9 is net positive (six true links, no wrong one, against the model off). The fragment-merge model path and the admission tolerance for model-confirmed pairs the issue asked for already exist since v11: `mergeFragments` → `compatibleFragments` applies the rule checks first and then `assessed` asks `PairScorer` for the eligible borderline cross pairs, and `modelConfirmed` stands in for the shared anchor in `eventScore`; that path makes 0 merges on the copy before and after. The seven wrong links are three reports carried into an event by a third member's match (two same-publisher), three related acts the act classifier does not classify, and one pair-model confirmation at 0.986. Authored corpus 22 / 0 and private tune replay 44 / 0 / 49 unchanged with the knobs off and with the same-publisher rule on.

The gate for #580, #582 and #581 is this file: precision ≥ 0.97 means at most one wrong link among the pairs linked, and every slice reports the recall it adds. Identical and near-identical headlines left unlinked here (CNA "OpenAI says its AI agents disabled their own safety monitors" twice, 9to5Mac "iOS 27.2" pairs, four Pope Leo pairs across CNA, BBC, CBC and Al Jazeera, Storm Austen across BBC, Euronews and Africanews) are the #580 targets. The three wrong links are two Euronews/Africanews daily bulletin pairs and one same-publisher series pair, the pattern the pair review found (`docs/audits/2026-10-24-pair-decision-review.md`).

```sh
NEWS_SNAPSHOT_DB=copy.sqlite3 NEWS_EVENT_OUTPUT=$HOME/news-eval/holdout-2026-10-24 ./test.sh --review-pairs --holdout-candidates
NEWS_SNAPSHOT_DB=copy.sqlite3 NEWS_LIBRARY_HOLDOUT=$HOME/news-eval/holdout-2026-10-24/library-holdout-2026-10-24.json ./test.sh --library-holdout
```
