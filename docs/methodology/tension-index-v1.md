# News tension — methodology v1

Status: experimental, uncalibrated, not shown in the app. Issue [#157](https://github.com/marspater/NewsApp-macOS/issues/157) under phase I ([#99](https://github.com/marspater/NewsApp-macOS/issues/99)). Code: [`Sources/Intelligence/TensionMethodology.swift`](../../Sources/Intelligence/TensionMethodology.swift), which must change together with this document and bump `TensionMethodology.version`.

## 1. What the indicator is

News tension describes **what a fixed panel of international news feeds reported** on a day: how many unique events of conflict, violence, coercion, unrest and emergency the panel covered, how large their reported human toll was and whether the reporting describes escalation. It is a property of the corpus.

It is not a measure of world danger, risk, threat level or the state of any country. It inherits the panel's editorial choices, its publishers' home regions, the language it is read in and the feeds' own selection of stories. A quiet day in the panel is not a peaceful day in the world, and a personal subscription mix is never presented as a global score. User-facing copy uses `TensionMethodology.disclaimer`.

Version 1 defines the corpus, the observation windows, the coverage rule and a deterministic classification. It defines **no score**: weights, aggregation and smoothing are set from a historical sample in [#158](https://github.com/marspater/NewsApp-macOS/issues/158), and a value may not be shown before that calibration. The view is [#159](https://github.com/marspater/NewsApp-macOS/issues/159); collecting panel feeds the reader has not subscribed to requires the explicit opt-in of [#160](https://github.com/marspater/NewsApp-macOS/issues/160). The rest of the product does not depend on any of it.

## 2. Panel

Twelve general-news feeds from the starter catalog (verified 2026-10-01), all in English, recorded with their catalog ID and exact URL. A changed catalog entry, an added or removed member or a changed region assignment is a new methodology version.

| Region | Catalog ID | Publisher |
| --- | --- | --- |
| Europe | `bbc-world` | BBC News · World |
| Europe | `guardian-world` | The Guardian · World |
| Europe | `dw-english` | DW · Top stories |
| Europe | `france-24` | France 24 · English |
| Europe | `euronews` | Euronews · News |
| North America | `cbc-world` | CBC News · World |
| Middle East & North Africa | `al-jazeera` | Al Jazeera English |
| Middle East & North Africa | `arab-news` | Arab News |
| South Asia | `the-hindu` | The Hindu · International |
| South Asia | `dawn` | Dawn |
| East & Southeast Asia | `cna` | CNA · World and Asia |
| Sub-Saharan Africa | `africanews` | Africanews |

Selection rule: general or international desks, one language for every cue in §5, publishers from as many regions as the catalog allows. Topic feeds (politics, business, technology) and single-country outlets covering mainly one conflict (the Ukraine set) are excluded so that the panel does not measure one story. `times-of-india` is left out as a second Indian outlet whose feed is mainly domestic.

Known bias, stated rather than hidden: five of twelve members are European, and Latin America, Oceania and Central Asia have no member at all. The unique-event unit (§4) stops five outlets reporting one event from counting it five times, but events that only European outlets report are still more likely to enter the corpus. Every assessment lists the reporting feeds and regions so the bias stays visible; calibration may decide to cap per-region contributions. Regions are the publishers' home regions, not where the reported events happened; v1 does not geolocate events.

## 3. Time windows and coverage

- **Observation day:** a UTC calendar day, the same span for every reader.
- **Assignment:** an article belongs to the day of its publication date. Undated articles (the unknown-date sentinel) never belong to a day, because their ingestion time measures our fetching, not the publisher.
- **Reporting feed:** a panel feed that delivered at least one dated item published that day and stored in the library.
- **Comparable day:** at least 7 of the 12 panel feeds reported, from at least 4 of the 6 panel regions — a majority of each. Fewer is *insufficient data*; no reporting feed at all is *no data*. Neither is ever zero, and neither may be interpolated as a value.
- **Provisional:** a day stays provisional for 24 hours after it ends, while late feed items and event clustering can still change it.
- **Smoothing:** none in v1. A trailing window, if any, is a calibration decision.

Without a historical corpus the series starts on the first comparable day the reader's own library contains.

## 4. Unit: the unique event

Panel articles of a day are grouped by their event (schema v13 `event_members`, built by the deterministic event clustering); an article clustering did not group is its own event. Each event counts once that day however many panel feeds reported it, and records which feeds and regions did. Articles from feeds outside the panel do not enter the corpus even when they belong to the same event. An event spanning several days contributes to each day on which a panel article about it was published, classified from that day's facts only.

Clustering precision limits the indicator: a false merge hides an event and a missed merge double-counts one. The clustering thresholds are evaluated separately ([#102](https://github.com/marspater/NewsApp-macOS/issues/102)).

## 5. Classification from anchored facts

Evidence is the publisher's own text: prose passages of the stored reader document, else the stored full text, else the feed summary (the passage rules of the event overview). Facts are sentences extracted deterministically from those passages and validated as verbatim quotes of them (`PassageFactExtractor.deterministicExtract`). Model-extracted facts are excluded in v1 because their output changes with the operating system's model. Classification reads only each fact's verbatim quote — never a model restatement, a headline alone or a generated overview — so the same stored text gives the same result.

Cues are English words and phrases matched as whole words after lowercasing (`riotous` is not `riot`). A cue with `no`, `not`, `never`, `without`, `rejected`, `rejects`, `refused`, `refuses`, `denied`, `denies` or `ruled` among the three words before it does not count. The cue lists are in code and are part of the version.

**Type.** Seven types: armed conflict, terrorism, civil unrest, coercion (sanctions, blockades, mobilisation, weapons tests), disaster, health emergency, cyberattack. Each fact supports every type whose cue it contains; the event's type is the one with most supporting facts, ties broken by that declaration order (an order, not a weighting). An event without any cue has no type: it counts toward the day's unique events but not toward tension. A bare "war" is not a cue, because trade, price and culture wars would dominate it.

**Scale.** Two orders of magnitude — deaths, and other people harmed (injured, displaced, evacuated, missing, hospitalised, homeless) — each from the largest figure any fact reports: explicit numbers attached to a harm word ("at least 12 people were killed", "killing 30", "the death toll rose to 1,200", "1.5 million displaced") and quantity words ("dozens", "hundreds", "thousands", "millions"). Bins: not reported, 1–9, 10–99, 100–999, 1,000 or more. Four-digit numbers from 1900 to 2099 without separators are read as years. Conflicting figures are not reconciled; the largest anchored figure is recorded with the facts that reported figures, including historical comparisons a fact may quote.

**Escalation.** What the day's facts say explicitly, not an inference from changing figures: *escalating* when a fact carries an escalation cue (escalated, intensified, renewed fighting, mobilised, declared war…), *de-escalating* for a de-escalation cue (ceasefire, truce, peace talks, withdrawal, prisoner exchange, lifted curfew…), *mixed* for both, otherwise no signal. A de-escalation cue followed within three words by collapsed, failed, broke, violated, ended, stalled or faltered does not count.

Every classification records the methodology version and the IDs of the facts behind its type, figures and escalation, so an explanation can describe known contributions without inventing them. A language model may phrase such an explanation; it never chooses a type, a magnitude or a score.

## 6. Calibration hand-off (#158) and opt-in collection (#160)

Calibration receives, per comparable day, the unique events with type, the two magnitudes, escalation, reporting feeds and regions, and the fact IDs. Weights, aggregation and smoothing have been calibrated on the frozen 14-day historical sample corpus ([#158](https://github.com/marspater/NewsApp-macOS/issues/158)) and normative calibration parameters are documented in [`docs/methodology/tension-calibration-v1.md`](tension-calibration-v1.md).

Calibrated parameters (`TensionWeights.calibratedV1`):
- Type weights: armed conflict (10.0), terrorism (8.0), disaster (6.0), civil unrest (4.0), coercion (4.0), health emergency (4.0), cyberattack (3.0).
- Scale factor: $S = 25.0$ in $100 \times (1 - e^{-\text{raw}/S})$.
- Smoothing: 7-day trailing EMA ($\alpha = 0.25$). Missing or insufficient days are never treated as zero and do not corrupt the series.
- Opt-in collection ([#160](https://github.com/marspater/NewsApp-macOS/issues/160)): fetching the 12 panel feeds beyond user subscriptions requires an explicit toggle in Settings (`tensionCollectionOptIn`, default `false`). Unread notifications are strictly isolated to user-subscribed feeds.
- Retention: history is rebuilt from stored articles, so while collection is on, stories delivered by panel feeds are exempt from the 24-hour expiry of waiting minor stories ([#310](https://github.com/marspater/NewsApp-macOS/issues/310)). They still wait out of the reading views. Saved/read rules and the other cleanup paths are unchanged.

## 6a. Presentation and explanation (#159)

The app shows the latest 7-day reading as whole degrees and names its range: Calm below 20, Mild from 20, Warm from 40, Hot from 60 and Boiling from 80 (`TensionLevel`). The bands are labels for display; they never feed back into scoring. The reading is rescored after every feed refresh and when a new UTC day begins.

The explanation paragraph is built from `TensionBriefFacts`: the reading and band, the change since the previous scored day, the mean of the scored days shown (with at least three), whether the day is provisional, and up to three largest contributions with their classified type, magnitude bins, escalation, panel-feed count and one panel headline. Without the on-device model (AI off, Low Power Mode, thermal pressure or no Apple Intelligence) the paragraph is assembled from those facts directly. With it, the model rewords the same facts; headlines are framed as untrusted data, and a draft is discarded for the deterministic text when it does not state the reading, contains a number absent from the facts, is not a single short paragraph or reads as a refusal. Generated text is labelled as written on device and cannot change the score.

## 7. Versioning

`TensionMethodology.version` changes with any change to the panel, windows, coverage rule, evidence or fact rules, cue lists, figure rules or classification logic. Values from different versions are never drawn on one series; history is recomputed from stored text under the new version or the series restarts. This document and the code are changed in the same commit.

## 8. Known limitations of v1

- English only; non-English panel candidates wait for per-language cue lists.
- Feeds deliver a limited number of recent items, so a feed refreshed rarely can miss part of a day; the coverage rule only partly compensates.
- Feed summaries are short; events whose panel articles were never opened in the reader are classified from summaries alone.
- Lexical cues miss paraphrase and can misread irony, quotations and hypotheticals; figures before nationality nouns ("40 Palestinians were killed") are not read.
- Publisher home region is not event location.
