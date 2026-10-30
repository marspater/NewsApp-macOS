# Model compression — 27 October 2026

Refs #554, #574 (epic M). Both models stay fp16: neither 8-bit variant meets the parity gates, although both leave the tune replay and the authored corpus unchanged. Receipts are in `~/news-eval/palettize-2026-10-27/` (`0700`). The old library holdout was not read; the dual gate runs on the fresh set later.

## Scope

Mars dropped the earlier 30 MB size target on 27 October: a bigger bundle is fine. Only two variants were measured, int8 linear quantization and 8-bit palettization. An 8-bit model ships only if it is decision-identical:

- tune and authored corpus identical;
- pair-model probability within 0.01 of the fp16 model;
- MiniLM pooled cosine at least 0.9999;
- Neural Engine placement and quiet latency not worse.

## What was built

`script/training/compress_models.py OUT --pair-state STATE.pt --mode fp16|int8|pal8` exports both shipped models as fixed-length functions and compresses each function with `coremltools.optimize.coreml`:

- `minilm.mlpackage`: the pinned Hub revision (the shipped weights), with functions `length_16` to `length_128`. These are the same functions as the #696 model.
- `pairscorer.mlpackage`: the pair model, rebuilt from the training state of the shipped model. `pairmodel-2026-10-24-v3/pairscorer-state.pt` (SHA-256 `69d45c41…d978f`) is the run whose `weight.bin` is byte-identical to the shipped one. It has functions `length_64`, `length_128` and `length_256`; `length_256` is the default and has the shipped shape.

The script then compares both with the shipped fp16 models on the authored-corpus texts, as the app runs them (CPU and Neural Engine):

- MiniLM: the pooled cosine on all 56 texts;
- the pair model: the probability for both orders of every pair of the first 30 texts, 870 in all, each padded to the shortest length that holds it.

Notes on the export:

- `coremltools.optimize.coreml` refuses a multifunction model, so `convert_minilm.export_functions` compresses each function before the join. The join shares the identical compressed weights.
- `compress()` takes any ML program, so a third model can go through the same step.
- The comparison runs in a fresh process. Core ML predictions in the process that had just traced the models crashed it (torch 2.14).
- The 8-bit palettizer uses coremltools' bundled `kmeans1d`, which it takes for fp16 tensors of 10,000 values or more. Smaller tensors (biases, norms) stay fp16, because the other k-means path needs scikit-learn, which the pinned requirements do not include.
- `--self-check` runs a tiny random pair model through every mode without downloads.

## Results

| Variant | `minilm.mlmodelc` | `pairscorer.mlmodelc` | MiniLM pooled cosine, min / median (gate ≥ 0.9999) | Pair probability difference, max / median (gate ≤ 0.01) | Authored corpus | Tune en |
| --- | --- | --- | --- | --- | --- | --- |
| shipped (fp16; the pair model is one 256-token function) | 45.8 MB | 45.7 MB | — | — | 23 / 0, FN 2 | 44 / 0 / 49 |
| fp16, fixed lengths | 45.8 MB | 45.7 MB | 1.000000 / 1.000000 | 0.00000 / 0.00000 | identical | identical report |
| int8 linear, symmetric per channel | 23.2 MB | 23.1 MB | 0.999111 / 0.999516 | **0.198** / 0.0002 | identical | identical report |
| 8-bit k-means palettization, per tensor | 23.1 MB | 23.1 MB | 0.999704 / 0.999818 | **0.091** / 0.0001 | identical | identical report |

- Both 8-bit variants halve the bundle: about 46 MB instead of 91 MB. Both leave every tune and corpus decision as it was.
- Both fail the parity gates. MiniLM falls below 0.9999. One pair-model probability moves by 0.20 (int8) or 0.09 (pal8). That is enough to cross the 0.9 cutoff on another library, so decisions there could change.
- Re-exporting the pair model at fixed lengths with padding changes nothing: the largest probability difference is 0.0 in fp16. That re-export is what `PairScorer` will load once it pads to 64, 128 or 256 tokens (after M17).

## Placement

From `--compute-plan`, with candidates passed through `NEWS_EMBEDDING_MODEL_PATH` and `NEWS_PAIR_MODEL_PATH`.

- **Same placement for every variant.** Compression does not move work: each function prefers the same device with the same cost shares in fp16, int8 and pal8.
  - MiniLM under `.cpuAndNeuralEngine`: Neural Engine 56% (16 tokens), 66% (32), 80% (64), 57% (128).
  - Pair model under `.cpuAndNeuralEngine`: Neural Engine 80% (64), 57% (128), 75% (256).
- **`.all` sends the pair model's short function to the GPU.** Under `.all`, Core ML puts the pair model's 64-token function 100% on the GPU, as it did with MiniLM's short functions. `PairScorer` should load with `.cpuAndNeuralEngine` when it takes the fixed lengths.
- **No latency numbers.** These runs had a 1-minute load average of 6.5–10 with another build running, so the latency they produced is not reported here. The compressed models do not ship, so no quiet measurement was needed.

## PairScorer at fixed lengths

`PairScorer` now works like `SentenceEmbedder`:
- It loads the `length_64`, `length_128` and `length_256` functions of the shipped fp16 re-export with `.cpuAndNeuralEngine`.
- It pads each pair to the shortest function that holds it.
- It writes its three inputs through the arrays' buffers instead of one boxed `NSNumber` per element.
- It keeps the cache and the mean of both orders.
- A model with a single 256-token function, which `train_pair_model.py` exports, still loads and runs every pair at 256.

The weights are unchanged: the shipped v3 state, with a probability difference of 0.0 against the earlier model. A second fp16 export from the same state has identical weights but differently named operations, and it differs by up to 0.0066 in probability.

Checks, the merged base (256-token model) against the change:
- Authored corpus: identical output, v13 TP 23, FP 0, FN 2.
- Story regressions: identical, 23 event pairs and 31 story pairs, with known gaps of 8 event pairs and 4 story pairs.
- Tune replay: the whole report is identical, en 44 / 0 / 49.

Placement and latency, measured on a quiet machine with no training or build running and a 1-minute load average of 2.4–2.9. The 55 corpus pairs need 64 or 128 tokens. The timings are model predictions on inputs built before the timer starts: one prediction, and one batched prediction per sequence length. They are not end-to-end pair scores. `PairScorer.probabilities` also tokenizes each pair and runs two predictions, one per order, one pair at a time, so an uncached pair score costs at least twice a single prediction plus tokenization; the ratio between before and after is what the table shows. The 27 October benchmark JSON names the single-prediction figure `per_pair_median_ms`; `--compute-plan` now reports it as `single_prediction_median_ms`.

| Pair model | Neural Engine share (`.cpuAndNeuralEngine`) | One prediction, median | 55 inputs, one batched prediction per length | Load |
| --- | --- | --- | --- | --- |
| before: one 256-token function, `.all` | 76% | 1.8 ms | 87 ms | 697 ms |
| before, `.cpuAndNeuralEngine` | 76% | 1.8 ms | 87 ms | 685 ms |
| after: 64/128/256 functions, `.cpuAndNeuralEngine` | 80% (64), 57% (128), 75% (256) | 0.7 ms | 27 ms | 1,775 ms |
| after, `.all` | the 64-token function 100% on the GPU | 0.8 ms | 31 ms | 1,495 ms |

The load time covers three functions; it is paid once per launch. The first quiet attempt aborted in Core ML. A stale compiled-model cache of the test binary (`~/Library/Caches/runner_pair`, "Original module missing") was hit while the `.all` and GPU loads compiled the 64-token GPU graph. Core ML raises that as an Objective-C exception, which Swift cannot catch. The run passed after the cache was cleared. The app loads with `.cpuAndNeuralEngine` only, which does not build that graph.

## Decision

`minilm.mlmodelc` and `pairscorer.mlmodelc` stay fp16; the pair model ships as its fixed-length fp16 re-export. The compression step stays in `compress_models.py` for a later model or a looser gate.
