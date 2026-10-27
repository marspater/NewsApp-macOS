# Neural Engine placement — 27 October 2026

Refs #554, #574 (epic M). Apple M5 (10 cores, 24 GB), macOS 27.2, an `-O` test runner, the training venv (coremltools 9.0, torch 2.14.1, transformers 5.20.2). Numbers are in `docs/benchmarks/2026-10-27-neural-engine-placement.json`. Receipts are in `~/news-eval/neural-engine-2026-10-27/` (`0700`): the candidate, the rejected exports, both vector dumps and the placement logs. The private holdout was not read.

## How placement was read

`./test.sh --compute-plan` loads each shipped model with `MLComputePlan` (macOS 14.4+) under `.all` and `.cpuAndNeuralEngine`, function by function, and sums each operation's estimated cost by its preferred device. It names the operations that cannot run on the Neural Engine, then times load, first prediction, one text or pair, and a batch under all four compute units. `NEWS_EMBEDDING_MODEL_PATH` and `NEWS_PAIR_MODEL_PATH` point it at candidates.

## Findings

| Model | Export | Cost share under `.all` | Under `.cpuAndNeuralEngine` |
| --- | --- | --- | --- |
| `minilm.mlmodelc` before | flexible 1–128 tokens (coremltools 6.3) | CPU 100% | CPU 100% |
| `minilm.mlmodelc` with enumerated lengths (rejected) | `EnumeratedShapes` 16/32/64/128 | every operation preferred on the CPU | — |
| `minilm.mlmodelc` after | four fixed-length functions | 16, 32, 64 tokens: GPU 100%; 128: Neural Engine 57%, CPU 43% | Neural Engine 56% (16), 66% (32), 80% (64), 57% (128); the rest CPU |
| `pairscorer.mlmodelc` (unchanged) | fixed 1×256 | Neural Engine 76%, CPU 24% | the same |

- The flexible-length encoder never reached the Neural Engine. Core ML ran it on the CPU without saying so.
- Enumerated shapes were no fix. The plan still preferred the CPU, and every change of length between predictions cost a re-plan: 76 ms a text, 155 s for 2,000 texts (measured under load).
- Fixed lengths work, joined as one multifunction model (`length_16` to `length_128`, one copy of the weights, 44 MB as before). Under `.all`, though, Core ML sends the three shorter functions to the GPU. `SentenceEmbedder` therefore loads with `.cpuAndNeuralEngine`. Clustering runs in the background, and staying off the GPU spares the interface's rendering.
- Operations that cannot run on the Neural Engine are the same in both models: the word-piece embedding `gather` and its index arithmetic (`cast`, `greater_equal`, `add`, `select`), `expand_dims` of the mask, and in MiniLM the `mul` that derives position and token-type ids from the input. That `mul` keeps the full 512-row position table and the 2-row token-type table in the file, so the encoder stays a complete `BertModel` for `train_pair_model.py`, which reads it as the pair model's base. The CPU share in the table is that lookup.

## Latency (quiet machine, load 2.4–3.5, no training)

Authored-corpus texts: median 40 word pieces, at most 57.

| | before, shipped `.all` | after, `.cpuAndNeuralEngine` | after, `.all` | after, `.cpuOnly` |
| --- | --- | --- | --- | --- |
| one text, median | 1.1 ms | 0.9 ms | 1.4 ms | 0.9 ms |
| 2,000 texts, one batch per length | 927 ms | 727 ms | 1,387 ms | 1,018 ms |
| load, compiled model cached | 253 ms | 119 ms | 1,203 ms | 330 ms |

Under a training run's GPU load the shipped model took 5.8 ms a text and 9.7 s per 2,000 texts. The pair model takes 1.8 ms a pair under `.all` and 1.9 ms under `.cpuAndNeuralEngine`.

One defect was found and fixed on the way. The fixed-length export returns half floats, and `pooled` read those through the boxed `MLMultiArray` subscript: 8.7 s per 2,000 texts. It now sums them from the buffer.

## Gates

- **Vector parity:** pooled cosine against the shipped model, on all 56 authored-corpus texts (`--embedding-vectors`), is at least 0.999967 (median 0.999978); none is below 0.9999. `SentenceEmbedder.modelVersion` stays 2 (the #540 precedent), so stored embeddings stay valid.
- **Authored corpus:** v13 TP 23, FP 0, FN 2 before and after.
- **Tune replay:** en TP 44, FP 0, FN 49 before and after. The whole report is identical.
- **`embedding_cold_2000_ms` (gate 1,040 ms):** not measured cleanly; see the open item below. On the corpus texts, which are longer than the synthetic ones the gate uses, 2,000 texts take 727 ms after against 927 ms before.

## Open

- Since 07:45 every `--performance-baseline` run has aborted with "Failed to allocate memory IOSurface object" inside Core ML batch prediction. The unchanged base runner with the old model aborts the same way, and about 5,000 IOSurfaces are allocated system-wide. The cold-2000 number waits for a clean machine.
- Core ML raises this failure as an Objective-C exception, which Swift cannot catch, so the batch fallback in `embedBatch` cannot help. This is the case before and after the change.
- Pair model, for its owner: a fixed 256-token input pads most pairs threefold. Fixed 64/128/256 functions in the same multifunction form would shorten them, and `.cpuAndNeuralEngine` costs it nothing.
- Palettization (slice 3) re-measures placement with this flag.
