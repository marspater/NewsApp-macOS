# The Hindu reader access — 18 October 2026

Wave 1 follow-up for [#435](https://github.com/marspater/NewsApp-macOS/issues/435) and [#90](https://github.com/marspater/NewsApp-macOS/issues/90). Source: `aa795a4c041e61b60260c2324afcda8b6d9d56ab`, macOS 27.0.1 (26A434), arm64.

## Result

The feed and three sampled stories worked through the production networking and extraction services. Keep `the-hindu` in the catalog without a retirement or new reader-inaccessibility advisory. The plan calls this entry `the-hindu-international`; its actual ID is `the-hindu`.

```sh
NEWS_CATALOG_FEEDS=the-hindu NEWS_CATALOG_SAMPLE=3 ./test.sh --catalog-reader-access
```

Completed with exit 0:

```text
Catalog reader access: 1 feeds, up to 3 stories each...
the-hindu en readable 3/3 median words 695
```

This existing check uses `FeedFetcher` / `SecureHTTPClient.shared` for feed retrieval and `ContentExtractionPipeline.shared.extractArticleWithIdentity` for each story. It exercises the protected destination, response-size and reader-quality boundaries. No browser cookies or challenge bypass were used.

A separate plain `curl` request to the same feed at 04:28:04 UTC returned HTTP 200, `content-type: application/xml`, and `cf-cache-status: HIT`, with no `cf-mitigated: challenge` header. This header observation is supplementary; it does not substitute for the production-client check. Its first three links were:

- [Story 1](https://www.thehindu.com/news/international/many-dont-know-what-my-decision-is-donald-trump-on-sanctions-waiver-to-russia/article71599103.ece)
- [Story 2](https://www.thehindu.com/news/international/secretary-of-state-marco-rubio-comments-before-departing-to-uzbekistan-and-india/article71599016.ece)
- [Story 3](https://www.thehindu.com/news/international/saudi-arabia-intercepts-houthi-drones-as-egypt-weighs-defensive-support/article71599060.ece)

The production-client check fetches its own live feed snapshot and reports aggregate outcomes, not individual URLs; these URLs identify the supplementary feed snapshot. The later compiled-app refresh also recorded successful extraction from `www.thehindu.com`.

## Limits and checks

This demonstrates access on this Mac and network today, not uninterrupted availability elsewhere or a resolution of Cloudflare's policy. The 12 October HTTP 403 observation remains valid historical evidence.

`python3 script/evaluation/catalog_review.py`, the full `./test.sh`, and the arm64 ad-hoc `./build.sh` passed. No catalog, settings migration, fixture or production behavior changed. Private raw logs remain outside the repository in `/private/tmp/news-wave1-catalog.log` and `/private/tmp/news-wave1-hindu-headers.txt`.
