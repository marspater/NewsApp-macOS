# Reader structure lost on refresh, and a static accessibility pass — 2 October 2026

Refs #115, #123, #93. Base: `7cd875a`.

## #115: where the structure was lost

This was traced in code, not from a reported page. The path matches the symptom: an article that read well once later shows as uniform paragraphs.

1. **Extraction.** A summary-only RSS item with `media:thumbnail`/`media:content` (the shape of BBC feeds, and the `mediaRSS` fixture) produces a v4 `ReaderDocument` with image candidates and **no blocks**. If `content:encoded` fails the quality gate or Atom content is plain text, the item stores the same image-only document with flattened feed text.
2. **Persistence.** Opening the article extracts the publisher page: a v4 document with headings, lists, quotes and figures, plus its body text. On the next refresh, `upsertArticles` set `reader_document = coalesce(excluded.reader_document, …)`. The item's image-only document is non-null, so it replaced the structured one. The body survived because the item had no content.
3. **Rendering.** `ensureContentExtracted` accepted any v1–v4 document with stored text as ready, so it never fetched again. `articleContentParagraphs` found no blocks and rendered `fullContent` through `redactAndSplit`: every heading, list item and quote became a body paragraph, and figures and inline formatting were gone.

The same gate also showed a rejected feed teaser with media as the complete article and never fetched the page.

Reproduced on SQLite 3.45 with the previous clauses: after a media-only refresh the row kept `content = 'Extracted body'` with `blocks = []`.

## Fix

- `ReaderDocument.hasPublisherText`: true when there is at least one non-figure block.
- `upsertArticles`: if the incoming item has no publisher text, a stored document that has text is kept, together with its content. The stored side is checked with the JSON1 functions the database already uses, and the incoming side is bound as `?17`. Unchanged:
  - feed media still refreshes a media-only document
  - feed publisher text still replaces both document and content
  - an item without a document still keeps the stored content
  - invalid stored JSON never blocks a refresh
- Reader gate: a stored document stands in for extraction only if it has publisher text. Rows already damaged are therefore fetched again on open. Offline, they show the fallback with their previously saved text.

No schema change and no new heuristics. Publisher headings are never invented.

## #123: static accessibility pass on `ArticleDetailView`

Changed:

- **Headings.** The headline is `.isHeader` + `.h1` and selectable. Publisher headings are `.h2`, subheadings `.h3`.
- **Source line.** The source, date and reading-time line is one accessibility element ("BBC News, Oct 2, 2026, 4 min read"). Before, it read as five elements, including the "·" separators, with the source in capitals.
- **Citation highlight.** The banner combined its dismiss button into the passage element. The passage is now one element and the button a separate control labelled "Dismiss citation highlight".
- **Increase Contrast.** These return to full strength:
  - softened text (fallback paragraphs, summary)
  - tertiary labels, which use secondary
  - hairline control and card borders, which use primary at 30%, as in `EventOverviewReaderView`

Found, not changed (needs a Mac to confirm):

- **Focus rings.** The reader root uses `.focusable().focusEffectDisabled()`. Per the API documentation, an outer `focusEffectDisabled` also governs descendants, so keyboard focus on the reader's buttons (Retry, Open Web View, External, the summary disclosure, dismiss) may show no ring. Moving the key handling to keep shortcuts and the root's focus behaviour needs a native check first.
- **Selection.** Selection is per block: each paragraph is its own selectable `Text`, so a selection cannot span paragraphs. Copy within a block, including inline strong, emphasis, code and links, is the check that remains.
- **Links.** Links inside paragraph text are not Tab stops. VoiceOver reaches them through the element's links.
- **Reduce Motion.** The source reader has no custom animations; navigation and the disclosure are system-driven. `EventOverviewReaderView` and the cards already honour Reduce Motion. Outside the reader, the list header's sidebar toggle (`ArticleListView`) and `SidebarView` animate unconditionally.

## Verification

The authoring environment was a Linux container without a Swift toolchain. Its network policy blocked publisher hosts and swift.org. Nothing was compiled, run, installed or fetched.

- The upsert clauses ran on SQLite 3.45.1 (Python) against nine scenarios: media-only insert, media update, media-only and teaser refresh over extracted structure, no-document refresh, publisher-text replacement, invalid stored JSON, figure-only stored document. All passed. The previous clauses reproduced the loss.
- Changed Swift files parse with tree-sitter-swift. The remaining parser errors (one in `ArticleDetailView`, three in `Tests/NewsTests.swift`) are pre-existing false positives, identical on the base.
- `python3 script/evaluation/evaluate.py` and `git diff --check` passed.
- New regressions in `testReaderPhaseC` (full suite and `--story-regressions`) cover:
  - feed media alone has no publisher text
  - media-only document refresh
  - extracted structure and body surviving media-only and teaser refreshes
  - feed publisher text still replacing both

Compile and test results come from macOS CI on the PR.

## Remaining

- #115: concrete problem pages from real reading still need tracing. If they persist after this fix, the cause is elsewhere.
- #123: on a Mac, with isolated data:
  - copy within a block
  - keyboard-only traversal, including the focus-ring finding above
  - a VoiceOver interaction pass, including the changes above
  - OS Increase Contrast and Reduce Motion
