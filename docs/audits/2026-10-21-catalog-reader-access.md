# Catalog reader access — 21 October 2026

Live run of `NEWS_CATALOG_SAMPLE=5 ./test.sh --catalog-reader-access`: the newest five stories of every catalog feed, opened through the production reader extraction (`extractArticleWithIdentity`) over the protected client. English feeds only below; parked languages are out of release scope. Stories differ between runs because feeds rotate, so word counts compare runs, not identical pages; identical-page comparisons are listed separately.

## Before and after reader v9

| Feed | Before (`origin/main` 1c1f05e) | After (reader v9) |
|---|---|---|
| africanews | 0/5 | 5/5, median 309 words |
| ars-technica | 5/5, median 52 words (author bio) | 5/5, median 548 |
| cna | 1/5 | 5/5, median 576 |
| ieee-spectrum | 1/5 | 5/5, median 939 |
| nasa | 5/5, median 71 (first paragraphs only) | 5/5, median 447 |
| science-news | 0/5 | 5/5, median 656 |
| variety | 5/5, median 56 (first paragraph only) | 5/5, median 457 |
| france-24 | 0/5 (403 that run) | 5/5, median 449 |
| politico | 0/5 (subscriber-only and empty) | 4/5, median 198 |
| the-hill | 0/5, HTTP 403 | 0/5, HTTP 403 |
| bbc-science, eater, lifehacker | 4/5 each | unchanged: one short page each, one timeout |

The other 26 English feeds read 5/5 in both runs.

## Causes fixed

1. `HTMLDOMBuilder` skipped `<script>` by counting nested `<script` opens. Inline JS such as `document.write('<script …>\x3C/script>')` never balanced, so the rest of the page vanished (Africanews, CNA, Science News, Ars Technica, IEEE Spectrum). Script and style now end at their first closing tag.
2. The SwiftSoup repair of explicit publisher bodies judged each element before adding its children. An empty `<p>` reads as boilerplate, so every paragraph of `.entry-content`, `.article__body` and similar bodies was dropped (NASA, Africanews). The converted node is now judged with its children.
3. Variety's body sits in a `pmc-paywall` metering wrapper that was removed as furniture. A paywall-classed wrapper holding two or more paragraphs of 80+ characters is kept.
4. Ars Technica's `x-cloak` text-size panel and form controls (`select`, `textarea`) read as story text. Both are now hidden.
5. RebelMouse `.body-description` bodies (IEEE Spectrum) lost to the site menu; they are now an explicit body.

Making explicit bodies work exposed two follow-on cases, both fixed in the same change:

- BleepingComputer's only `.article-body` is a sponsor box. An explicit body must now hold at least 40% of the scored prose.
- The Guardian's media and standfirst sit beside its explicit body. Lead figures and one paragraph from a standfirst-marked element just before the body are kept.

Dawn's "Email Story" and "Join our Whatsapp Channel" lines are now boilerplate.

## Identical-page checks (old vs new extractor on the same saved page)

- The Hindu: the old text mixed in related-story cards and image credits and missed the lede; the new text is the article body (829 → 488 words on one page).
- Quanta: the old text included page furniture; the new text is `post__content` (1,690 → 1,017 words on one page). A podcast transcript stays at about 9,800 words in both.
- DW, Dawn, Times of India, BleepingComputer: identical word counts.
- The Guardian: lead figure kept on 3 of 3 pages, standfirst on 2 of 3.

## Not fixed

- The Hill answers HTTP 403 to the app's client on every story. It is a reader-blocking feed under the free-and-open rule; retiring it is in the same PR as the FT retirement.
- Politico: one of five stories is a short subscriber page.
- CNA keeps an "(Updated: …)" line near the top of the body.

Stored documents from earlier readers re-extract on open (reader document v9).
