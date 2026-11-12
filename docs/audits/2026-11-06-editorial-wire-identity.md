# Editorial wire identity — 6 November 2026

## Result

`EditorialMomentum` can now be fed real rows: all 336 events of a copied library replay without an error. The feed is not yet good enough to accept momentum on real news. On the same copy, 73% of the rows in the replay window have unknown identity, because the library stores neither a byline nor, for most articles, body text. Only 32 of the 336 events have two or more independent reports, and only 3 reach the volume and origin floors.

Nothing in the app reads the mapping, and it adds no user-visible behaviour. A later slice stored the feed's author field to fill the byline gap. On one feed sample that added no agency credits; the named reporters it holds are estimated below.

## Contract

`EditorialWireIdentity.identities(event:)` is a pure function over one event's members. `momentumReports(eventID:members:)` turns its result into `MomentumReport` rows. Each article gets one basis:

| Basis | Evidence | Wire group | Origin |
|---|---|---|---|
| `credited` | The feed's author field or a byline-position credit names one agency, here or in a near-identical copy; or the feed is the agency | `wire:<agency>` | `agency:<agency>` |
| `multipleCredits` | Credits to several agencies | `wire:<a>+<b>` | unknown |
| `copies` | Near-identical title or text in the event, no credit | `copy:<lowest id>` | `unattributed:<lowest id>`; `publisher:<outlet>` when one outlet repeats its own full text |
| `fullText` | At least 100 words, no copy in the event, no agency named | `report:<id>` | `publisher:<outlet>` |
| `agencyMention` | At least 100 words naming an agency outside a credit ("told AFP", a photo credit) | unknown | unknown |
| `insufficient` | Under 100 words and no copy, or no publisher | unknown | unknown |

- **Credits** count only in byline positions: `PARIS (AFP) —`, `By Reuters`, a trailing `— AFP` or `(AP)`, `(FRANCE 24 with Reuters and AFP)`, `Reuters contributed`.
- **Near-identical** means an 8-word shingle containment of at least 0.8 over the longer of body and feed description, with at least 10 shared shingles; or title word Jaccard of at least 0.9 with at least 5 words on each side. Case, diacritics and zero-width marks are ignored.
- **Same agency, one group:** two differently worded credits to one agency in an event count once. A genuine second dispatch is undercounted, which cannot manufacture a burst.
- **`unattributed:` is one unnamed origin**, not a claim about a publisher. Two such groups from one agency overcount origins by one.
- **Clamping:** a publication stamped after News stored the article is clamped to the storage time, since it was published by then at the latest. Undated articles stay out of the replay. Without the clamp, the 40 such members would fail `invalidTime` for their whole events (34 of 336 events).

`OverviewPerspectivesExtractor.detectWireSource` does not fit, and that file is unchanged. Its substring markers fire on 91 of the 2,830 articles, 44 of them only because "upi" occurs inside another word, and the agency names read in context were almost all quotations and photo credits. Used here, it would merge two outlets for quoting Reuters, the opposite of independence.

## Measurement

Copy of the real library, last fetch 5 November 2026: 2,830 articles, 893 of them members of 336 events. Aggregates only; no article text leaves the private output directory.

| Scope | Articles | Known wire group | Known origin | `credited` | `multipleCredits` | `copies` | `fullText` | `agencyMention` | `insufficient` |
|---|---|---|---|---|---|---|---|---|---|
| Last 72 hours | 926 | 26.2% (243) | 26.1% (242) | 0 | 1 | 36 | 206 | 10 | 673 |
| Event members | 893 | 28.4% (254) | 28.0% (250) | 0 | 4 | 102 | 148 | 32 | 607 |
| Whole library | 2,830 | 24.7% (700) | 24.6% (696) | 0 | 4 | 102 | 594 | 39 | 2,091 |

Articles outside any event are mapped alone, so they can only be `fullText`, `agencyMention`, `insufficient` or credited.

Replay of each event over the 48 hours to its last fetch, with the values the synthetic sweep selected (300-second buckets, 1,800/10,800-second half-lives, three reports, two origins). These are not shipping defaults.

| Measure | Mapping as built | If every unknown row counted as its publisher's own report |
|---|---|---|
| Rows in window | 811 | 811 |
| Unknown rows | 591 (72.9%) | 0 |
| Independent reports | 177 | 767 |
| Events with two or more reports | 32 | 257 |
| Events reaching both floors | 3 | 21 |
| Events accelerating | 3 | 21 |
| Replay errors | 0 | 0 |

The right-hand column is the policy this mapping refuses. It multiplies acceleration sevenfold by crediting feed blurbs as independence, which the momentum contract rules out.

Copy groups: 50 multi-row groups hold 104 rows; 43 cross outlets, in 42 events. All 43 were read and no group looked wrong: 22 are the sister sites Euronews and Africanews, the other 21 mostly identical agency-style headlines across Arab News, CNA, The Hindu and Dawn. That is one reader's check, not a labelled precision.

Lowering the containment floor to 0.4 adds 6 groups and 14 rows, and known wire groups rise from 28.4% to 29.7% of members. The floor stays at 0.8, so outlets weaving the same agency paragraphs into their own story (0.39–0.54 shared on one plane crash) stay separate reports.

## Why rows are unknown

- **No byline was stored.** No `credited` row exists on this copy, which predates `articles.author`. The only credit found is the France 24 trailer naming several agencies. Storing the field adds almost no agency credits; see below.
- **Most articles have no body.** 424 of 2,830 articles (15%) have stored full text. Unknown rows in the last 72 hours fall hardest on BBC News (99), 9to5Mac (75), Arab News (57), The Hindu (57) and The Guardian (53).
- **Silence is weak evidence.** `fullText` is an assumption, not a finding: wire copy with no credit in its body reads as the publisher's own report unless a sibling in the event carries the same text. Its share of the known rows is therefore an upper bound on independence.

## Feed author field

`articles.author` (schema v33) now stores the RSS `author` or `dc:creator`, or the Atom author names, bounded to 300 characters. A refresh with no author keeps the stored one, and an author change is not a publisher revision. `media:credit` stays out: on The Guardian it credits photos. JSON Feed authors are not read. Nothing displays the field, and a story loaded for reading does not carry it. Any exact agency name in the field makes the article `credited`.

**Agency credits do not move coverage on this sample.** One fetch of 33 of the library's 34 feeds on 6 November, through the production parser:

| Measure | Value |
|---|---|
| Feed items | 1,066 |
| With an author | 566 (53%) |
| Naming an agency | 5 (0.5%): Dawn 4 of 24, The Guardian 1 of 171 |
| Library rows those feeds still serve, with an author | 346 of 2,830 (295 of 926 in the last 72 hours; 100 of 893 event members) |
| Those rows naming an agency | 0 |
| Known wire group, last 72 hours | 26.2%, unchanged |
| Unknown replay rows | 72.9%, unchanged |

The agency items are newer than the library copy's last fetch, so no stored row gained a credit. BBC News, Arab News, The Hindu, CNA, Euronews, Al Jazeera, CNBC and Deutsche Welle expose no author, so the agency-copy groups around Arab News, CNA and The Hindu keep no named origin. An earlier fetch the same day found 4 agency items; one fetch shows the rate is low, not exactly how low. Rows only gain authors once a build with v33 refreshes feeds that still serve them.

## Named-author estimate

The author field mostly holds people: 486 of the 566 authors pass a filter for a person's name (at least two words, a leading capital, no digit, no desk word, not the publisher or an agency). This estimate asks what would change if an unknown row with such an author counted as its publisher's own report. **The mapping and the app do not do this**; only the opt-in evaluation does.

| Measure | Mapping as built | Rows with an author now | Steady state |
|---|---|---|---|
| Known wire group, last 72 hours | 26.2% | 44.0% | 49.8% |
| Known wire group, event members | 28.4% | 34.7% | 45.4% |
| Unknown replay rows | 72.9% | 68.3% | 58.6% |
| Independent reports | 177 | 214 | 293 |
| Events with two or more reports | 32 | 47 | 79 |
| Events reaching both floors, and accelerating | 3 | 5 | 7 |

"Rows with an author now" only uses rows today's feeds still serve. "Steady state" also treats every stored row without an author as named when its publisher named a person on at least 80% of today's items, approximating a library that had stored authors all along: 9to5Mac, Ars Technica, Hackaday, MacRumors, Quanta Magazine, Science News, TechCrunch, The Guardian, The Verge and Wired. It is an estimate of a state no library is in.

**What limits it:**

- **The gain is not in world news.** 9to5Mac, Wired and The Guardian supply 135 of the 164 rows gained in the last 72 hours. BBC News, Arab News, The Hindu, CNA, Al Jazeera and Euronews gain nothing because their feeds name nobody, so they stay unknown under any author policy.
- **A name is not proof.** 8 of the 93 event members with a named author (9%) sit in a verbatim copy group across outlets. That is a floor: only copies with a sibling carrying the same text can be seen, and a rewrite under a reporter's name cannot.
- **No labels.** The extra accelerating events are not validated bursts, so this measures coverage, not whether momentum gets better.
- **The filter is a word list.** An unusual desk label passes it. Twelve authored non-person shapes are pinned in the atom, but it has not been checked against the full field.

So a named author is a much stronger lever than an agency credit, and still leaves most world-news rows unknown. Adopting it would be a policy change needing labelled burst and quiet windows first.

## Reproduction

```sh
sqlite3 "file:<library>?mode=ro" ".backup '/private/tmp/wire-identity/news.sqlite3'"
sqlite3 /private/tmp/wire-identity/news.sqlite3 "pragma journal_mode=delete"
NEWS_WIRE_IDENTITY_FETCH_FEEDS=1 bash script/test_editorial_wire_identity.sh /private/tmp/wire-identity/news.sqlite3 /private/tmp/wire-identity/results
```

The script refuses a path inside an app container and refuses to overwrite a report. It reviews the upgrade on a second private copy. The fetch variable is optional and contacts the copy's subscribed feeds once. The regression atom is `Tests/EditorialWireIdentityTests.swift`, 79 checks on fictional authored cases, and runs under `./test.sh`.

## Migration review

A private copy at schema v29, the version the installed library is on, opened through the production engine and upgraded to v33, not read-only. Articles (2,830), event members (893), feeds (34), read (5), saved (2) and searchable rows (2,830) were the same before and after. The copy the upgrade keeps stayed at v29 with the same counts, which is the rollback path; an older build opens a v33 library read-only. The real library was not touched.

## Completed evidence

- `./test.sh` passed in full, including the 27 Debug atom checks. `script/format.sh --check` passed.
- The script ran end to end on the copy through the Xcode Release runner; its report matched a Debug runner's on the same copy. It refused the live container path.
- An isolated arm64 ad-hoc app build passed. The app was not installed or launched.
- The author slice repeated these on its own branch: 79 atom checks, including parser, storage, v32 upgrade and named-author estimate cases.

## Limits

- No labels, so there is no accuracy claim. Acceleration counts are not validated bursts.
- Thresholds were read off this same copy, with no holdout and one library's feed mix.
- Credit shapes other than the France 24 trailer have no live occurrence here; only authored cases exercise them.
- `published_at` can be a revision date rather than the first publication, which can place a report in a later bucket than it belongs.
- Pair-style comparison cannot see a copy when a sibling has only a differently worded blurb and a different headline.
