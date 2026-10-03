# Event-boundary rules and fingerprint gate scope — 3 October 2026

Refs #102; the fingerprint is the #110 signal. Base: `1962779`, after the requested rebase. No production source, settings, library, app installation or matching threshold changed. Publisher text stays in Mars's private folders under `~/Documents`; nothing private is committed.

## Event boundaries

The v2 review packet left three boundaries open: the Spanish housing vote and rally, the failed execution and the resignation, and the separate Kyiv bridge strikes. All 29 documents in those families were read from the private packet, together with about 40 related captured items outside the manifest. The resulting rules are in the [corpus README](../../Tests/Fixtures/story-corpus/README.md#event-boundary-rules). This is a second pass by a coding copilot. It makes the rules explicit; it does not replace independent adjudication of the final corpus.

- **Spanish housing (holdout).** Friday's rejection of two housing decrees in parliament (2 documents) and Saturday's protests in more than 50 cities (9 documents) are different events: another actor, another act, another day (rules 4 and 5). Each headline matches its assignment. The vote reports mention protesters and the rally reports mention the vote only as background (rule 2). The capture also holds a 1 October pot-banging protest, which would be a third event, and a preview of the rally, which belongs to the rally.
- **Christa Pike (holdout).** The ventilator and critical-condition reports, the lawyers' accusations, the explainer and the radio portrait all belong to the failed execution of 30 September (rule 3). `pike-medical-aftermath` therefore stands for the failed execution and its consequences. Commissioner Strada's resignation on 3 October (5 documents) is a new act and a different event (rule 4). The governor's halt of executions would be another; it appears only as background.
- **Kyiv bridges (tune).** The Northern Bridge strike on the morning of 3 October (5 documents: damage, two injured, a video, closed traffic) is one event. The 2 October strikes on the Southern Bridge (a live page whose headline leads with them, rule 8) and the city's new bridge traffic rules during air alerts (2 documents) are two more (rules 4 and 5). The pontoon-crossing plan (`occurrence-0273`) is another decision.

All 29 proposed assignments follow the rules, so these families need no new manifest version. The other 34 multi-observation proposals also follow them (headlines of all 34, descriptions of the 16 with a possible boundary). For example, Trump's conditional threat stays in `flydubai-attack` (rule 3), Zelensky's decided refinery strikes are their own event (rule 4), and the Mekelle retreat and airport recapture are one offensive day (rule 5).

Points for the independent reviewer:

- `doc-0279` (Kyiv Independent): the URL slug says the key bridge was struck for a third straight day, while the captured headline says a second bridge was hit. The headline apparently changed after first publication; the captured description matches the Northern Bridge. Verify the page and its timestamp (rule 9).
- `doc-0286` (Kyiv Independent live page): confirm that the 2 October bridge is the Southern Bridge.
- `doc-1149` (franceinfo radio portrait): its article number is far below those of neighbouring 1–3 October articles. All captured franceinfo replay-radio items share that range, so the number reflects pre-assigned replay pages, not an earlier publication. Verify the broadcast date as for every document.
- Brazil: one report combines the US and Australian consular suspensions; check whether they were one joint action.
- Identical-headline negatives, still missing from v2, exist in the captures: recurring programme titles such as weekly science episodes and cartoon galleries. A few would cover that class in the next version.
- Singletons: the capture holds further reports of two proposed singletons (pontoon crossings: 3; Spanish floods: 1). They would add positive support. More reports of the rally or the resignation would deepen the concentration noted in the [v2 audit](2026-10-03-publisher-holdout-review.md): pair counts grow quadratically with event size, so a 13-document event would contribute 78 positive pairs.

## Fingerprint gate

### Targeted collection

`--corpus-capture` ran once more through the production protected networking, with the catalog plus 41 sibling feeds of 14 catalog publishers: 90 feeds, 2 failures, 2,926 items. The sample favoured sibling feeds that share a feed title (BBC, DW, Dawn, CBC, Ukrainska Pravda) or carry long text (Guardian, NOS, Dawn, Ars Technica, Politico, Ukrainska Pravda). The captures stay in `~/Documents/NewsFingerprintCapture` (directory 0700, files 0600). The 40 feeds that responded are frozen in [`fingerprint-feeds.json`](../../Tests/Fixtures/story-corpus/fingerprint-feeds.json).

Together with the earlier capture the private directory holds 3,021 unique observations: 1,713 tuning and 1,308 holdout. Of these, 1,089 are fingerprint-eligible: 164 tuning and 925 holdout.

- **Native tuning review:** 0 different-URL candidates. None of the 13 eligible same-URL copies shared a fingerprint, because sibling feeds of Times of India, France 24 and Politico carry different feed titles.
- **Structural check, both splits:** no two observations share host, feed title, title and timestamp under different raw links, even without the 400-character text threshold. A candidate needs all four, so none can exist in either split. Holdout hosts were counted only; no fingerprints, review sheets or labels were produced for them.
- **Identical headlines:** about 270 pairs share host and title under different URLs, mostly recurring programme titles such as weekly podcasts, galleries and bulletins. Their timestamps or feed titles differ, so the fingerprint keeps them apart.

### Decision

The gate no longer waits for 100 real different-URL matches. A signal that never fires has no measurable precision, so the old gate could neither pass nor fail. The sample is now every fingerprint-eligible holdout observation, which is every document a fingerprint could wrongly merge:

- `releaseGatePassed` requires the holdout split, every candidate adjudicated, and falsely merged observations at most 1% of eligible observations at the Wilson 95% upper bound. With no false merge, that takes at least 381 eligible observations.
- Precision ≥99% is still required once there are at least 100 candidates, so the earlier rule applies whenever it can be measured.
- Acceptance uses a new private directory of captures taken from 4 October on, with the catalog and `fingerprint-feeds.json`, reviewed once with `--corpus-holdout`. The 3 October captures were inspected for support counts on both splits and are not acceptance evidence.

This shows that text fingerprints are unlikely to merge distinct documents. It does not show that they find copies: on these feeds they found none, and GUID and canonical-URL identity carry deduplication. Making fingerprints useful, for example by not keying on the feed title, would be a tuning change. If that is tried, it belongs on the tuning split, and this gate would then guard it.

## Validation

- `StoryCorpus.captureGatePassed` takes the eligible count. `testCapturedFingerprintReview` covers the 381/380 boundary, a false merge needing more support, the precision rule at 100 candidates, unreviewed candidates and the tuning split. The report adds `falseMergeUpperBound95`.
- Full `./test.sh` regressions passed locally (arm64, macOS 15 target), including the v1 and v2 validators.
- `./test.sh --corpus-review` on the private directory (tuning only) produced the counts above; its report now prints `falseMergeUpperBound95` (0.023 on tuning, where the gate never passes). No holdout review was run, no app was built and no hosted CI result is claimed here.

#102 remains open. Next: independent adjudication of v2 (dates, singletons, the rules above), more varied positive events, real quarterly-report hard negatives, the tune-then-holdout event replay, and one fresh-capture fingerprint holdout review.
