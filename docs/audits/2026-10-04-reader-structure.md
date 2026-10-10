# Inline widgets and split-link cards — 4 October 2026

Fixes #246; Refs #93. Base: `03a0a8e`. Apple Silicon, Swift 6.4 / Xcode 27, deployment target macOS 15.

## Cause and change

Excluded related widgets still contributed navigation links while their text was absent from the denominator. Between two prose sections this penalized the complete article and let its first section win. Navigation scoring now ignores an excluded child only when prose siblings precede and follow it. Excluded menus at a container edge still penalize wrappers, preserving the earlier publisher fixes.

A prose-length teaser with category, headline and publisher links passed the citation heuristic when no one anchor dominated. Card/teaser class tokens, at least two distinct link destinations, and a majority of linked text now identify that widget for the existing reader exclusion path. Prose cards with short citations remain eligible. Anchor nodes never inspect their own combined text, avoiding recursion for links styled as cards. Card classification is computed once at immutable DOM construction, rather than repeated during ancestor scoring. No network, persistence or rendering behavior changes.

These remain conservative structural heuristics. Unmarked cards, different CSS tokens and widgets outside the flanked-prose shape are not a general semantic article-boundary solution.

## Verification

- Baseline/fixed regression comparison: the inline-widget article retains 6/8 blocks before and 8/8 after; the split-link fixture includes 16 blocks before and only its six article paragraphs after.
- Committed regressions also preserve a prose card containing citations and safely traverse a card-styled anchor. Existing heavily cited prose/list, wrapper, hidden-content and repetition checks remain.
- Reused all 96 publisher URLs from the #245 comparison. Fetched responses through `SecureHTTPClient.fetchArticleHTML`, then passed identical saved decoded HTML to unchanged and modified `extractFromHTML` implementations. Response hashes and per-URL counts are in [the comparison report](../benchmarks/2026-10-04-reader-structure.json); publisher bodies remain in a private temporary directory outside Git.
- 92 responses obtained: 90 extracted successfully in both versions; two short pages failed quality validation in both. Four URLs could not be fetched (two protected destination rejections, two insecure HTTP URLs); those are not parser coverage.
- Of 90 successful pages, 87 are byte-identical extracted block arrays. Two Quanta pages lose six repeated teaser headings each; one Onet page loses two author-profile labels. Inspection found no removed article prose and no newly included blocks. No new extraction failures.
- All 19 sampled pages from The Hill, Times of India, Dawn, DW and Guardian have identical extracted block arrays, including The Hill 12/14 blocks and Times of India 22/5 blocks. This fulfills the targeted comparison without assuming pages remain identical to 3 October.
- Sequential unoptimized parsing of the saved sample took 18.56 s on baseline and 21.16 s after the change (about 14% overhead); a discarded implementation took 33.49 s. These are one-run diagnostic timings, not a release performance budget.
- One full-suite attempt became idle without an assertion failure and was stopped; the unchanged compiled suite passed on retry. The final source is also checked by the mandatory full-suite commit hook.
- Full `./test.sh`, isolated arm64 `./build.sh`, signature verification and diff checks are recorded with publication.

## Limits

The temporary comparison driver is not a new maintained harness. The committed deterministic regressions reproduce both reported failures. This is one dated publisher sample and a parser comparison, not rendered UI, installation, VoiceOver or release acceptance. No installed app or real library/settings were changed. #102 and its sealed holdout are untouched.
