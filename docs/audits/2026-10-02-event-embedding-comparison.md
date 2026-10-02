# Native embeddings against deterministic event matching — 2 October 2026

Refs #127, #94, #102. Base: `1ecdbca`.

## Why

#127 asks whether native embeddings improve event matching over the deterministic features, judged on the #102 holdout, with language support checked per language and without assuming that vectors from different languages are comparable. The holdout is parked, so the adoption decision cannot be made yet. This slice builds the measurement so that it runs in the same pass as the clustering gate once the labeled corpus exists.

## Implementation

Evaluation-only code in `Tests/NewsTests.swift`. No production source, schema or behaviour changed; `EventMatcher` still uses no embeddings.

- `EventEmbeddingComparison` embeds each article's title and first 600 plain description characters (the text `EventFeatures` reads) with `NLEmbedding.sentenceEmbedding` for its detected language (`EventMatchKey.language`, as in the clustering report).
- **Language support:** each detected language reports its article count and the sentence-embedding dimension, or that the system has none.
- **Comparable pairs:** both articles in the same detected language, within the matcher's 36-hour window, and both with a vector. Labeled or deterministically linked pairs left out are counted by reason: unknown language, cross-language, outside the time window, no sentence embedding. Cross-language pairs are never compared, even when both languages have a model.
- **Scored on the same pairs, overall and per language:**
  - **deterministic:** the clusterer's replayed memberships, as in the existing report
  - **embedding:** cosine distance at or below the cutoff
  - **veto:** a deterministic link that the embeddings also accept (can only remove links)
  - **rescue:** a deterministic link or an embedding link (can only add links)
- **Cutoffs:** the tune split sweeps cosine distances 0.2–1.0. The holdout is never swept: it is scored only at the single cutoff chosen on tune, passed as `NEWS_EMBEDDING_THRESHOLD`; without it, only deterministic metrics and support are printed.

Run: `NEWS_EVENT_CORPUS=corpus.json ./test.sh --event-corpus`, then `NEWS_EMBEDDING_THRESHOLD=<cutoff> NEWS_EVENT_CORPUS=corpus.json ./test.sh --event-corpus --corpus-holdout`.

## Limits

- Scores are pairwise. They skip the whole-event check that stops A≈B≈C chains, so a rescue row overstates what clustering would accept. If embeddings are adopted, adoption means a matcher change measured through the clusterer, not these rows.
- Sentence embeddings exist only for some languages. The catalog's languages are en, de, fr, it, nl, pl and uk. A language without a model abstains rather than falling back to another language's model.
- `NLContextualEmbedding` (per-script models, on-demand assets) is not evaluated here.
- Metrics count true positives, false positives and false negatives on labeled or predicted pairs; true negatives are not reported.

## Tests

`testEventCorpusHarness` now also covers the comparison on the synthetic control set, with a French report of the same earthquake and an English copy dated six days earlier:

- with no model, the 4 cross-language, 3 out-of-window and 3 unembedded labeled pairs are counted and nothing is scored
- cosine distance of a zero vector is maximal; parallel vectors have no distance
- with the system models, cross-language pairs still stay out; deterministic links score 3 true and 0 false positives on the compared pairs; a veto never adds links, a rescue never removes them, and the widest cutoff misses no comparable labeled pair
- the sentence-embedding dimension for each catalog language on the test machine is printed

If the system has no English sentence embedding, the native checks are skipped with a printed note.

## Verification

The authoring environment was a Linux container without a Swift toolchain; its network policy blocked swift.org. Nothing was compiled or run locally. A tree-sitter Swift parse of `Tests/NewsTests.swift` found no new syntax errors (the same six grammar-limitation errors as on `main`). Compilation, the regression suite and per-language support are left to macOS CI.

## Remaining for #127

- Run the tune sweep and the holdout at the chosen cutoff once #102 has a labeled corpus with titles and descriptions.
- Adopt embeddings only if the holdout improves over deterministic matching without lowering precision below the ≥97% gate; otherwise close #127 as not adopted.
