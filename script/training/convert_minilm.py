#!/usr/bin/env python3
"""Convert the sentence encoder to Core ML and check it against the shipped `minilm.mlmodelc` (#555).
Mars's Mac only, never CI: run it from the virtual environment built from `script/training/requirements.txt`.

`convert_minilm.py OUT_DIR [--source hub|shipped]` builds `sentence-transformers/all-MiniLM-L6-v2` (pinned revision,
downloaded from the Hugging Face Hub at conversion time; the shipped weights derive from it) or the shipped model's own
weights as a `BertModel`, exports it with a flexible sequence length of 1 to 128 tokens and the two outputs the app
reads (`last_hidden_state`; `pooler_output` kept for the schema), writes OUT_DIR/minilm.mlpackage and
OUT_DIR/metadata.json (source, revision, versions, parity), and reports how far the new model is from the shipped one
on the check texts: the largest hidden-state difference and the smallest cosine between the pooled, normalized vectors
`SentenceEmbedder.embed` would produce. A model only ships after the Swift replay (`--matcher-regressions`, the tune
replay) is unchanged and `SentenceEmbedder.modelVersion` is bumped, since stored vectors are recomputed.
`convert_minilm.py --self-check` exports a tiny random encoder at two lengths without downloads.
"""
import json
import pathlib
import platform
import sys

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
CHECK_TEXTS = (
    'Erdoğan meets Sánchez in Ankara',
    'Magnitude 6.1 earthquake strikes eastern Turkey',
    'Apple reports record iPhone sales as services revenue climbs',
    'Storm Austen leaves 200,000 homes without power across Ireland and Scotland after overnight gusts of 130 km/h',
)


class Encoder(torch.nn.Module):
    """The exported function with the sequence length left open: position ids come from the input's own shape, the
    attention mask is spelled out as the additive form the original conversion used, token types are all zero."""

    def __init__(self, bert):
        super().__init__()
        self.bert = bert

    def forward(self, input_ids, attention_mask):
        embeddings = self.bert.embeddings
        positions = torch.arange(input_ids.shape[1], device=input_ids.device).unsqueeze(0)
        hidden = embeddings.LayerNorm(
            embeddings.word_embeddings(input_ids) + embeddings.position_embeddings(positions)
            + embeddings.token_type_embeddings(torch.zeros_like(input_ids)))
        blocked = (1.0 - attention_mask[:, None, None, :].to(hidden.dtype)) * -10000.0
        for layer in self.bert.encoder.layer:
            output = layer(hidden, attention_mask=blocked)
            hidden = output[0] if isinstance(output, tuple) else output  # transformers 5 returns the tensor alone
        return hidden, self.bert.pooler(hidden)


def convert(bert, example_length, max_length):
    """Traces `bert` at one length and converts it with a flexible sequence dimension."""
    encoder = Encoder(bert).eval()
    example = (torch.ones(1, example_length, dtype=torch.int32), torch.ones(1, example_length, dtype=torch.int32))
    traced = torch.jit.trace(encoder, example)
    shape = ct.Shape(shape=(1, ct.RangeDim(1, max_length, default=example_length)))
    mlmodel = ct.convert(
        traced, inputs=[ct.TensorType(name='input_ids', shape=shape, dtype=np.int32),
                        ct.TensorType(name='attention_mask', shape=shape, dtype=np.int32)],
        outputs=[ct.TensorType(name='last_hidden_state'), ct.TensorType(name='pooler_output')],
        convert_to='mlprogram', minimum_deployment_target=ct.target.macOS15, compute_precision=ct.precision.FLOAT16)
    return encoder, mlmodel


def predict(model, ids):
    """`last_hidden_state` of a Core ML model (`.mlpackage` or compiled) for one unpadded token sequence."""
    return model.predict({'input_ids': np.array([ids], dtype=np.int32),
                          'attention_mask': np.ones((1, len(ids)), dtype=np.int32)})['last_hidden_state']


def pooled(hidden):
    """Mean over the tokens, L2-normalized: the vector `SentenceEmbedder.embed` returns for an unpadded input."""
    vector = np.asarray(hidden, dtype=np.float32)[0].mean(axis=0)
    return vector / max(float(np.linalg.norm(vector)), 1e-12)


def compare(ours, theirs, texts, tokenizer):
    """Largest hidden-state difference and smallest pooled cosine between two Core ML models on `texts`."""
    worst_difference, worst_cosine = 0.0, 1.0
    for text in texts:
        ids = tokenizer.encode_single(text, max_length=MAX_TOKENS)
        a, b = predict(ours, ids), predict(theirs, ids)
        worst_difference = max(worst_difference, float(np.abs(np.asarray(a) - np.asarray(b)).max()))
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
    encoder, mlmodel = convert(bert, example_length=16, max_length=MAX_TOKENS)
    mlmodel.short_description = 'Sentence encoder for story matching: mean-pooled token states (#555)'
    mlmodel.author = 'News'
    mlmodel.license = 'Derived from sentence-transformers/all-MiniLM-L6-v2, Apache License 2.0'
    path = out / 'minilm.mlpackage'
    mlmodel.save(str(path))
    torch_difference = 0.0
    for text in CHECK_TEXTS:
        ids = tokenizer.encode_single(text, max_length=MAX_TOKENS)
        with torch.no_grad():
            ours = encoder(torch.tensor([ids], dtype=torch.int32), torch.ones(1, len(ids), dtype=torch.int32))[0]
        torch_difference = max(torch_difference, float(np.abs(ours.numpy() - predict(mlmodel, ids)).max()))
    shipped_difference, shipped_cosine = compare(mlmodel, ct.models.CompiledMLModel(str(SHIPPED)), CHECK_TEXTS,
                                                 tokenizer)
    metadata = {
        'model': 'minilm', 'source': source, 'max_tokens': MAX_TOKENS,
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
    """A tiny random encoder converts with a flexible length and agrees with PyTorch at two lengths."""
    torch.manual_seed(555)
    config = BertConfig(vocab_size=200, hidden_size=32, num_hidden_layers=2, num_attention_heads=4,
                        intermediate_size=64, max_position_embeddings=64, attn_implementation='eager')
    encoder, mlmodel = convert(BertModel(config, add_pooling_layer=True).eval(), example_length=8, max_length=32)
    for length in (5, 20):
        ids = list(range(1, length + 1))
        with torch.no_grad():
            ours = encoder(torch.tensor([ids], dtype=torch.int32), torch.ones(1, length, dtype=torch.int32))[0]
        difference = float(np.abs(ours.numpy() - predict(mlmodel, ids)).max())
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
