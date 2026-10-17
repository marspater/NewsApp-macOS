# Release simplification: core validation — 17 October 2026

Scope: Codex matching, visibility, refresh energy and Briefing slice of [#439](https://github.com/marspater/NewsApp-macOS/issues/439). Gemini's publisher-excerpt slice is separate and not included in these results.

## Existing labeled regression data

The matcher was frozen before scoring. Matcher version 5 uses the production 2,000-article budget, no event judge, no embedding promotion and unchanged standard thresholds. The final tune and English holdout replay used the same compiled binary. The only correction following the earlier tune run was an article-budget guard and its regression; no threshold or label was changed. The original corpus SHA-256 is `868c62a0ec973d07aa2ca3d63de8623fbe866359d1e082fadacd7bd456acf2a0`.

| Existing split | Articles | TP | FP | FN | Precision (Wilson 95%) | Recall (Wilson 95%) |
| --- | ---: | ---: | ---: | ---: | --- | --- |
| English tune | 105 | 26 | 3 | 67 | 89.7% (73.6–96.4%) | 28.0% (19.9–37.8%) |
| English holdout | 49 | 12 | 1 | 26 | 92.3% (66.7–98.6%) | 31.6% (19.1–47.5%) |

Each split has one impure predicted event. Neither split meets the 97% point-precision target. These reused datasets provide regression evidence, not fresh independent acceptance. A narrower deterministic predicate is not sufficient to close #307, and lower recall is a material tradeoff. Do not tune against this held-out outcome.

The original #409 export (88 articles / 638 labeled positive pairs, provisional labels) was not recovered. Public aggregate results cannot reconstruct the replay input. That comparison remains incomplete.

## Backup-only upgrade

The relation collector was disabled and unloaded; job and process absence were checked. Its files remain intact. A consistent SQLite backup contained 4,303 articles and passed integrity verification (SHA-256 `09096a400195ea2bdb10ca5564eeeedc9fa14ee3ffa4cee9add53213bdecbd23`). Validation used copies only. The original library was not migrated or repaired.

Both the initial and final-source upgrade checks converged after 1,894 processed articles, 460 moved members, 5 newly formed events, 26 admissions and 58 fragment merges across two changing passes. A third pass and another repeat made no changes. Each pass remained below the 2,000-article budget and made zero judge calls. This is automated migration evidence, not a precision estimate for unlabeled data.

Article rows, read/save state, ratings, historical expiry tombstones and feed links were unchanged in both checks; 225 inactive archived events and their memberships were unchanged. SQLite integrity was `ok`, with zero foreign-key violations.

## Validation boundaries

Full offline regressions, the SwiftPM app build, 160 native UI checks and an isolated arm64 app build with strict signature verification passed. The final guard has a dedicated regression for a partner outside the fetched batch. One final-suite attempt became idle in the existing socket-boundary regression and was stopped after sampling; rerunning the same binary with PTY output passed the complete suite. That interrupted attempt is not a passing check. No installed app, OS-notification delivery, hosted CI or release acceptance is established by these checks. #314 remains parked, #334 deferred, and #264/#268 untouched.
