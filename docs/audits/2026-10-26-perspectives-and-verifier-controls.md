# Perspectives coverage and claim-verifier controls — 26 October 2026

Refs #547 (epic L, #573). Source: `mars/l-547-perspectives`, stacked on #650. Sample: the installed library (6,400 stories, last refreshed 25 October 18:05 UTC), copied read-only with SQLite's backup API into a private temporary directory. Every run used `./test.sh --overviews-live` with `NEWS_OVERVIEWS_EXTRACT=1` (publisher text fetched for each event, as in production), a 72-hour window ending at the run, and model drafts for every multi-source event. Passages, model records and the claim sheet stay in the private run directories; only aggregates are recorded here.

## Perspectives

Target: at least 60 % of multi-source events with two or more perspectives; Mars raised it on review to clearly above 61 %, on every stored-text replay and on a fresh live run, since run-to-run noise spans about two points. The 10 October figure (25/55, 45 %) came from a different window.

Live runs (fresh library copy, publisher text fetched):

| Run | Code | Events | Two or more | One | None | Publisher texts stored |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| A (baseline) | #650 tip (`4d968f2`) | 134 | 67 (50.0 %) | 36 | 31 | 222 |
| E | first pass | 131 | 80 (61.1 %) | 28 | 23 | 234 |
| F | first pass, final verifier | 130 | 63 (48.5 %) | 36 | 31 | 168 (degraded) |
| G | first pass (`5a21532`) | 122 | 75 (61.5 %) | 26 | 21 | 217 |
| H | second pass (`428e11e`) | 120 | 79 (65.8 %) | 21 | 20 | 182 |
| **I** | **final (`68b3295`)** | 115 | **80 (69.6 %)** | 23 | 12 | 191 |

Run F's fetch was degraded while other sessions loaded the Mac (19 deadline cuts). Run H fetched less than G (13 deadline cuts) and still reached 65.8 %. Run I, on the final code, fetched cleanly (5 deadline cuts); on its own stored text the baseline code reaches 57/113 (50.4 %). The window shrinks from 134 to 113 events because the library was last refreshed on 25 October and the 72-hour window moves with each run.

Same-input replays on the publisher text stored by six runs, baseline and final code measured at the same moment (113–114 events):

| Stored text from | Baseline code | Final code (`68b3295`) |
| --- | ---: | ---: |
| A | 59/114 (51.8 %) | **79 (69.3 %)** |
| B | 60/113 (53.1 %) | **83 (73.5 %)** |
| C | 60/113 (53.1 %) | **84 (74.3 %)** |
| G | 59/113 (52.2 %) | **83 (73.5 %)** |
| H | 54/113 (47.8 %) | **72 (63.7 %)** |
| I | 57/113 (50.4 %) | **78/112 (69.6 %)** |

At 120 events, before the last fixes, the first pass (`5a21532`) gave 60.8–63.3 % on A, B, C and G, and the second pass (`428e11e`) gave 70.8–75.8 %.

Every replay and the final live run are above 61 %.

First pass (`OverviewPerspectivesExtractor`):
- A sentence closed by its attribution, without quotation marks: "…, the Ukrainian air force said.", "…, said Mayor Vitali Klitschko.", "…, according to the Gaza health ministry.", "…, Peskov told reporters on Monday." The tag may carry "in a statement", a weekday or date with an optional "(October 23, 2026)", a platform ("on X"), and continuations such as "…, adding" or "…, as". Full stops inside numbers ("3.48") and initialisms ("U.S.") do not end the sentence; a dateline ("PARIS: ") is not part of the statement.
- A quotation closed by a described speaker ("…," political scientist Dusan Spasojevic told DW; "…," said student representative Nathanael Combary), and "X told those gathered that …".
- Institutional speakers of two or more words ("interior ministry", "the club's sporting director").
- Wire copy: zero-width and soft-hyphen characters are removed before matching.
- Speaker cleanup: a speaker after a place ("In Karak, Major General … said"); a clause before the speaker, a trailing "meanwhile" or "on Saturday" and "Mr." alone are dropped; a statement of capitalized words only is a tag; reported speech does not start with "and", "but", "late", "earlier" or "a day after".

Second pass, after the 61 % review (general forms found in the 46 events still below two voices on run G's text, not tuned to particular events):
- Statements: a quoted phrase inside the sentence ("was “seriously wounded” but stable"), abbreviations ("Oct. 29", "Mr."), decimals in reported speech ("£8.9bn"), up to 300 characters; quotations up to 400 characters.
- Quotations closed by a named speaker with an appositive ("…," Jorge Hernández-Bernal, a planetary scientist at …, said in a press release), by "says X", "argued", "posted", "wrote", "told me", without requiring the sentence to end at the tag.
- Tags: a speaker with one appositive ("…, the mayor of La Verrière, Nicolas Dainville, told AFP."), initialisms and acronyms ("a U.S. envoy", "(CCI)"), continuations with "after" or "following", channels such as "in a letter", "in a press release", "in 2013", "said at a rally that"; "as many as" is a quantity, not a clause.
- Bare institutions name their speaker within the story: "the military said", "police said", "prosecutors said", "the ministry said", "the prefecture said", "the university said". "Officials", "authorities", "many", "some" and "others" stay vague.
- Not speakers: data sources and documents ("National Grid map", "a memo from…", "posts on Reddit", "the report"), aliases ("…, or FDFA"), ages ("Joao Paulo, 37"), cut-off fillers ("Google has long", "… at the"), a later segment opening with a preposition ("OCHA, in 2019"), a clause spanning "while" ("Police put their number at 13,000 while organisers"). An all-caps acronym is a name, not the relative word ("WHO chief Tedros").
- After the coordinator check: a position ends before a contrast clause with another party (", while organisers put the figure at…", ", whereas the SNS…"). A quoted fragment of a few words takes the clause that holds it: the sentence up to the quotation when the quote precedes its speaker ("The damage was estimated "at hundreds of millions euros", the CCI said"), and the rest of the sentence when it follows the speaker. A quotation ending in a full stop is not given to the speaker of the next sentence. A merged voice cites the passage its position comes from first.
- Not statements: a statement before its tag that itself reports a named speaker ("Clayton said in a memo…, according to a U.S. official"), a channel phrase reaching into the next sentence, and the rest of a sentence after a dashed aside ("– which Rio's City Hall said attracted about 1.1 million people –").

Precision. All labels are mine, pending Mars; row-by-row verdicts are in the private review notes.
- First pass: on run C, 81 perspectives were new or changed against run A. 75 are correct (92.6 %, Wilson 95 % 84.8–96.6 %). The first review counted 76; a sentence-ending quotation given to the next speaker (Orgeta Likaj) was mislabelled correct and is corrected here. All six errors are fixed in the final code.
- Second pass: two review rounds on the rows it added across the A, B, C and G texts. The first round found 10 defects in 70 rows (85.7 %): numbers cut at a decimal, a channel phrase reaching into the next sentence, a nested report, document and post speakers, a split UNESCO name, an alias, "Many", an official shortened to "Trump administration", and a statement running past an aside. All were fixed with regression cases. A coordinator check of the 72 rows against their full passages found 71 correct: one position carried the organisers' figure after "while", three positions were bare quoted fragments, and one merged voice cited the wrong passage. With the fixes above, the final set is **72 rows, all correct (Wilson 95 % 94.9–100 %)**, one borderline (a newspaper as speaker), no new critical kind. Every row the fixes changed was re-read: the five flagged rows, three contrast cuts, two widened fragments, and two removed defects. Of the 20 rows the second pass removes, 13 are the same voice with a cleaner speaker or position, 6 were defects, and 1 correct row of nested speech is lost.

## Claim verifier controls

The 10 October independent review replayed ten invented controls; six mismatched. The control sheet is private, so `testOverviewVerifierControls` rebuilds the six named failure kinds plus four ordinary controls. A control is accepted only when both deterministic gates on a drafted sentence pass: `OverviewClaimVerifier.verifyOverview`, then `OverviewQualityAuditor.auditClaim`.

| Control | Expected | Before | After |
| --- | --- | --- | --- |
| Renamed speaker ("Carney said" for "Ford said") | rejected | accepted | rejected |
| Actor taken for speaker ("Hamas said" for "the military said Hamas fighters attacked") | rejected | accepted | rejected |
| Reporting verb moved inside a quotation | rejected | accepted | rejected |
| Arrest substituted for summons | rejected | accepted | rejected |
| Number inside a longer number (14 for 140) | rejected | accepted | rejected |
| Unrelated speech elsewhere in the sentence | accepted | accepted | accepted |
| Word inside a word ("reinstated" read as "stated") | accepted | rejected | accepted |
| Speaker kept | accepted | accepted | accepted |
| "According to" kept | accepted | accepted | accepted |
| Plain fact | accepted | accepted | accepted |

Six of ten mismatched on the baseline; all ten match now. New verifier checks: the speaker named next to a reporting verb must be one the closest passage sentence names (`speakerMismatch`); a quotation holding a reporting clause must sit inside one passage quotation (`misquotedReport`); legal and physical actions (arrest, charge, summon, kill, …) must appear in the passage in some form (`actionMismatch`); numbers match whole (`containsNumber`); attribution verbs match whole words. The claim review below added two more: eight or more words copied from a passage quotation without quotation marks or a speaker (`quotationAsFact`), and unquoted first-person speech without a speaker (an extension of `isDetachedQuotation`, shared with the auditor).

`recordVerifiedOverview` and `createFallbackOverview` had no production caller and are removed. The opt-in generative path already runs the verifier and `auditClaim` on every drafted sentence before acceptance, and the app ships publisher-excerpt overviews, so wiring the verifier into `recordEventOverview` would check nothing new.

## Claim review

Thirty claims drawn at random (seed 547) from the accepted model overviews of a run, each checked against its cited passage. The criterion follows the 10 October review: supported by the exact cited passage; allegations and disputed assessments keep their reporting frame; ordinary reported facts need not keep every reporting wrapper. I did the review myself, so it is not independent of the implementation; it is pending Mars's acceptance.

| Run | Accepted overviews / claims | Critical | Unsupported | Finding |
| --- | --- | ---: | ---: | --- |
| C | 75 / 382 | 1 | 0 | An analyst's quoted assessment restated as fact → `quotationAsFact` |
| E | 72 / 364 | 1 | 1 | Unquoted first-person police statement ("we have confirmed…"); a dropped condition ("if Sullivan loses") as unsupported → first-person check |
| F (final code) | 69 / 352 | 0 | 1 | A claim citing a different passage than the one holding "to prevent a repeat of the violence" |

The final sample has 0 critical errors (Wilson 95 % upper bound 11.4 %) and 1 unsupported claim. Thirty claims cannot show a low error rate; they show that the two failure kinds found earlier no longer pass.

## Limits

- One window, from a library last refreshed on 25 October; later news may differ.
- One reviewer, not independent of the implementation. The claim and perspective labels are proposals pending Mars.
- Coverage counts perspectives as shown by the deterministic overview; it is not a precision measure.
- No installation, app launch or UI check; the generative path stays off in the app.
