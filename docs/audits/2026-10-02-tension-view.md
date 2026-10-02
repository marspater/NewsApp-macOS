# News tension view — 2 October 2026

Refs #159, #99, #90. Base: `6322436`. Apple M5 / 24 GiB, macOS 27.0.1, Xcode 27.0, Swift 6.4.

## Change

- `TensionHistory.load` scores the most recent 30 UTC days from the stored panel corpus with the existing assessor and calibrated v1 weights. The series starts at the first day any panel feed reported, so without a historical corpus it starts on the day collection began. Later days without enough coverage stay in the series with a nil index, never zero.
- `TensionIndexView` is a separate "News Tension" window, opened from the tension section in Settings or the Window menu. It shows the methodology disclaimer and version, a Swift Charts history (7-day index as a line, daily index as points, provisional days dimmed, gap days shaded and breaking the line), the selected day's date, coverage (feeds and regions), daily and 7-day index, provisional state and its five largest event contributions, a keyboard- and VoiceOver-accessible list of days, and a link to the methodology. Without a scored day it says "Insufficient data", and tells the reader to turn on collection if it is off.
- No language model is involved; contributions are the calibrated event scores.

## Checks

- `testTensionMethodology` covers the history: days before collection are omitted, later thin and empty days stay as nil gaps, contributions are positive, ordered and named after a panel story, and there is no series before collection began. Full regressions passed.
- `build.sh` in an isolated staging copy compiled and signed the app.
- The view was rendered off-screen with temporary data in light and dark appearance, with data and in the empty state, and inspected. The real library and settings were not used.

## Finding: v1 calibration saturates on real days

To see real values, the 12 panel feeds were fetched once (2 October 2026, through the app's own networking) into a temporary database, clustered with `EventClusterer`, and scored with `TensionHistory`:

| UTC day | Coverage | Panel feeds | Unique events | Typed events | Raw score | Index |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 1 October | sufficient | 7 | 90 | 10 | 74.9 | 95.0 |
| 2 October | sufficient | 12 | 240 | 50 | 303.6 | 100.0 |

The v1 scale factor (S = 25) was fitted to a 14-day synthetic sample with about one event a day. A real day of the panel has dozens of typed events, so the index sits at or near 100 every day and cannot show change. Among the typed events were also clear false positives, such as a story about reducing the number of generals.

The view displays the numbers as calculated; it does not hide or rescale them. Per #99, release of the index depends on calibration. A new calibration needs a real historical sample: with collection turned on, the app stores the panel corpus, and a few weeks of it can be used to refit the scale and review classifier precision. That is tracked separately; this slice does not change weights or methodology.

## Limits

The live sample is one fetch, covering parts of two days. It shows the scale saturates; it is not a calibration. The view was not opened in the installed app; keyboard and VoiceOver use belong to the native QA pass (#155).
