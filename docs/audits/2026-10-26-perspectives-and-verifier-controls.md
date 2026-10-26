# Perspectives coverage and claim-verifier controls — 26 October 2026

Refs #547 (epic L, #573). Source: `mars/l-547-perspectives`, stacked on #650. Sample: the installed library (6,400 stories, last refreshed 25 October 18:05 UTC), copied read-only with SQLite's backup API into a private temporary directory. Every run used `./test.sh --overviews-live` with `NEWS_OVERVIEWS_EXTRACT=1` (publisher text fetched for each event, as in production), a 72-hour window ending at the run, and model drafts for every multi-source event. Passages, model records and the claim sheet stay in the private run directories; only aggregates are recorded here.

## Perspectives

| Run | Code | Events | Two or more | One | None |
| --- | --- | ---: | ---: | ---: | ---: |
| A (baseline) | #650 tip (`4d968f2`) | 134 | 67 (50.0 %) | 36 | 31 |
| E (final perspective code) | this PR | 131 | 80 (61.1 %) | 28 | 23 |
| F (final code) | this PR | 130 | 63 (48.5 %) | 36 | 31 |

Target: at least 60 % of multi-source events with two or more perspectives. The 10 October figure (25/55, 45 %) came from a different window. Runs E and F share the same perspective code; F changed only the claim verifier. F's publisher fetch was degraded: it stored 168 publisher texts against 222 in the baseline and 234 in run E, with 19 fetches cut at the deadline, while other sessions were loading the Mac. Its coverage reflects the thinner input, not the code; on F's own stored text the baseline code reaches 55/128.

Each run fetches publisher pages again, so its input differs slightly. To compare code on the same input, the pattern changes were also measured on the publisher text stored by three runs:

| Stored text from | Before | After |
| --- | ---: | ---: |
| A | 66/133 (49.6 %) | 79/132 (59.8 %) |
| B (intermediate) | — | 82/132 (62.1 %) |
| C (intermediate) | — | 81/132 (61.4 %) |
| F (degraded fetch) | 55/128 (43.0 %) | 63/128 (49.2 %) |

The change adds 8 to 13 events with two or more perspectives on the same input. Whether a run clears 60 % depends on how much publisher text it fetched: the complete fetches reach 59.8–62.1 %.

Changes (`OverviewPerspectivesExtractor`):
- A sentence closed by its attribution, without quotation marks: "…, the Ukrainian air force said.", "…, said Mayor Vitali Klitschko.", "…, according to the Gaza health ministry.", "…, Peskov told reporters on Monday." The tag may carry "in a statement", a weekday or date with an optional "(October 23, 2026)", a platform ("on X"), and may be followed by "…, adding", "…, as" and similar continuations. Full stops inside numbers ("3.48") and initialisms ("U.S.") do not end the sentence. A dateline ("PARIS: ") is not part of the statement.
- A quotation closed by a described speaker: "…," political scientist Dusan Spasojevic told DW; "…," said student representative Nathanael Combary.
- "X told those gathered that …": a lowercase audience after "told".
- Institutional speakers: an institution or office as the head noun of a speaker of at least two words ("interior ministry", "the club's sporting director"). A bare "police" or "the ministry" stays vague, as does "authorities", which is now listed with "officials".
- Wire copy: zero-width and soft-hyphen characters are removed before matching; they had split words inside the patterns.
- Speaker cleanup: a speaker after a place ("In Karak, Major General … said") is taken from after the comma instead of being rejected; a clause before the speaker ("Kenya has recorded a second Ebola death, the health ministry") and a trailing "meanwhile" or "on Saturday" are dropped; "a figure the UN" is "UN"; "Mr." alone is not a speaker; a statement made only of capitalized words is a speaker tag, not a statement.
- Reported speech no longer takes a statement that starts with "and", "but", "as", "late", "earlier" or "a day after".

Precision: I reviewed the perspectives that the new code added or changed against run A, on the output of runs B and C, as a copilot review pending Mars's acceptance. The criterion follows the 10 October review: the participant identifies the actual speaker (extra descriptive words tolerated), and the position is something that speaker said. The errors the run B review found were fixed before run C and are covered by regression cases: a sentence and speaker swapped by "…, said American tariffs …", clause fragments as speakers, datelines inside statements, "Mr" as a speaker, statements starting mid-clause after a tag, and "figure the UN". On the run C output, 81 perspectives were new or changed against run A; besides the cases fixed after it, the remaining defects are cosmetic speaker text ("real name Stephen Yaxley-Lennon", "Visiting Hebron, Netanyahu"), with the speaker still identified, and one time-clause statement ("a day after a Palestinian attack…") that the baseline already showed and the final code rejects.

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
