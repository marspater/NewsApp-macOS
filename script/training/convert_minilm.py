#!/usr/bin/env python3
"""Convert the sentence encoder to Core ML and check it against the shipped `minilm.mlmodelc` (#555).
Mars's Mac only, never CI: run it from the virtual environment built from `script/training/requirements.txt`.

`convert_minilm.py OUT_DIR [--source hub|shipped]` builds `sentence-transformers/all-MiniLM-L6-v2` (pinned revision,
downloaded from the Hugging Face Hub at conversion time; the shipped weights derive from it) or the shipped model's own
weights as a `BertModel`, exports it as one fixed-length function per sequence length (`length_16` to `length_128`,
sharing one copy of the weights; #554: a flexible length kept Core ML on the CPU, fixed lengths run on the Neural Engine,
and the app pads each text to the next length) with the two outputs the app reads (`last_hidden_state`;
`pooler_output` kept for the schema), writes OUT_DIR/minilm.mlpackage and OUT_DIR/metadata.json (source, revision,
versions, parity), and reports how far the new model is from the shipped one on the check texts: the largest
hidden-state difference and the smallest cosine between the pooled, normalized vectors `SentenceEmbedder.embed` would
produce. A model with new weights only ships after the Swift replay (`--matcher-regressions`, the tune replay) is
unchanged and `SentenceEmbedder.modelVersion` is bumped, since stored vectors are recomputed.
`convert_minilm.py --self-check` exports a tiny random encoder at three lengths and checks two padded inputs, without
downloads.
"""
import json
import pathlib
import platform
import sys
import tempfile

import coremltools as ct
import numpy as np
import torch
from transformers import BertConfig, BertModel

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from train_pair_model import CONFIG, SHIPPED, load_shipped
from wordpiece import Tokenizer, require

HUB_MODEL = 'sentence-transformers/all-MiniLM-L6-v2'
HUB_REVISION = '1110a243fdf4706b3f48f1d95db1a4f5529b4d41'  # as served on 25 October 2026
MAX_TOKENS = 128  # SentenceEmbedder.maxSequenceLength
LENGTHS = (16, 32, 64, MAX_TOKENS)  # SentenceEmbedder.sequenceLengths, one function each (#554)
# What the app runs on (#554): under ALL, Core ML placed the 16- to 64-token functions on the GPU.
UNITS = ct.ComputeUnit.CPU_AND_NE
CHECK_TEXTS = (
    'Erdoğan meets Sánchez in Ankara',
    'Magnitude 6.1 earthquake strikes eastern Turkey',
    'Apple reports record iPhone sales as services revenue climbs',
    'Storm Austen leaves 200,000 homes without power across Ireland and Scotland after overnight gusts of 130 km/h',
)


class Encoder(torch.nn.Module):
    """The exported function: position ids come from the input's own shape, the attention mask is spelled out as the
    additive form the original conversion used, token types are all zero. Both ids are derived from the input, so a
    fixed-length export still looks up the whole position (512) and token-type (2) tables instead of folding the rows
    it uses into constants (#554): the shipped encoder stays a complete `BertModel`, which `train_pair_model.py` reads
    as the pair model's base."""

    def __init__(self, bert):
        super().__init__()
        self.bert = bert

    def forward(self, input_ids, attention_mask):
        embeddings = self.bert.embeddings
        zeros = input_ids * 0
        positions = torch.arange(input_ids.shape[1], device=input_ids.device).unsqueeze(0) + zeros
        hidden = embeddings.LayerNorm(
            embeddings.word_embeddings(input_ids) + embeddings.position_embeddings(positions)
            + embeddings.token_type_embeddings(zeros))
        blocked = (1.0 - attention_mask[:, None, None, :].to(hidden.dtype)) * -10000.0
        for layer in self.bert.encoder.layer:
            output = layer(hidden, attention_mask=blocked)
            hidden = output[0] if isinstance(output, tuple) else output  # transformers 5 returns the tensor alone
        return hidden, self.bert.pooler(hidden)


def convert(bert, lengths, path, describe=lambda model: None):
    """Converts `bert` at each fixed length and joins the conversions as one multifunction package at `path`, function
    `length_N` per length (the longest is the default), sharing one copy of the weights. Returns the PyTorch module and
    the package's functions by length."""
    encoder = Encoder(bert).eval()
    descriptor = ct.utils.MultiFunctionDescriptor()
    with tempfile.TemporaryDirectory() as scratch:
        for length in lengths:
            example = (torch.ones(1, length, dtype=torch.int32), torch.ones(1, length, dtype=torch.int32))
            mlmodel = ct.convert(
                torch.jit.trace(encoder, example),
                inputs=[ct.TensorType(name='input_ids', shape=(1, length), dtype=np.int32),
                        ct.TensorType(name='attention_mask', shape=(1, length), dtype=np.int32)],
                outputs=[ct.TensorType(name='last_hidden_state'), ct.TensorType(name='pooler_output')],
                convert_to='mlprogram', minimum_deployment_target=ct.target.macOS15,
                compute_precision=ct.precision.FLOAT16)
            mlmodel.save(f'{scratch}/{length}.mlpackage')
            descriptor.add_function(f'{scratch}/{length}.mlpackage', src_function_name='main',
                                    target_function_name=f'length_{length}')
        descriptor.default_function_name = f'length_{lengths[-1]}'
        ct.utils.save_multifunction(descriptor, f'{scratch}/joined.mlpackage')
        joined = ct.models.MLModel(f'{scratch}/joined.mlpackage', skip_model_load=True)
        describe(joined)  # the join keeps no description of its parts
        joined.save(str(path))
    return encoder, {length: ct.models.MLModel(str(path), compute_units=UNITS, function_name=f'length_{length}')
                     for length in lengths}


def compiled_functions(path):
    """A compiled model's functions by length; a model of one flexible-length function (the encoder before #554) under
    its longest length, which it also accepts."""
    description = json.loads((path / 'metadata.json').read_text())[0]
    if 'functions' not in description:
        return {MAX_TOKENS: ct.models.CompiledMLModel(str(path), compute_units=UNITS)}
    return {int(function['name'].removeprefix('length_')):
            ct.models.CompiledMLModel(str(path), compute_units=UNITS, function_name=function['name'])
            for function in description['functions']}


def predict(models, ids):
    """`last_hidden_state` at the tokens of `ids`, run as `SentenceEmbedder` runs them: padded to the shortest length
    of `models` that holds them, the padding masked out."""
    length = min(length for length in models if length >= len(ids))
    padded, mask = np.zeros((2, 1, length), dtype=np.int32)
    padded[0, :len(ids)], mask[0, :len(ids)] = ids, 1
    hidden = models[length].predict({'input_ids': padded, 'attention_mask': mask})['last_hidden_state']
    return np.asarray(hidden)[:, :len(ids)]


def pooled(hidden):
    """Mean over the tokens, L2-normalized: the vector `SentenceEmbedder.embed` returns."""
    vector = np.asarray(hidden, dtype=np.float32)[0].mean(axis=0)
    return vector / max(float(np.linalg.norm(vector)), 1e-12)


def compare(ours, theirs, texts, tokenizer):
    """Largest hidden-state difference and smallest pooled cosine between two Core ML models on `texts`."""
    worst_difference, worst_cosine = 0.0, 1.0
    for text in texts:
        ids = tokenizer.encode_single(text, max_length=MAX_TOKENS)
        a, b = predict(ours, ids), predict(theirs, ids)
        worst_difference = max(worst_difference, float(np.abs(a - b).max()))
        worst_cosine = min(worst_cosine, float(np.dot(pooled(a), pooled(b))))
    return worst_difference, worst_cosine


def build(source):
    """The encoder's weights: the pinned Hub revision, or the shipped model's own tensors."""
    if source == 'hub':
        bert = BertModel.from_pretrained(HUB_MODEL, revision=HUB_REVISION, attn_implementation='eager')
        return bert.eval(), f'{HUB_MODEL}@{HUB_REVISION}'
    bert = BertModel(CONFIG, add_pooling_layer=True)
    load_shipped(bert)
    return bert.eval(), str(SHIPPED.relative_to(SHIPPED.parents[3]))


def describe(mlmodel):
    mlmodel.short_description = 'Sentence encoder for story matching: mean-pooled token states (#555, #554)'
    mlmodel.author = 'News'
    mlmodel.license = 'Derived from sentence-transformers/all-MiniLM-L6-v2, Apache License 2.0'


def main(argv):
    """OUT_DIR [--source hub|shipped]: convert, compare with the shipped model, write metadata.json."""
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('out')
    parser.add_argument('--source', choices=('hub', 'shipped'), default='hub')
    args = parser.parse_args(argv)
    out = pathlib.Path(args.out).resolve()
    require(not any((parent / '.git').exists() for parent in [out, *out.parents]), 'Write outside Git checkouts')
    out.mkdir(parents=True, exist_ok=True)
    bert, source = build(args.source)
    tokenizer = Tokenizer()
    path = out / 'minilm.mlpackage'
    encoder, models = convert(bert, LENGTHS, path, describe)
    torch_difference = 0.0
    for text in CHECK_TEXTS:
        ids = tokenizer.encode_single(text, max_length=MAX_TOKENS)
        with torch.no_grad():
            ours = encoder(torch.tensor([ids], dtype=torch.int32), torch.ones(1, len(ids), dtype=torch.int32))[0]
        torch_difference = max(torch_difference, float(np.abs(ours.numpy() - predict(models, ids)).max()))
    shipped_difference, shipped_cosine = compare(models, compiled_functions(SHIPPED), CHECK_TEXTS, tokenizer)
    metadata = {
        'model': 'minilm', 'source': source, 'max_tokens': MAX_TOKENS,
        'functions': [f'length_{length}' for length in LENGTHS], 'compute_units': 'cpuAndNeuralEngine',
        'outputs': ['last_hidden_state', 'pooler_output'],
        'check': {'texts': len(CHECK_TEXTS), 'core_ml_vs_torch_max_difference': round(torch_difference, 5),
                  'vs_shipped_max_difference': round(shipped_difference, 5),
                  'vs_shipped_min_pooled_cosine': round(shipped_cosine, 6)},
        'versions': {'python': platform.python_version(), 'torch': torch.__version__,
                     'transformers': __import__('transformers').__version__, 'coremltools': ct.__version__},
    }
    # OUT_DIR is the operator's own output directory, named on the command line.
    (out / 'metadata.json').write_text(json.dumps(metadata, indent=1, sort_keys=True) + '\n')  # NOSONAR
    print(f'wrote {path}; Core ML matches PyTorch within {torch_difference:.5f}; against the shipped model: '
          f'hidden states within {shipped_difference:.5f}, pooled cosine at least {shipped_cosine:.6f}')


def self_check():
    """A tiny random encoder converts to three fixed-length functions; padded to the next length, it agrees with
    PyTorch on the unpadded tokens at two lengths."""
    torch.manual_seed(555)
    config = BertConfig(vocab_size=200, hidden_size=32, num_hidden_layers=2, num_attention_heads=4,
                        intermediate_size=64, max_position_embeddings=64, attn_implementation='eager')
    with tempfile.TemporaryDirectory() as scratch:
        encoder, models = convert(BertModel(config, add_pooling_layer=True).eval(), (8, 16, 32),
                                  pathlib.Path(scratch) / 'tiny.mlpackage')
        for length in (5, 20):
            ids = list(range(1, length + 1))
            with torch.no_grad():
                ours = encoder(torch.tensor([ids], dtype=torch.int32), torch.ones(1, length, dtype=torch.int32))[0]
            difference = float(np.abs(ours.numpy() - predict(models, ids)).max())
            require(difference < 0.02, f'Core ML and PyTorch differ by {difference:.4f} at {length} tokens')
    require(abs(float(np.linalg.norm(pooled(ours.numpy()))) - 1.0) < 1e-5, 'pooled vectors are unit length')
    print('MiniLM conversion self-check passed')


if __name__ == '__main__':
    if sys.argv[1:] == ['--self-check']:
        self_check()
    elif sys.argv[1:] and not sys.argv[1].startswith('--'):
        main(sys.argv[1:])
    else:
        sys.exit(__doc__)
