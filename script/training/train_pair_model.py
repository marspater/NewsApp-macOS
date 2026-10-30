#!/usr/bin/env python3
"""Train the in-house pair cross-encoder (#525) from the shipped MiniLM weights and export it to Core ML.

Mars's Mac only, never CI: run it from a virtual environment built from `script/training/requirements.txt`.

`train_pair_model.py PAIRS.csv OUT_DIR [--pretrain A.csv B.csv ...]` reads the private `./test.sh --export-pairs` CSV
(headline and lead text with the app's own word pieces, an optional `weight` column), fine-tunes a pair classifier
initialized from `Sources/Resources/Models/minilm.mlmodelc`, reports numbers on a tenth of the articles held out (an
in-distribution check, not the gate), writes OUT_DIR/pairscorer.mlpackage, OUT_DIR/metadata.json (inputs with SHA-256,
epochs, rates, versions, held-out numbers) and checks that Core ML and PyTorch agree. With `--pretrain` (#624) the
model first trains on the public pretraining CSVs from `pretrain_pairs.py` (stage 1, two epochs), then on the library
pairs (stage 2). Tune and holdout never enter any CSV; the cutoff is chosen afterwards by the Swift replay against the
library holdout, which is the gate.
`train_pair_model.py --check-shipped` checks the weight import alone against the shipped model.
Training uses the word pieces the app exported, so it sees exactly the ids the app sends. The tokenizer port below only
serves the shipped-model check and the self-check; `encode_ids` mirrors `BertWordPieceTokenizer.encodePair`.
"""
import csv
import hashlib
import json
import platform
import math
import pathlib
import re
import struct
import sys
import zlib

import coremltools as ct

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from wordpiece import MAX_LENGTH, Tokenizer, require
import numpy as np
import torch
from transformers import (
    BertConfig,
    BertForSequenceClassification,
    BertModel,
    get_linear_schedule_with_warmup,
)

ROOT = pathlib.Path(__file__).resolve().parents[2]
BATCH = 32  # training batch size, both stages
SHIPPED = ROOT / 'Sources/Resources/Models/minilm.mlmodelc'
CONFIG = BertConfig(
    vocab_size=30522, hidden_size=384, num_hidden_layers=6, num_attention_heads=12, intermediate_size=1536,
    max_position_embeddings=512, type_vocab_size=2, hidden_act='gelu', layer_norm_eps=1e-12, num_labels=1,
    attn_implementation='eager')
CONST = re.compile(
    r'tensor<fp16, \[([0-9, ]+)\]> (\w+) = const\(\)\[name = tensor<string, \[\]>\("\w+"\), '
    r'val = tensor<fp16, \[[0-9, ]+\]>\(BLOBFILE\(path = tensor<string, \[\]>\("@model_path/weights/weight.bin"\), '
    r'offset = tensor<uint64, \[\]>\((\d+)\)')


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


def read_pairs(path, cap=None):
    """Rows of one CSV as (label, group, pieces_a, pieces_b, weight); the pieces are int32 arrays, so a million-pair
    file fits in memory. With `cap`, a fixed pseudo-random subset of that many rows (CRC-32 order of the texts)."""
    file = pathlib.Path(path).resolve()
    require(file.suffix == '.csv' and file.is_file(), 'Use the --export-pairs CSV')
    require(not any((parent / '.git').exists() for parent in file.parents), 'Keep the pairs outside Git checkouts')
    csv.field_size_limit(1 << 20)
    def ids(value):
        return np.array(value.split(), dtype=np.int32)
    with file.open(newline='', encoding='utf-8') as handle:
        rows = [(int(row['label']), row['group'], ids(row['pieces_a']), ids(row['pieces_b']),
                 float(row.get('weight') or 1.0))
                for row in csv.DictReader(handle)]
    if cap and len(rows) > cap:
        rows.sort(key=lambda r: zlib.crc32(r[2].tobytes() + r[3].tobytes()))
        rows = rows[:cap]
    return rows


def describe(path, rows):
    """What `metadata.json` records about one input CSV."""
    file = pathlib.Path(path)
    # read_pairs checked this path already: a CSV outside Git checkouts.
    digest = hashlib.sha256(file.read_bytes()).hexdigest()  # NOSONAR
    return {'file': file.name, 'sha256': digest, 'rows': len(rows),
            'positives': sum(r[0] for r in rows), 'weight_sum': round(sum(r[4] for r in rows), 1)}


def split(rows):
    """A tenth of the texts is held out, and a pair is held out only when both of its texts are; pairs that straddle
    the split are dropped, so no held-out text was trained on."""
    def held(pieces):
        return zlib.crc32(' '.join(map(str, pieces)).encode()) % 10 == 0  # unchanged since v11: same held-out texts
    fit = [r for r in rows if not held(r[2]) and not held(r[3])]
    return fit, [r for r in rows if held(r[2]) and held(r[3])]


def tensors(tokenizer, rows):
    """[CLS] a [SEP] b [SEP] per row as int32 arrays filled in place (no Python lists of ids), plus labels and
    weights; one row of 256 ids costs a kilobyte instead of tens."""
    count = len(rows)
    ids = np.zeros((count, MAX_LENGTH), dtype=np.int32)
    mask = np.zeros((count, MAX_LENGTH), dtype=np.int32)
    types = np.zeros((count, MAX_LENGTH), dtype=np.int32)
    for index, row in enumerate(rows):
        pa, pb = list(row[2]), list(row[3])
        while len(pa) + len(pb) > MAX_LENGTH - 3:
            (pa if len(pa) > len(pb) else pb).pop()
        sequence = [tokenizer.cls, *pa, tokenizer.sep, *pb, tokenizer.sep]
        ids[index, :len(sequence)] = sequence
        mask[index, :len(sequence)] = 1
        types[index, len(pa) + 2:len(sequence)] = 1
    return (torch.from_numpy(ids), torch.from_numpy(mask), torch.from_numpy(types),
            torch.tensor([float(r[0]) for r in rows]), torch.tensor([float(r[4]) for r in rows]))


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
    if not positives or not negatives:
        return float('nan')  # a held-out split with one class only (tiny inputs) has no AUC
    return (sum(r for r, y in zip(ranks, labels, strict=True) if y) - positives * (positives + 1) / 2) / (
        positives * negatives)


def at_threshold(scores, labels, cutoff):
    pairs = list(zip(scores, labels, strict=True))
    tp = sum(1 for s, y in pairs if s >= cutoff and y)
    fp = sum(1 for s, y in pairs if s >= cutoff and not y)
    fn = sum(1 for s, y in pairs if s < cutoff and y)
    return f'precision {tp / max(1, tp + fp):.3f} recall {tp / max(1, tp + fn):.3f} (TP {tp}, FP {fp}, FN {fn})'


def predict(model, data, device, batch=64):
    model.eval()
    scores = []
    with torch.no_grad():
        for start in range(0, len(data[0]), batch):
            ids, mask, types = (t[start:start + batch].to(device) for t in data[:3])
            logits = model(input_ids=ids.long(), attention_mask=mask.long(), token_type_ids=types.long()).logits[:, 0]
            scores.extend(torch.sigmoid(logits).float().cpu().tolist())
    return scores


def run_epoch(model, data, device, optimization, batch):
    """One pass over the training pairs in a fresh order."""
    loss_function, optimizer, schedule = optimization
    model.train()
    order = torch.randperm(len(data[0]))
    for start in range(0, len(order), batch):
        index = order[start:start + batch]
        ids, mask, types, target, weight = (t[index].to(device) for t in data)
        logits = model(input_ids=ids.long(), attention_mask=mask.long(), token_type_ids=types.long()).logits[:, 0]
        # Per-row weights (#624): reader verdicts count five times, graded SemEval pairs twice.
        (loss_function(logits, target) * weight).sum().div(weight.sum().clamp(min=1.0)).backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        optimizer.step()
        schedule.step()
        optimizer.zero_grad()


def fit_stage(model, tokenizer, rows, device, epochs, rate, name, report):
    """One training stage on `rows`; per-epoch held-out numbers are printed and the last ones recorded."""
    fit, held = split(rows)
    print(f'{name}: {len(fit)} training ({sum(r[0] for r in fit)} same event), {len(held)} held out '
          f'({sum(r[0] for r in held)} same event), {len(rows) - len(fit) - len(held)} straddling dropped')
    require(fit and held, f'{name}: too few pairs to train and hold out')
    train_data, held_data = tensors(tokenizer, fit), tensors(tokenizer, held)
    positives = float(train_data[3].sum())
    pos_weight = torch.tensor(max(1.0, (len(fit) - positives) / max(1.0, positives)), device=device)
    loss_function = torch.nn.BCEWithLogitsLoss(reduction='none', pos_weight=pos_weight)
    optimizer = torch.optim.AdamW(model.parameters(), lr=rate, weight_decay=0.01)
    steps = epochs * math.ceil(len(fit) / BATCH)
    schedule = get_linear_schedule_with_warmup(optimizer, int(0.1 * steps), steps)
    # The final epoch of the decayed schedule is kept: picking the best held-out AUC chose an early, overconfident
    # model that merged four tune pairs below a 0.95 cutoff (24 October 2026).
    labels = [bool(r[0]) for r in held]
    for epoch in range(epochs):
        run_epoch(model, train_data, device, (loss_function, optimizer, schedule), BATCH)
        scores = predict(model, held_data, device)
        line = (f'{name} epoch {epoch + 1}: held-out AUC {auc(scores, labels):.4f}; at 0.5 '
                f'{at_threshold(scores, labels, 0.5)}; at 0.9 {at_threshold(scores, labels, 0.9)}')
        print(line)
        report[name] = {'epochs': epochs, 'rate': rate, 'training': len(fit), 'held_out': len(held),
                        'held_out_auc': round(auc(scores, labels), 4), 'last_epoch': line}
    return held


def train(rows, epochs=3, rate=3e-5, pretrain=None, pretrain_epochs=2, pretrain_rate=3e-5):
    """Stage 1 on the public pretraining pairs when given (#624), stage 2 on the library pairs."""
    torch.manual_seed(525)
    tokenizer = Tokenizer()
    device = torch.device('mps' if torch.backends.mps.is_available() else 'cpu')
    model = BertForSequenceClassification(CONFIG)
    load_shipped(model.bert)
    model.to(device)
    report = {}
    if pretrain:
        fit_stage(model, tokenizer, pretrain, device, pretrain_epochs, pretrain_rate, 'pretrain', report)
    held = fit_stage(model, tokenizer, rows, device, epochs, rate, 'library', report)
    return model.cpu().eval(), tokenizer, held, report


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
    for row in held[:64]:
        a, b = row[2], row[3]
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
    rows = [(1, 'g', np.array([7, 8], dtype=np.int32), np.array([9], dtype=np.int32), 1.0),
            (0, 'h', np.array([10], dtype=np.int32), np.array([11, 12], dtype=np.int32), 5.0)]
    fit, held = split(rows)
    require(not {tuple(r[2]) for r in fit} & {tuple(r[2]) for r in held}, 'No held-out text is trained on')
    built = tensors(tokenizer, rows)
    require(built[4].tolist() == [1.0, 5.0], 'Row weights travel with the tensors')
    require(built[0][0, :6].tolist() == [tokenizer.cls, 7, 8, tokenizer.sep, 9, tokenizer.sep]
            and built[2][0, :6].tolist() == [0, 0, 0, 0, 1, 1] and int(built[1][0].sum()) == 6,
            'Tensors match encode_ids')
    require(built[0][0].tolist() == tokenizer.encode_ids([7, 8], [9])[0], 'Array rows equal the list encoder')
    print('Pair model training self-check passed')


def main(argv):
    """PAIRS.csv OUT_DIR [--pretrain A.csv ...] [--pretrain-epochs N]: train, export and write metadata.json."""
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('pairs')
    parser.add_argument('out')
    parser.add_argument('--pretrain', nargs='*', default=[])
    parser.add_argument('--pretrain-epochs', type=int, default=2)
    parser.add_argument('--pretrain-cap', type=int, default=120_000, help='rows kept per pretraining CSV')
    parser.add_argument('--epochs', type=int, default=3)
    args = parser.parse_args(argv)
    rows = read_pairs(args.pairs)
    pretrain = [r for path in args.pretrain for r in read_pairs(path, cap=args.pretrain_cap)]
    trained, tok, held_out, report = train(rows, epochs=args.epochs, pretrain=pretrain or None,
                                           pretrain_epochs=args.pretrain_epochs)
    out = pathlib.Path(args.out)
    torch.save(trained.state_dict(), out / 'pairscorer-state.pt')
    export(trained, tok, held_out, args.out)
    metadata = {
        'model': 'pairscorer', 'base': 'sentence-transformers/all-MiniLM-L6-v2 (shipped minilm.mlmodelc weights)',
        'inputs': {'library': describe(args.pairs, rows),
                   'pretrain': [describe(path, read_pairs(path, cap=args.pretrain_cap)) for path in args.pretrain]},
        'pretrain_cap': args.pretrain_cap,
        'stages': report, 'batch': BATCH,
        'versions': {'python': platform.python_version(), 'torch': torch.__version__,
                     'transformers': __import__('transformers').__version__, 'coremltools': ct.__version__},
    }
    text = json.dumps(metadata, indent=1, sort_keys=True) + '\n'
    # OUT_DIR is the operator's own output directory, named on the command line.
    (out / 'metadata.json').write_text(text)  # NOSONAR
    print(f'wrote {out / "metadata.json"}')


if __name__ == '__main__':
    if sys.argv[1:] == ['--check-shipped']:
        check_shipped()
    elif len(sys.argv) >= 3 and sys.argv[1] != '--export':
        main(sys.argv[1:])
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
        sys.exit('usage: train_pair_model.py PAIRS.csv OUT_DIR [--pretrain A.csv ...] | --export PAIRS.csv OUT_DIR '
                 '| --check-shipped')
