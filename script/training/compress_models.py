#!/usr/bin/env python3
"""Export the shipped models as fixed-length functions and compress their weights (#554).
Mars's Mac only, never CI: run it from the virtual environment built from `script/training/requirements.txt`.

`compress_models.py OUT_DIR --pair-state STATE.pt [--mode fp16|int8|pal8]` writes, under OUT_DIR/MODE/:
- `minilm.mlpackage`: the sentence encoder from the pinned Hub revision (the shipped weights), one function per
  `convert_minilm.LENGTHS`;
- `pairscorer.mlpackage`: the pair model from the training state it was exported from (`pairscorer-state.pt` beside
  the shipped `pairscorer.mlpackage`), one function per `PAIR_LENGTHS` (64, 128, 256 tokens; `length_256`, the
  default, is the shipped model's shape);
- both compiled, and `report.json`: sizes, and the distance to the shipped fp16 models on the authored-corpus texts as
  the app runs them (CPU and Neural Engine): the smallest pooled cosine of the encoder (#540, at least 0.9999) and the
  largest difference of the pair probability over both orders of every pair of the first 30 texts (at most 0.01).
Modes: `fp16` none; `int8` linear symmetric per-channel weights (`coremltools.optimize.coreml.linear_quantize_weights`);
`pal8` an 8-bit k-means lookup table per tensor of 10,000 values or more (`palettize_weights`). `compress()` takes any ML program, so a further
model goes through the same step.
A model ships only when the Swift replay (tune, authored corpus) is identical and the placement is not worse.
`compress_models.py --self-check` runs a tiny random pair model through every mode, without downloads.
"""
import argparse
import gc
import json
import multiprocessing
import pathlib
import platform
import subprocess  # nosec B404
import sys

import coremltools as ct
import coremltools.optimize.coreml as cto
import numpy as np
import torch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from convert_minilm import (
    LENGTHS,
    MAX_TOKENS,
    UNITS,
    Encoder,
    build,
    compiled_functions,
    export_functions,
    pooled,
)
from wordpiece import Tokenizer, require

ROOT = pathlib.Path(__file__).resolve().parents[2]
MODELS = ROOT / 'Sources/Resources/Models'
FIXTURE = ROOT / 'Tests/Fixtures/story-corpus/matcher-regressions-v1.json'
PAIR_LENGTHS = (64, 128, 256)  # PairScorer.sequenceLengths
MODES = {
    'fp16': None,
    'int8': cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(
        mode='linear_symmetric', granularity='per_channel')),
    # k-means through coremltools' bundled kmeans1d, which it takes for fp16 tensors of 10,000 values or more; smaller
    # ones (biases, norms) stay fp16, since the other k-means path needs scikit-learn, not in the requirements.
    'pal8': cto.OptimizationConfig(global_config=cto.OpPalettizerConfig(
        nbits=8, mode='kmeans', granularity='per_tensor', weight_threshold=10_000)),
}


def compress(mlmodel, mode):
    """One ML program with its weights compressed by `mode`; a multifunction model is compressed function by function
    before the join (`convert_minilm.export_functions`)."""
    config = MODES[mode]
    if config is None:
        return mlmodel
    if mode == 'int8':
        return cto.linear_quantize_weights(mlmodel, config)
    return cto.palettize_weights(mlmodel, config)


class PairEncoder(torch.nn.Module):
    """The pair model's exported function at any fixed length: `train_pair_model.Scorer` with position ids derived from
    the input, so every length shares the whole position table."""

    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, input_ids, attention_mask, token_type_ids):
        bert = self.model.bert
        positions = torch.arange(input_ids.shape[1], device=input_ids.device).unsqueeze(0) + input_ids * 0
        hidden = bert.embeddings.LayerNorm(
            bert.embeddings.word_embeddings(input_ids) + bert.embeddings.position_embeddings(positions)
            + bert.embeddings.token_type_embeddings(token_type_ids))
        blocked = (1.0 - attention_mask[:, None, None, :].to(hidden.dtype)) * -10000.0
        for layer in bert.encoder.layer:
            output = layer(hidden, attention_mask=blocked)
            hidden = output[0] if isinstance(output, tuple) else output
        logits = self.model.classifier(bert.pooler(hidden))
        if logits.shape[-1] == 1:  # binary: `probability` of one event
            return torch.sigmoid(logits[:, 0])
        return torch.softmax(logits, dim=-1)  # three-way (#627): `probabilities` of different, related, same


def pair_probability(models, tokenizer, a, b):
    """The pair model's probability for `a` then `b`, padded to the shortest of `models` that holds the pair, as
    `PairScorer` pads it: `[CLS] a [SEP] b [SEP]` truncated longest first to the longest length."""
    longest = max(models)
    ids, mask, types = tokenizer.encode_ids(tokenizer.pieces(a), tokenizer.pieces(b), longest)
    used = sum(mask)
    length = min(length for length in models if length >= used)
    feed = {name: np.array([values[:length]], dtype=np.int32)
            for name, values in (('input_ids', ids), ('attention_mask', mask), ('token_type_ids', types))}
    output = models[length].predict(feed)
    if 'probability' in output:
        return float(np.ravel(output['probability'])[0])
    return float(np.ravel(output['probabilities'])[2])  # three-way: the same-event class


def compiled_pair_functions(path):
    description = json.loads((path / 'metadata.json').read_text())[0]
    if 'functions' not in description:
        return {256: ct.models.CompiledMLModel(str(path), compute_units=UNITS)}
    return {int(f['name'].removeprefix('length_')):
            ct.models.CompiledMLModel(str(path), compute_units=UNITS, function_name=f['name'])
            for f in description['functions']}


def size(path):
    return sum(f.stat().st_size for f in path.rglob('*') if f.is_file())


def compile_model(package, out):
    """Compiles with Xcode's own compiler, which also writes the metadata that lists a model's functions; the
    arguments are this script's own paths."""
    subprocess.run(  # nosec B603 # nosemgrep
        ['/usr/bin/xcrun', 'coremlcompiler', 'compile', str(package), str(out)], check=True, capture_output=True)
    return out / (package.stem + '.mlmodelc')


def private_file(value):
    """An input file, which must be a regular file outside this checkout."""
    path = pathlib.Path(value).expanduser().resolve()
    if not path.is_file() or ROOT in path.parents:
        raise argparse.ArgumentTypeError(f'{value} is not a private file outside the checkout')
    return path


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument('out')
    parser.add_argument('--pair-state', required=True, type=private_file, help='pairscorer-state.pt of the shipped pair model')
    parser.add_argument('--mode', choices=sorted(MODES), default='int8')
    parser.add_argument('--check-only', action='store_true', help='compare the packages already in OUT_DIR/MODE')
    args = parser.parse_args(argv)
    out = pathlib.Path(args.out).resolve() / args.mode
    require(not any((parent / '.git').exists() for parent in [out, *out.parents]), 'Write outside Git checkouts')
    out.mkdir(parents=True, exist_ok=True)
    texts = [a['title'] + '\n' + (a.get('description') or '')[:600]
             for a in json.loads(FIXTURE.read_text())['articles']]

    if not args.check_only:
        export(args, out)
        # The comparison runs in a fresh process: Core ML predictions after the exports crashed this one (torch 2.14).
        process = multiprocessing.get_context('spawn').Process(target=check, args=(args, out, texts))
        process.start()
        process.join()
        require(process.exitcode == 0, f'The comparison failed (exit {process.exitcode})')
        return
    check(args, out, texts)


def export(args, out):
    from train_pair_model import CONFIG
    from transformers import BertConfig, BertForSequenceClassification
    bert, _ = build('hub')
    export_functions(Encoder(bert).eval(), ('input_ids', 'attention_mask'), ('last_hidden_state', 'pooler_output'),
                     LENGTHS, out / 'minilm.mlpackage', compress=lambda m: compress(m, args.mode))
    state = torch.load(args.pair_state, weights_only=True)
    labels = state['classifier.weight'].shape[0]  # the shipped v3 model is binary, M17's head three-way
    model = BertForSequenceClassification(BertConfig(**{**CONFIG.to_dict(), 'num_labels': labels}))
    model.load_state_dict(state)
    export_functions(PairEncoder(model.eval()).eval(), ('input_ids', 'attention_mask', 'token_type_ids'),
                     ('probability' if labels == 1 else 'probabilities',), PAIR_LENGTHS,
                     out / 'pairscorer.mlpackage',
                     compress=lambda m: compress(m, args.mode))


def check(args, out, texts):
    tokenizer = Tokenizer()
    ours, shipped = compiled_functions(compile_model(out / 'minilm.mlpackage', out)), compiled_functions(
        MODELS / 'minilm.mlmodelc')
    cosines = []
    for text in texts:
        ids = tokenizer.encode_single(text, max_length=MAX_TOKENS)
        vectors = []
        for models in (ours, shipped):
            length = min(n for n in models if n >= len(ids))
            padded, mask = np.zeros((2, 1, length), dtype=np.int32)
            padded[0, :len(ids)], mask[0, :len(ids)] = ids, 1
            hidden = models[length].predict({'input_ids': padded, 'attention_mask': mask})['last_hidden_state']
            vectors.append(pooled(np.asarray(hidden)[:, :len(ids)]))
        ours_vector, shipped_vector = vectors
        cosines.append(float(np.dot(ours_vector, shipped_vector)))
    del ours, shipped, models  # loading the pair model beside eight encoder functions crashed the process
    gc.collect()
    ours = compiled_pair_functions(compile_model(out / 'pairscorer.mlpackage', out))
    shipped = compiled_pair_functions(MODELS / 'pairscorer.mlmodelc')
    pairs = [(a, b) for i, a in enumerate(texts[:30]) for b in texts[:i]]
    differences = [abs(pair_probability(ours, tokenizer, x, y) - pair_probability(shipped, tokenizer, x, y))
                   for a, b in pairs for x, y in ((a, b), (b, a))]
    report = {
        'mode': args.mode,
        'bytes': {name: size(out / name) for name in ('minilm.mlmodelc', 'pairscorer.mlmodelc')},
        'minilm_vs_shipped': {'texts': len(cosines), 'pooled_cosine_min': round(min(cosines), 6),
                              'pooled_cosine_median': round(float(np.median(cosines)), 6)},
        'pairscorer_vs_shipped': {'orders': len(differences), 'probability_difference_max': round(max(differences), 5),
                                  'probability_difference_median': round(float(np.median(differences)), 5)},
        'versions': {'python': platform.python_version(), 'torch': torch.__version__, 'coremltools': ct.__version__},
    }
    # OUT_DIR is the operator's own output directory, named on the command line.
    (out / 'report.json').write_text(json.dumps(report, indent=1, sort_keys=True) + '\n')  # NOSONAR
    print(json.dumps(report, indent=1, sort_keys=True))


def self_check():
    """A tiny random pair model through every mode: three joined functions that agree with PyTorch."""
    import tempfile

    from transformers import BertConfig, BertForSequenceClassification
    torch.manual_seed(554)
    config = BertConfig(vocab_size=200, hidden_size=128, num_hidden_layers=2, num_attention_heads=4,
                        intermediate_size=256, max_position_embeddings=64, num_labels=1, attn_implementation='eager')
    module = PairEncoder(BertForSequenceClassification(config).eval()).eval()
    ids = torch.tensor([[1, 5, 9, 2, 7, 3, 0, 0]], dtype=torch.int32)
    mask = torch.tensor([[1, 1, 1, 1, 1, 1, 0, 0]], dtype=torch.int32)
    types = torch.tensor([[0, 0, 0, 0, 1, 1, 0, 0]], dtype=torch.int32)
    with torch.no_grad():
        expected = float(module(ids, mask, types)[0])
    for mode in MODES:
        with tempfile.TemporaryDirectory() as scratch:
            path = pathlib.Path(scratch) / 'tiny.mlpackage'
            export_functions(module, ('input_ids', 'attention_mask', 'token_type_ids'), ('probability',), (8, 16), path,
                             compress=lambda m, mode=mode: compress(m, mode))
            short = ct.models.MLModel(str(path), compute_units=UNITS, function_name='length_8')
            got = float(np.ravel(short.predict({'input_ids': ids.numpy(), 'attention_mask': mask.numpy(),
                                                     'token_type_ids': types.numpy()})['probability'])[0])
            require(abs(got - expected) < 0.02, f'{mode}: Core ML {got:.4f} against PyTorch {expected:.4f}')
    print('compress_models self-check passed')


if __name__ == '__main__':
    if sys.argv[1:] == ['--self-check']:
        self_check()
    elif sys.argv[1:] and not sys.argv[1].startswith('--'):
        main(sys.argv[1:])
    else:
        sys.exit(__doc__)
