# Card image placeholders and in-article figure fallback — 9 October 2026

Refs #312, follow-up to #290 and the [story curation and image audit](2026-10-09-story-curation-images.md). Measured on a fresh private copy of the same audited library (`/private/tmp/news-story-live/library.sqlite3`); the installed app and its library were not touched. Story titles, links and page text stay in the private output directory.

## Same denominator

`NEWS_IMAGES_NOW` pins `./test.sh --images-live` to the original measurement clock (`1791498686.49`, the `checked_at` of every 9 October lookup), so the 72-hour window and card grouping are unchanged. With the stored lookups, the harness reproduces the earlier result: **473 cards, 466 with a usable lead, 7 placeholders**. The private `placeholders-private.json` lists each placeholder card's members and lookup state.

## Placeholder classification

| Cards | Kind | Cause |
| ---: | --- | --- |
| 4 | single story, The Hindu | The page declares only the site-wide `og-image.png`. The recurrence rule clears it as a site default, and the page has no article photo in its markup. |
| 3 | single story, The New York Times | The page returns HTTP 403 with a bot challenge. The finder treats it as unreachable and retries on a later pass. |

**No clustered event card kept a placeholder.** All seven are single stories whose pages offer no relevant image to the app.

## Fallback result

When a page declares no usable image, `StoryImageFinder` now takes the first qualifying figure from the article body in the same 256 KiB prefix. It reuses reader extraction, so hidden, tiny, logo and newsletter-banner images are excluded. Extreme aspect ratios are excluded too, and `recordStoryImage` still clears an image that another story shares.

After clearing the four remembered misses and repeating the lookups at the pinned clock, coverage stayed at **466 / 473**. The four Hindu pages were read again; the NYT pages remained unreachable. The fallback added no image on this sample, because none of the placeholder pages has an article figure. Placeholders remain where no relevant image exists, as intended.

## Site-default finding

The repeat run exposed a pre-existing order dependence in `recordStoryImage`. When a second story declares the same image, both rows are cleared to `NULL`, and the shared URL is no longer recorded. A third story declaring it is stored again. On 9 October one Hindu story kept `og-image.png` this way and was counted as pictured. In the repeat run a different Hindu story kept it. On this denominator, coverage with a relevant image is therefore **465 / 473**, with 8 placeholders. Fixing this needs the cleared URL to be remembered, which is a storage change outside this slice. It is tracked in #338.

## Verification

- Mocked-HTTP regressions cover a figure-only page (the first qualifying figure is chosen, skipping a tracking pixel) and a furniture-only page (logo, newsletter banner, pixel and a 20:1 strip all yield none). The figure regression fails without the fallback.
- `./test.sh` passed. No installation or hosted CI result is claimed by these local checks.
