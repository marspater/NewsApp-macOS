# Plain-text feed content collapsed into one paragraph — 3 October 2026

Refs #115, #93. Base: `05beb0a`.

## Collecting problem pages

#115 asks for concrete wall-of-text pages. A scan collected them from live publishers: for each of the 49 catalog feeds, two current stories (98 in all) were resolved the way the reader resolves them. A stored feed document with publisher text is shown as is; otherwise the page is extracted; otherwise the feed text or description is split into paragraphs. The scan flagged stories with at least 1,200 characters of text and either a paragraph of 1,200 characters or more, or at most two blocks.

Of the 98 stories, 22 were shown from the feed document, 64 from the extracted page and 12 from the fallback. Four were flagged:

| Publisher | Shown from | Blocks | Longest block | Cause |
| --- | --- | ---: | ---: | --- |
| Економічна правда (2 stories) | feed | 1 | 2,211 / 2,952 | Structure lost in feed parsing, below |
| The Guardian (interview) | page | 34 | 1,354 | Publisher's own long answer paragraph |
| franceinfo (live page) | page | 43 | 1,222 | Publisher's own long entry |

Only Економічна правда lost structure.

## Cause

Економічна правда's RSS puts plain text in `content:encoded`, with blank lines between paragraphs and no HTML tags. `FeedXMLParser` treated it as HTML, where line breaks are whitespace, so extraction produced one paragraph. Because that feed document had publisher text, the reader showed it and never fetched the page.

Structure was therefore lost at extraction from the feed, not in persistence or rendering.

## Fix

Content that is not Atom XHTML, contains no `<` and does contain line breaks is now read as plain text, as Atom `type="text"` content already was. The feed text keeps its paragraph breaks, and no feed reader document is created, so opening the story extracts the publisher page. A rescan showed both stories from the page with 17–18 blocks and a longest block of 282–326 characters.

A regression in `testReaderParsingRegressions` parses a plain-text `content:encoded` item. Without the fix it yields one merged paragraph; with it, three paragraphs and no feed document.

## Also observed

Nine of the 12 fallback stories (The Hill, DW, ANSA, Times of India, Onet, IEEE Spectrum, Eater) failed page extraction with "Excessive repetitive text" and fell back to the feed summary. Two Africanews links use `http` and were blocked as insecure. These are not walls of text, but they hide the article; they are tracked separately.

## Limits

One scan of two current stories per feed. Pages a reader saw earlier, and feeds outside the catalog, were not covered. The scan harness was not committed; the regression test is.
