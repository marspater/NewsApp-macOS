#!/usr/bin/env python3
"""Train the in-house pair cross-encoder (#525) from the shipped MiniLM weights and export it to Core ML.

Mars's Mac only, never CI: run it from a virtual environment built from `script/training/requirements.txt`.

`train_pair_model.py PAIRS.csv OUT_DIR` reads the private `./test.sh --export-pairs` CSV (headline and lead text with
the app's own word pieces), fine-tunes a pair classifier initialized from `Sources/Resources/Models/minilm.mlmodelc`,
reports numbers on a tenth of the articles held out (an in-distribution check, not the gate), writes
OUT_DIR/pairscorer.mlpackage and checks that Core ML and PyTorch agree. Tune and holdout never enter the CSV; the
threshold is chosen afterwards on tune by the Swift replay, which is also the only gate.
`train_pair_model.py --check-shipped` checks the weight import alone against the shipped model.
Training uses the word pieces the app exported, so it sees exactly the ids the app sends. The tokenizer port below only
serves the shipped-model check and the self-check; `encode_ids` mirrors `BertWordPieceTokenizer.encodePair`.
"""
import csv
import math
import pathlib
import re
import struct
import sys
import unicodedata
import zlib

import coremltools as ct
import numpy as np
import torch
from transformers import (
    BertConfig,
    BertForSequenceClassification,
    BertModel,
    get_linear_schedule_with_warmup,
)

ROOT = pathlib.Path(__file__).resolve().parents[2]
SHIPPED = ROOT / 'Sources/Resources/Models/minilm.mlmodelc'
VOCAB = ROOT / 'Sources/Resources/Models/vocab.txt'
MAX_LENGTH = 256
CONFIG = BertConfig(
    vocab_size=30522, hidden_size=384, num_hidden_layers=6, num_attention_heads=12, intermediate_size=1536,
    max_position_embeddings=512, type_vocab_size=2, hidden_act='gelu', layer_norm_eps=1e-12, num_labels=1,
    attn_implementation='eager')
CONST = re.compile(
    r'tensor<fp16, \[([0-9, ]+)\]> (\w+) = const\(\)\[name = tensor<string, \[\]>\("\w+"\), '
    r'val = tensor<fp16, \[[0-9, ]+\]>\(BLOBFILE\(path = tensor<string, \[\]>\("@model_path/weights/weight.bin"\), '
    r'offset = tensor<uint64, \[\]>\((\d+)\)')


def require(condition, message):
    if not condition:
        raise ValueError(message)


class Tokenizer:
    """Uncased, accent-stripped WordPiece exactly as the app's `BertWordPieceTokenizer` splits text."""

    def __init__(self, path=VOCAB):
        self.vocab = {}
        for index, line in enumerate(path.read_text(encoding='utf-8').split('\n')):
            if line.strip():
                self.vocab[line.strip()] = index
        self.pad, self.unk = self.vocab.get('[PAD]', 0), self.vocab.get('[UNK]', 100)
        self.cls, self.sep = self.vocab.get('[CLS]', 101), self.vocab.get('[SEP]', 102)

    @staticmethod
    def words(text):
        folded = ''.join(c for c in unicodedata.normalize('NFD', text) if unicodedata.category(c) != 'Mn').lower()
        words, current = [], ''
        for char in folded:
            if char.isspace():
                words, current = words + [current] if current else words, ''
            elif unicodedata.category(char)[0] in 'PS':
                words, current = (words + [current] if current else words) + [char], ''
            else:
                current += char
        return words + [current] if current else words

    def pieces(self, text):
        ids = []
        for word in self.words(text):
            ids.extend(self.word_piece(word))
        return ids

    def word_piece(self, word):
        if len(word) > 100:
            return [self.unk]
        ids, start = [], 0
        while start < len(word):
            end = len(word)
            while start < end and (('##' if start else '') + word[start:end]) not in self.vocab:
                end -= 1
            if start == end:
                return [self.unk]
            ids.append(self.vocab[('##' if start else '') + word[start:end]])
            start = end
        return ids

    def encode_single(self, text, max_length=128):
        return [self.cls] + self.pieces(text)[:max_length - 2] + [self.sep]

    def encode_pair(self, a, b, max_length=MAX_LENGTH):
        return self.encode_ids(self.pieces(a), self.pieces(b), max_length)

    def encode_ids(self, pa, pb, max_length=MAX_LENGTH):
        """[CLS] a [SEP] b [SEP], longest first truncation (b on ties), padded; ids, mask, type ids."""
        pa, pb = list(pa), list(pb)
        while len(pa) + len(pb) > max_length - 3:
            (pa if len(pa) > len(pb) else pb).pop()
        ids = [self.cls] + pa + [self.sep] + pb + [self.sep]
        types = [0] * (len(pa) + 2) + [1] * (len(pb) + 1)
        padding = max_length - len(ids)
        return ids + [self.pad] * padding, [1] * len(ids) + [0] * padding, types + [0] * padding


def shipped_state(path=SHIPPED):
    """The shipped model's fp16 tensors by Hugging Face `BertModel` key, read from its MIL program and weight file."""
    mil = (path / 'model.mil').read_text()
    blob = (path / 'weights/weight.bin').read_bytes()
    state = {}
    for dims, name, offset in CONST.findall(mil):
        sentinel, dtype, size, start = struct.unpack_from('<IIQQ', blob, int(offset))
        require(sentinel == 0xDEADBEEF and dtype == 1, f'Unexpected blob header for {name}')
        shape = [int(d) for d in dims.split(', ')]
        values = np.frombuffer(blob, dtype=np.float16, count=size // 2, offset=start).reshape(shape)
        state[name.removeprefix('model_').removesuffix('_to_fp16')] = torch.from_numpy(values.astype(np.float32))
    return state


def load_shipped(module):
    """Copies the shipped weights into a `BertModel`; every parameter must be found."""
    state = shipped_state()
    target = module.state_dict()
    loaded = {key: state[key.replace('.', '_')] for key in target if key.replace('.', '_') in state}
    missing = [key for key, value in module.named_parameters() if key not in loaded]
    require(not missing, f'Shipped weights miss {missing[:3]}')
    module.load_state_dict(loaded, strict=False)


def check_shipped():
    """The imported weights reproduce the shipped Core ML model's hidden states."""
    tokenizer, bert = Tokenizer(), BertModel(CONFIG, add_pooling_layer=True).eval()
    load_shipped(bert)
    shipped = ct.models.CompiledMLModel(str(SHIPPED))
    for text in ('Erdoğan meets Sánchez in Ankara', 'Magnitude 6.1 earthquake strikes eastern Turkey'):
        ids = tokenizer.encode_single(text)
        with torch.no_grad():
            ours = bert(input_ids=torch.tensor([ids]), attention_mask=torch.ones(1, len(ids), dtype=torch.long))
        theirs = shipped.predict({
            'input_ids': np.array([ids], dtype=np.int32), 'attention_mask': np.ones((1, len(ids)), dtype=np.int32)})
        difference = np.abs(ours.last_hidden_state.numpy() - theirs['last_hidden_state']).max()
        require(difference < 0.05, f'Imported weights differ from the shipped model by {difference:.3f}')
        print(f'  shipped parity for {len(ids)} tokens: max difference {difference:.4f}')
    print('Shipped MiniLM weights import check passed')


def read_pairs(path):
    file = pathlib.Path(path).resolve()
    require(file.suffix == '.csv' and file.is_file(), 'Use the --export-pairs CSV')
    require(not any((parent / '.git').exists() for parent in file.parents), 'Keep the pairs outside Git checkouts')
    csv.field_size_limit(1 << 20)
    def ids(value):
        return [int(piece) for piece in value.split()]
    with file.open(newline='') as handle:
        return [(int(row['label']), row['group'], ids(row['pieces_a']), ids(row['pieces_b']))
                for row in csv.DictReader(handle)]


def split(rows):
    """A tenth of the texts is held out, and a pair is held out only when both of its texts are; pairs that straddle
    the split are dropped, so no held-out text was trained on."""
    def held(pieces):
        return zlib.crc32(' '.join(map(str, pieces)).encode()) % 10 == 0
    fit = [r for r in rows if not held(r[2]) and not held(r[3])]
    return fit, [r for r in rows if held(r[2]) and held(r[3])]


def tensors(tokenizer, rows):
    encoded = [tokenizer.encode_ids(a, b) for _, _, a, b in rows]
    return (torch.tensor([e[0] for e in encoded]), torch.tensor([e[1] for e in encoded]),
            torch.tensor([e[2] for e in encoded]), torch.tensor([float(r[0]) for r in rows]))


def auc(scores, labels):
    """Area under the ROC curve by ranks (ties averaged)."""
    order = sorted(range(len(scores)), key=lambda i: scores[i])
    ranks, i = [0.0] * len(scores), 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and scores[order[j + 1]] == scores[order[i]]:
            j += 1
        for k in range(i, j + 1):
            ranks[order[k]] = (i + j) / 2 + 1
        i = j + 1
    positives = sum(labels)
    negatives = len(labels) - positives
    return (sum(r for r, y in zip(ranks, labels) if y) - positives * (positives + 1) / 2) / (positives * negatives)


def at_threshold(scores, labels, cutoff):
    tp = sum(1 for s, y in zip(scores, labels) if s >= cutoff and y)
    fp = sum(1 for s, y in zip(scores, labels) if s >= cutoff and not y)
    fn = sum(1 for s, y in zip(scores, labels) if s < cutoff and y)
    return f'precision {tp / max(1, tp + fp):.3f} recall {tp / max(1, tp + fn):.3f} (TP {tp}, FP {fp}, FN {fn})'


def predict(model, data, device, batch=64):
    model.eval()
    scores = []
    with torch.no_grad():
        for start in range(0, len(data[0]), batch):
            ids, mask, types = (t[start:start + batch].to(device) for t in data[:3])
            logits = model(input_ids=ids, attention_mask=mask, token_type_ids=types).logits[:, 0]
            scores.extend(torch.sigmoid(logits).float().cpu().tolist())
    return scores


def run_epoch(model, data, device, optimization, batch):
    """One pass over the training pairs in a fresh order."""
    loss_function, optimizer, schedule = optimization
    model.train()
    order = torch.randperm(len(data[0]))
    for start in range(0, len(order), batch):
        index = order[start:start + batch]
        ids, mask, types, target = (t[index].to(device) for t in data)
        logits = model(input_ids=ids, attention_mask=mask, token_type_ids=types).logits[:, 0]
        loss_function(logits, target).backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        optimizer.step()
        schedule.step()
        optimizer.zero_grad()


def train(rows, epochs=3, batch=32, rate=3e-5):
    torch.manual_seed(525)
    tokenizer = Tokenizer()
    fit, held = split(rows)
    print(f'pairs: {len(fit)} training ({sum(r[0] for r in fit)} same event), {len(held)} held out '
          f'({sum(r[0] for r in held)} same event), {len(rows) - len(fit) - len(held)} straddling dropped')
    train_data, held_data = tensors(tokenizer, fit), tensors(tokenizer, held)
    device = torch.device('mps' if torch.backends.mps.is_available() else 'cpu')
    model = BertForSequenceClassification(CONFIG)
    load_shipped(model.bert)
    model.to(device)
    positives = float(train_data[3].sum())
    loss_function = torch.nn.BCEWithLogitsLoss(pos_weight=torch.tensor((len(fit) - positives) / positives, device=device))
    optimizer = torch.optim.AdamW(model.parameters(), lr=rate, weight_decay=0.01)
    steps = epochs * math.ceil(len(fit) / batch)
    schedule = get_linear_schedule_with_warmup(optimizer, int(0.1 * steps), steps)
    # The final epoch of the decayed schedule is kept: picking the best held-out AUC chose an early, overconfident
    # model that merged four tune pairs below a 0.95 cutoff (24 October 2026).
    labels = [bool(r[0]) for r in held]
    for epoch in range(epochs):
        run_epoch(model, train_data, device, (loss_function, optimizer, schedule), batch)
        scores = predict(model, held_data, device)
        print(f'epoch {epoch + 1}: held-out AUC {auc(scores, labels):.4f}; at 0.5 {at_threshold(scores, labels, 0.5)}; '
              f'at 0.9 {at_threshold(scores, labels, 0.9)}')
    return model.cpu().eval(), tokenizer, held


class Scorer(torch.nn.Module):
    """The exported function: the probability that two texts report one event. Embeddings and the attention mask are
    spelled out for a fixed length, because the converter cannot trace the library's shape arithmetic."""

    def __init__(self, model):
        super().__init__()
        self.model = model
        self.register_buffer('positions', torch.arange(MAX_LENGTH).unsqueeze(0))

    def forward(self, input_ids, attention_mask, token_type_ids):
        bert = self.model.bert
        embeddings = (bert.embeddings.word_embeddings(input_ids) + bert.embeddings.position_embeddings(self.positions)
                      + bert.embeddings.token_type_embeddings(token_type_ids))
        hidden = bert.embeddings.LayerNorm(embeddings)
        blocked = (1.0 - attention_mask[:, None, None, :].to(hidden.dtype)) * -10000.0
        for layer in bert.encoder.layer:
            output = layer(hidden, attention_mask=blocked)
            hidden = output[0] if isinstance(output, tuple) else output  # transformers 5 returns the tensor alone
        logits = self.model.classifier(bert.pooler(hidden))
        return torch.sigmoid(logits[:, 0])


def export(model, tokenizer, held, out):
    scorer = Scorer(model).eval()
    example = tuple(torch.tensor([v]) for v in tokenizer.encode_ids(held[0][2], held[0][3]))
    traced = torch.jit.trace(scorer, example)
    inputs = [ct.TensorType(name=n, shape=(1, MAX_LENGTH), dtype=np.int32)
              for n in ('input_ids', 'attention_mask', 'token_type_ids')]
    mlmodel = ct.convert(
        traced, inputs=inputs, outputs=[ct.TensorType(name='probability')], convert_to='mlprogram',
        minimum_deployment_target=ct.target.macOS15, compute_precision=ct.precision.FLOAT16)
    mlmodel.short_description = 'Probability that two news reports describe one event (#525)'
    mlmodel.author = 'News'
    mlmodel.license = 'Derived from sentence-transformers/all-MiniLM-L6-v2, Apache License 2.0'
    path = pathlib.Path(out) / 'pairscorer.mlpackage'
    mlmodel.save(str(path))
    worst = 0.0
    for _, _, a, b in held[:64]:
        ids, mask, types = tokenizer.encode_ids(a, b)
        with torch.no_grad():
            ours = float(scorer(torch.tensor([ids]), torch.tensor([mask]), torch.tensor([types]))[0])
        theirs = float(np.ravel(mlmodel.predict({
            'input_ids': np.array([ids], dtype=np.int32), 'attention_mask': np.array([mask], dtype=np.int32),
            'token_type_ids': np.array([types], dtype=np.int32)})['probability'])[0])
        worst = max(worst, abs(ours - theirs))
    require(worst < 0.05, f'Core ML and PyTorch differ by {worst:.3f}')
    print(f'wrote {path}; Core ML matches PyTorch within {worst:.4f} on 64 held-out pairs')


def self_check():
    tokenizer = Tokenizer()
    require(tokenizer.words('Erdoğan, Sánchez!') == ['erdogan', ',', 'sanchez', '!'], 'Words fold and split as Swift')
    ids, mask, types = tokenizer.encode_pair('a ' * 300, 'b ' * 10)
    require(len(ids) == MAX_LENGTH and sum(mask) == MAX_LENGTH and types.count(1) == 11, 'Longest-first truncation')
    require(abs(auc([0.1, 0.4, 0.35, 0.8], [False, False, True, True]) - 0.75) < 1e-9, 'AUC by ranks')
    rows = [(1, 'g', [7, 8], [9]), (0, 'h', [10], [11, 12])]
    fit, held = split(rows)
    require(not {tuple(r[2]) for r in fit} & {tuple(r[2]) for r in held}, 'No held-out text is trained on')
    print('Pair model training self-check passed')


if __name__ == '__main__':
    if sys.argv[1:] == ['--check-shipped']:
        check_shipped()
    elif len(sys.argv) == 3:
        rows = read_pairs(sys.argv[1])
        trained, tok, held_out = train(rows)
        torch.save(trained.state_dict(), pathlib.Path(sys.argv[2]) / 'pairscorer-state.pt')
        export(trained, tok, held_out, sys.argv[2])
    elif len(sys.argv) == 4 and sys.argv[1] == '--export':
        rows = read_pairs(sys.argv[2])
        model = BertForSequenceClassification(CONFIG)
        state = pathlib.Path(sys.argv[3]).resolve() / 'pairscorer-state.pt'
        require(state.is_file(), 'Train first: the output directory has no pairscorer-state.pt')
        model.load_state_dict(torch.load(state, weights_only=True))
        export(model.eval(), Tokenizer(), split(rows)[1], sys.argv[3])
    elif len(sys.argv) == 1:
        self_check()
    else:
        sys.exit('usage: train_pair_model.py PAIRS.csv OUT_DIR | --export PAIRS.csv OUT_DIR | --check-shipped')
