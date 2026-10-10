# Related-event live check — 10 October 2026

Refs #314. Source: `origin/main` at `32b1f7f` plus the measurement tooling in this change. This is a feasibility check before the wrong-link review, not an acceptance result.

## Tooling

- `./test.sh --related-live COPY DIR` runs `EventStoryRelation` on every event of a copied library. It writes a private `relations-private.json` with each proposed link and one hard control per linked event: the first earlier candidate in the window that shares a person, organization or local place but was rejected. It prints aggregate counts only, including the first condition that each in-window candidate fails.
- `NEWS_RELATED_RECLUSTER=1` first runs the production clustering pass on the copy (on-device judge, production budgets, clock at the library's last refresh). An older library then gets the events the current matcher would build.
- `python3 script/evaluation/relation_review.py sheet DIR` writes a blind reviewer sheet: links and controls are interleaved, and their kind stays in the run file. `report DIR` gives the wrong-link rate of proposed links and the share of controls judged related, both with Wilson 95% bounds. It rejects edited input columns and never replaces an existing sheet. Its self-check runs in `./test.sh`.

## Run

The installed library was copied read-only with SQLite's backup API; only the copy was migrated and written. The installed app has not refreshed since 8 October: the copy holds 1,611 articles, and about 600 of them were published in the last 72 hours of its window.

| Run | Events | Links | Candidates in the window |
| --- | ---: | ---: | ---: |
| Stored events (older app) | 103 | 1 | — |
| Re-clustered with the current matcher (2 passes, 44 events changed) | 108 | 0 | 1,024 |

The first condition that each in-window candidate fails, on the re-clustered copy:

| Stage | Candidates |
| --- | ---: |
| Different people and organizations | 671 |
| No person or organization found on one side | 305 |
| Shared actor, but no shared local place | 42 |
| Shared actor and place, but no pair meets every condition | 2 |
| Some pairs qualify, but below two-thirds support | 4 |

## Findings

- No wrong-link rate can be measured: the rule proposes 0–1 links in about 100 events, so there is nothing to label.
- The sample is too short for developing stories. Two days of news rarely contain an earlier, separate event of the same story with shared named actors.
- Most candidates fail on actors. The full-text search finds lexically similar events, but their named people and organizations differ. The 48 candidates that share an actor are the realistic near misses; 42 of them stop at the local-place requirement.

## Limits

- One library, last refreshed on 8 October, with no review labels.
- Feature extraction reads titles and feed summaries only.
- No installation, app launch, sealed corpus or holdout data was used.
