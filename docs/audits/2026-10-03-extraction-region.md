# Extraction region and page furniture — 3 October 2026

Refs #242, #93, #115. Base: `05beb0a`.

## Finding

A live scan for #115 found 9 of 98 current catalog stories rejected as "Excessive repetitive text" and shown from the feed summary instead. On every one the repeated text was page furniture inside the extracted region: a repeated headline, related links shown twice, "To view this video please enable JavaScript", ad prompts, bylines.

The region itself was too wide. Container scoring adds 30 points per block and a fixed link-density penalty, so a page wrapper with dozens of short related links outscored the article body inside it:

| Page | Winning container (before) | Article body container |
| --- | --- | --- |
| The Hill | `<article>`: 32 blocks, 50% link text | `article__text body-copy`: 12 blocks, 4% links |
| Times of India | app wrapper: 101 blocks, 54% link text | `contentwrapper`: 34 blocks |
| DW | `<article>`: 34 blocks, 5% links (correct) | — only a repeated video placeholder |

## Change

- Container scores are multiplied by the squared share of text outside navigation links, after the existing penalties. Links inside prose-length paragraphs, list items and quotations (120 characters or more) are citations and do not count, so navigation-heavy wrappers lose to the body they contain while an article whose sections carry many inline citations keeps every section.
- Repeated labels (under 120 characters and no closing sentence punctuation: headlines, related links, buttons, bylines, video placeholders) lose every copy before validation, so the repetition check judges only prose, even on pages where labels outnumber it. After validation, repeated prose that is not a loop, such as a sentence that is also a pull quote, keeps its first occurrence, and the page is validated again.
- The validator rejects repetition only when repeated blocks make up half or more of the text, a syndication loop, instead of whenever two blocks repeat.

## Evidence

The same 96 live stories were extracted with `main` and with this change, minutes apart:

| | Stories | Unchanged | Changed | Fixed | Broken |
| --- | ---: | ---: | ---: | ---: | ---: |
| Page extraction | 96 | 62 | 24 | 10 | 0 |

Page-extraction failures fell from 14 to 4. Every change removed blocks; none added any. Long blocks (≥120 characters) that disappeared were author bios (TechCrunch, Dawn), an affiliate notice (TechCrunch), a copyright line (The Hill), Dawn's editorial-teaser sidebar, DW's "Mehr zum Thema" teaser, and a repeated headline (Variety). One was publisher text: Euronews's standfirst sits outside the body container and is no longer included. Fixed pages now read as articles: The Hill 12 blocks instead of 28, Times of India 22 instead of 93.

Regressions in `testReaderParsingRegressions`: a link-heavy wrapper around an article body (19 blocks before, 6 after), an article whose middle section is 60–70% citation links (all 13 paragraphs kept), repeated short furniture and a repeated pull quote (rejected before), and a mostly repeated page that must still be rejected. Each new assertion fails on `main`.

## Limits

One day of current stories, two per feed. Publisher standfirsts outside the body container can be lost; Onet and Euronews keep some in-body prompts ("Czytaj nas częściej w Google"). Four stories still fail extraction for other reasons (two `http` Africanews links, a short ON24 event page, one Times of India page).
