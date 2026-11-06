# Blind acceptance holdout (#737, 6 November 2026)

Route 3, stage 0. The 3 November holdout has been read many times, so it becomes the development set. A new set is held for one read, for acceptance, at the end. Its acceptance as a gate is still Mars's decision: v1 was not accepted, and v2 has `same` pairs too few for a strong strict-recall reading.

## Recipe

- Source: the installed app's library, opened `mode=ro` once for `.backup`; live file mtime 5 November 22:03:28. It was not written to or reopened.
- Copy: `~/news-eval/library-2026-11-06.sqlite3` (`0600`), integrity check ok, 2,830 articles, SHA-256 `2c739d87562b3c06ee88b484009a36e0988835e9a0192c180a3f455f6cdc4690`.
- Draw: main at 38613da, event tables wiped, `NEWS_RELATED_RECLUSTER=1 ./test.sh --related-live`, then `--review-pairs --holdout-candidates`.
- Window: 945 articles after the 3 November set's last article (2 November 16:52 UTC). Candidate pairs run from 2 November 21:32 to 5 November 20:44 UTC.
- Candidates: 189 pairs (70 borderline, 59 singleton, 60 fragments), none sharing an article with the 3 November set.
- Clock pin: `NEWS_HOLDOUT_NOW=1793915517`, the newest article plus one hour.
- Files, under `~/news-eval/holdout-2026-11-06/`, are private and never committed.

## Labels

| Version | Same | Related | Different | Close calls | SHA-256 |
| --- | ---: | ---: | ---: | ---: | --- |
| v1 | 63 | 30 | 96 | 45 | `cf40a54b378d36f9e52b8a16fa29dcb0e06dd62f367e12a9cf7388b9ab121e93` |
| v2 | 16 | 43 | 130 | 37 | `69812093e80d64bd89e3d6d17ed9b67540514da8e4623891d8bad82650270cd4` |

Mars's review of v1 found pairs labelled `same` only because they followed one trigger. v2 is a fresh pass by a new independent agent under this rule, and 61 labels differ (same to related 27, same to different 20, related to different 14):

- `same`: the same occurrence (same act, place, time, actors) reported twice.
- `related`: another act in the same unfolding story.
- `different`: only broad context is shared, or the leads do not settle a link.
- A shared trigger (an election result, a beta wave, a war) never makes `same`.

## Exposure

The set is less than fully blind:

- Mars reviewed v1 row by row.
- The orchestrating agent saw headlines and assessments of 11 rows in that review's message. It has read no other pairs or labels.
- The v2 labeller saw v1's aggregate counts in the README, not its per-row labels. It read leads cut to 420 characters; two articles have no lead.
- No matcher or model has been scored on the set.

## Limits

With 16 `same` pairs, one pair moves strict recall by about 6 points. Story recall has 59 true pairs. All pairs come from one library and one three-day window. A top-up would be a later draw sealed beside v2, never a relabel.
