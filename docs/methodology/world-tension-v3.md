# World Tension methodology v3 — history-aware reading

Issue #585 (epic L), 24 October 2026. Version 3 changes only what the sheet shows for a day; it does not change how a
day is assessed (v2, [world-tension-v2.md](world-tension-v2.md)) or how the v1 index is calibrated
([tension-calibration-v1.md](tension-calibration-v1.md)).

## Reading

For a day *d* with an accepted on-device assessment *A(d)* (0–100):

1. **Seven-day average.** Over the accepted assessments of the seven days ending on *d*, in day order, the
   exponentially weighted average with the v1 smoothing constant α = 0.25: *S* starts at the oldest assessment in the
   window and each later day sets *S = 0.25 · A + 0.75 · S*, rounded half away from zero. Days without an accepted
   assessment are skipped, never read as zero; unlike the v1 series, nothing older than the window carries over.
2. **Momentum.** 3 points for each consecutive daily rise of the assessed score ending on *d* (an assessment on the
   day before, and the one before that, each lower than the next), capped at 9.
3. **Reading** = round(*S*) + momentum, clamped to 0–100. The band name follows the reading.

A keyword estimate (shown when the on-device model cannot assess the day) is displayed as it is and never enters the
average: an estimate counts cues, not context, and must not pull the week's reading.

The sheet shows the reading in degrees with its band, the day's own assessment beside it when the two differ
("Today's assessment 44°, 7-day reading shown"), and the 30-day trend of readings. Selecting a day shows that day's
reasoning, which is the assessment's.

## Storage

The history stays in `news.sqlite3.world-tension-v2.json` beside the library, on device, and now keeps up to 90 daily
readings (30 before). Stored readings hold the assessed scores; the blend is computed when a history is shown, so a
changed constant never rewrites history, and nothing new leaves the Mac.

## Calibration

`script/evaluation/calibrate_tension.py` applies the same blend to the v1 historical sample
(`Tests/Fixtures/tension-corpus/historical-sample.json`), treating each day's calibrated index as that day's assessment:

| Day | Index | v3 reading | Note |
| --- | --- | --- | --- |
| day-01-major-conflict-escalation | 88.1 | 88 | first day of the window |
| day-02-major-earthquake | 46.4 | 78 | |
| day-03-civil-unrest | 30.1 | 66 | |
| day-04-diplomatic-coercion | 23.7 | 55 | |
| day-05-ceasefire-deescalation | 27.5 | 51 | one rise: +3 |
| day-06-routine-peaceful-day | 0.0 | 36 | |
| day-07-cyberattack | 11.3 | 33 | one rise: +3 |
| day-08-health-emergency | 24.1 | 29 | two consecutive rises: +6; the window now starts at day-02 |
| day-09-hard-negatives-negations | 0.0 | 15 | |
| day-10-hard-negatives-reversals | 54.2 | 27 | one rise: +3 |
| day-11-hard-negatives-historical-years | 0.0 | 18 | |

Insufficient and no-data days (12–14) have no index and no reading. The unit tests in `Tests/NewsTests.swift`
(`testWorldTensionSmoothing`) check the average, the momentum cap and the estimate exclusion on synthetic histories.
