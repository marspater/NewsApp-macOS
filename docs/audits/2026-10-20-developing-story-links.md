# Developing-story links — 20 October 2026 (#314)

Aggregate evidence for showing "Earlier in This Story" links in event overviews. Private libraries, review sheets and publisher text stay local; only counts are recorded here.

## Method

`./test.sh --related-live` ran the production `EventStoryRelation` on read-only copies of two private libraries:

- **Collector:** the isolated relation collector library, frozen 17 October 2026 (504 events).
- **Current:** the daily-use library on 20 October 2026 (353 events).

`script/evaluation/relation_review.py sheet` produced blind sheets that mix proposed links with the hardest rejected candidates (controls). One reviewer (the coding agent, under Mars's standing delegation for pair review) labelled each pair `related`, `unrelated` or `unsure`; `report` computed the rates. Labels from the first collector run were carried over to identical pairs in later runs.

## Results

| Rule | Library | Links | Wrong / decided | Wilson 95% | Unsure |
| --- | --- | --- | --- | --- | --- |
| Before (two-thirds support, countries as places) | Collector | 42 | 7 / 36 (19%) | 10–35% | 6 |
| With common-actor discount | Collector | 25 | 0 / 22 | 0–15% | 3 |
| With common-actor discount | Current | 24 | 1 / 23 (4%) | 1–21% | 1 |

Every wrong link before the change shared only a ubiquitous actor (the US president or administration). The shipped rule ignores people and organizations named in more than 5%, and at least ten, of the preceding week's events when looking for a shared actor; the minimum does not change these runs (5% of 353 or 504 events exceeds ten). Combined, 1 of 45 decided links was wrong.

Controls judged related were 13 of 16 (collector) and 9 of 12 (current): recall among near misses stays low by design. The section shows at most three direct links per event and never chains them.

## Limitations

One reviewer; labels are judgements, not ground truth. Two overlapping October 2026 news weeks. Controls are the hardest rejections, not a recall sample.
