# Reproducible models — 25 October 2026

Refs #555, #574 (epic M). Run on Mars's Mac in the training venv (`script/training/requirements.txt`: Python 3.13.13, torch 2.14.1, transformers 5.20.2, coremltools 9.0); outputs under `~/news-eval/minilm-2026-10-25/` (`0700`), nothing of them enters the repository.

## What the repository lacked

- `minilm.mlmodelc` was converted with coremltools 6.3.0, torch 1.13.1 and transformers 4.8.2 (its own `userDefinedMetadata`), and the script that did it was never committed.
- `pairscorer.mlmodelc` (matcher v11, #525) was exported by `train_pair_model.py` with coremltools 9.0 and torch 2.7.1 on 24 October 2026; its training state (`pairscorer-state.pt`) was not kept, so it cannot be re-exported, only retrained. Retrained models write `metadata.json` since #624 and keep their state beside the model.
- Neither model had a metadata file naming its base, versions and check.

## What #555 adds

- `script/training/convert_minilm.py OUT [--source hub|shipped]`: `sentence-transformers/all-MiniLM-L6-v2` at revision `1110a243fdf4706b3f48f1d95db1a4f5529b4d41` (as served on 25 October 2026), or the shipped model's own tensors, as a hand-written encoder with a flexible 1–128 token length, exported as an fp16 ML program for macOS 15; the two outputs the shipped schema has (`last_hidden_state`, which `SentenceEmbedder.embed` pools, and `pooler_output`). The script compares the result with the shipped model on four check texts and writes `OUT/metadata.json`. `--self-check` exports a tiny random encoder at two lengths without downloads.
- `Sources/Resources/Models/minilm-metadata.json` and `pairscorer-metadata.json`: base, versions, inputs and outputs, the reproducing check.
- `.github/dependabot.yml`: the `pip` ecosystem for `script/training`, weekly, five open pull requests at most.

## Parity

| Conversion | Core ML vs PyTorch (same weights, four texts, max element difference in `last_hidden_state`) | vs shipped `minilm.mlmodelc`: max element difference | vs shipped: smallest cosine of the pooled, L2-normalized vectors |
| --- | --- | --- | --- |
| Shipped model (coremltools 6.3.0) against PyTorch on its own imported weights (`train_pair_model.py --check-shipped`, two texts) | 0.0162 | — | — |
| `--source hub` (Hub revision above) | 0.0043 | 0.0176 | 0.999986 |
| `--source shipped` (tensors read from the shipped MIL program) | 0.0037 | 0.0176 | 0.999986 |

Both sources give the same numbers to the printed precision: the Hub revision carries the weights the shipped model was built from. The 0.0176 hidden-state gap is the two converters' fp16 arithmetic, not the weights; the shipped model itself is 0.0162 from PyTorch, the new one 0.0043. The issue asked for a largest element difference of 0.001, which fp16 does not give across converter versions; the vectors the matcher uses agree to a cosine of 0.999986 (the identical-vector standard of #540 is 0.9999), so the re-export reproduces the model as the app sees it.

## Decision

The shipped encoder stays. A reconverted encoder would move every stored vector by fp16 noise for no gain and would need a `SentenceEmbedder.modelVersion` bump (every embedding recomputed) and the replay rerun; the script exists for the day the encoder changes (M18, #628, a news-tuned bi-encoder). The pair model's reproduction is the retraining path of #624 with its `metadata.json`.
