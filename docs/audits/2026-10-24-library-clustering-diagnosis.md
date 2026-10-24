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
