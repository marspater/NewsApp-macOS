#!/usr/bin/env python3
"""Train the in-house pair cross-encoder (#525) from the shipped MiniLM weights and export it to Core ML.

Mars's Mac only, never CI: run it from a virtual environment built from `script/training/requirements.txt`.

`train_pair_model.py PAIRS.csv OUT_DIR [--pretrain A.csv B.csv ...]` reads the private `./test.sh --export-pairs` CSV
(headline and lead text with the app's own word pieces, `weight` and `marginal` columns), fine-tunes a three-way pair
classifier (#627: different, related, same) initialized from `Sources/Resources/Models/minilm.mlmodelc`, reports numbers
on a tenth of the articles held out (an in-distribution check, not the gate), writes OUT_DIR/pairscorer.mlpackage (one
output, `probabilities`: different, related, same), OUT_DIR/metadata.json (inputs with SHA-256, epochs, rates, versions,
held-out numbers) and checks that Core ML and PyTorch agree. With `--pretrain` (#624) the model first trains on the
public pretraining CSVs from `pretrain_pairs.py` (stage 1) and saves OUT_DIR/pretrain-state.pt; `--init STATE.pt`
starts stage 2 from such a state instead. Stage 2 trains on the library pairs at 1.5e-5 with the embeddings and the
first two encoder layers frozen. The loss is cross-entropy against the classes a row allows (a partial label sums its
classes' probabilities), label-smoothed by 0.05 and scaled by the row weight, with no class weight on top. GDELT hard
negatives (group `g:`, partial `01`) whose shipped-MiniLM cosine is below 0.55 count as exact `different`.
`--exclude-headlines FILE` (folded headlines of the library holdout and the tune corpus, one a line) leaves out every
row of every input that names one: GDELT pages carry the same headlines. Tune and holdout never enter training; the
cutoff is chosen afterwards on tune and on the held-out sweep, and the Swift replay against the library holdout is the
gate.
`train_pair_model.py --check-shipped [MODEL.mlmodelc]` checks the weight import alone against the shipped encoder, or
against another compiled encoder (one flexible-length function, or one function per enumerated length, #554).

Pairs CSV contract (#627), written by `./test.sh --export-pairs`, `pretrain_pairs.py` and `sample_pairs.py --labels`:
    label,group,text_a,text_b,pieces_a,pieces_b,weight,marginal
`label` is a class id as the #551 review protocol labels a pair: 0 different (another story, or the same kind of
occurrence elsewhere or at another time), 1 related (another act of the same story), 2 same (one occurrence reported
twice). `marginal` is empty for an exact label, or the class ids (digits) whose summed probability is the target of a
partial label: `12` one story, same or related (WCEP-10 pairs more than 18 h apart); `01` not one occurrence (GDELT hard
negatives, far-apart library negatives, "Not the Same Event" verdicts: none of them says the two reports are different
stories). Reviewed `different` labels and clean same-day negatives stay exact `different`. `label` is then one of those
classes and is only reported. `weight` scales the row's loss (reviewed labels and verdicts 5, same-day negatives 2);
`pieces_*` are the app's word-piece ids, space-separated; `group` names where the row came from. A file without the
`marginal` column is a binary file of the earlier contract: 1 is same (2), 0 is different (0).
Training uses the word pieces the app exported, so it sees exactly the ids the app sends. The tokenizer port below only
serves the shipped-model check and the self-check; `encode_ids` mirrors `BertWordPieceTokenizer.encodePair`.
"""
import argparse
import csv
import dataclasses
import hashlib
import json
import platform
import math
import pathlib
import re
import struct
import sys
import unicodedata
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
CLASSES = ('different', 'related', 'same')
SMOOTHING = 0.05
FROZEN_LAYERS = 2  # stage 2 keeps the embeddings and this many lower encoder layers fixed (#627)
GDELT_DIFFERENT = 0.55  # a GDELT pair below this cosine is a different story, not possibly a related act
STATE = 'pairscorer-state.pt'  # the trained weights beside the exported model


@dataclasses.dataclass(frozen=True)
class Stage:
    """One training stage's hyperparameters: epochs, learning rate, lower encoder layers frozen (with the embeddings)
    and label smoothing."""
    epochs: int
    rate: float
    frozen: int = 0
    smoothing: float = SMOOTHING


def private_file(value):
    """An input file named on the command line, which must be a regular file outside this checkout."""
    path = pathlib.Path(value).expanduser().resolve()
    checkout = pathlib.Path(__file__).resolve().parents[2]
    if not path.is_file() or checkout in path.parents:
        raise argparse.ArgumentTypeError(f'{value} is not a private file outside the checkout')
    return path
CONFIG = BertConfig(
    vocab_size=30522, hidden_size=384, num_hidden_layers=6, num_attention_heads=12, intermediate_size=1536,
    max_position_embeddings=512, type_vocab_size=2, hidden_act='gelu', layer_norm_eps=1e-12, num_labels=3,
    attn_implementation='eager')
CONST = re.compile(
    r'tensor<fp16, \[([0-9, ]+)\]> (\w+) = const\(\)\[name = (?:tensor<string, \[\]>|string)\("\w+"\), '
    r'val = tensor<fp16, \[[0-9, ]+\]>\(BLOBFILE\(path = (?:tensor<string, \[\]>|string)'
    r'\("@model_path/weights/weight.bin"\), offset = (?:tensor<uint64, \[\]>|uint64)\((\d+)\)')


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
        key = re.sub(r'^(model|bert)_', '', name).removesuffix('_to_fp16')
        state[key] = torch.from_numpy(values.astype(np.float32))
    return state


def load_shipped(module, path=SHIPPED):
    """Copies the shipped weights into a `BertModel`; every parameter must be found."""
    state = shipped_state(path=path)
    target = module.state_dict()
    loaded = {key: state[key.replace('.', '_')] for key in target if key.replace('.', '_') in state}
    missing = [key for key, value in module.named_parameters() if key not in loaded]
    require(not missing, f'Shipped weights miss {missing[:3]}')
    module.load_state_dict(loaded, strict=False)


def compiled_functions(path=SHIPPED):
    """A compiled encoder's functions by input length (`length_16` …); a single flexible-length function (the encoder
    before #554) stands under its longest length, 128, which it accepts like any shorter one."""
    description = json.loads((path / 'metadata.json').read_text())
    functions = (description[0] if isinstance(description, list) else description).get('functions') or []
    if not functions:
        return {128: ct.models.CompiledMLModel(str(path))}
    return {int(function['name'].removeprefix('length_')):
            ct.models.CompiledMLModel(str(path), function_name=function['name']) for function in functions}


def check_shipped(path=SHIPPED):
    """The imported weights reproduce the shipped Core ML model's hidden states."""
    tokenizer, bert = Tokenizer(), BertModel(CONFIG, add_pooling_layer=True).eval()
    load_shipped(bert, path=path)
    models = compiled_functions(path)
    for text in ('Erdoğan meets Sánchez in Ankara', 'Magnitude 6.1 earthquake strikes eastern Turkey'):
        ids = tokenizer.encode_single(text)
        with torch.no_grad():
            ours = bert(input_ids=torch.tensor([ids]), attention_mask=torch.ones(1, len(ids), dtype=torch.long))
        length = min(size for size in models if size >= len(ids))
        padded = np.zeros((1, length), dtype=np.int32)
        mask = np.zeros((1, length), dtype=np.int32)
        padded[0, :len(ids)] = ids
        mask[0, :len(ids)] = 1
        theirs = models[length].predict({'input_ids': padded, 'attention_mask': mask})['last_hidden_state']
        difference = np.abs(ours.last_hidden_state.numpy() - theirs[:, :len(ids)]).max()
        require(difference < 0.05, f'Imported weights differ from the shipped model by {difference:.3f}')
        print(f'  shipped parity for {len(ids)} tokens on {path.name}: max difference {difference:.4f}')
    print(f'Shipped MiniLM weights import check passed for {path.name}')


def targets(row):
    """The classes one CSV row allows under the contract above: one class for an exact label, two for a partial one."""
    if 'marginal' not in row:
        return frozenset([2 if row['label'] == '1' else 0])
    label = int(row['label'])
    classes = frozenset(int(c) for c in row['marginal']) if row['marginal'] else frozenset([label])
    require(label in classes and classes <= {0, 1, 2}, f'Bad label {label} with marginal {row["marginal"]!r}')
    return classes


def bits(classes):
    """A set of class ids as a bit mask: different 1, related 2, same 4."""
    return sum(1 << c for c in classes)


EXCLUDED = set()  # --exclude-headlines: folded headlines of the library holdout and the tune corpus
LEFT_OUT = {}  # rows left out per input file for naming one of them


def fold(text):
    """A headline as the leakage check compares it: accents stripped, case folded, words of letters and digits."""
    text = ''.join(c for c in unicodedata.normalize('NFKD', text) if not unicodedata.combining(c)).casefold()
    return ' '.join(re.findall(r'[0-9a-z]+', text))


def read_pairs(path, cap=None):
    """Rows of one CSV as (allowed classes as a bit mask, group, pieces_a, pieces_b, weight); the pieces are int32
    arrays, so a million-pair file fits in memory. With `cap`, a fixed pseudo-random subset of that many rows (CRC-32
    order of the texts). A row whose headline (a text's first line) is in `EXCLUDED` is left out: public pretraining
    data carries the same headlines as the library holdout and the tune corpus (#627)."""
    file = pathlib.Path(path).resolve()
    require(file.suffix == '.csv' and file.is_file(), 'Use the --export-pairs CSV')
    require(not any((parent / '.git').exists() for parent in file.parents), 'Keep the pairs outside Git checkouts')
    csv.field_size_limit(1 << 20)
    def ids(value):
        return np.array(value.split(), dtype=np.int32)
    def named(row):
        return {fold(row['text_a'].split('\n', 1)[0]), fold(row['text_b'].split('\n', 1)[0])} & EXCLUDED
    with file.open(newline='', encoding='utf-8') as handle:
        rows, left_out = [], 0
        for row in csv.DictReader(handle):
            if EXCLUDED and named(row):
                left_out += 1
                continue
            rows.append((bits(targets(row)), row['group'], ids(row['pieces_a']), ids(row['pieces_b']),
                         float(row.get('weight') or 1.0)))
    LEFT_OUT[file.name] = left_out
    if cap and len(rows) > cap:
        rows.sort(key=lambda r: zlib.crc32(r[2].tobytes() + r[3].tobytes()))
        rows = rows[:cap]
    return rows


def describe(path, rows):
    """What `metadata.json` records about one input CSV."""
    file = pathlib.Path(path)
    # read_pairs checked this path already: a CSV outside Git checkouts.
    digest = hashlib.sha256(file.read_bytes()).hexdigest()  # NOSONAR
    return {'file': file.name, 'sha256': digest, 'rows': len(rows), 'targets': kinds(rows),
            'left_out_for_excluded_headline': LEFT_OUT.get(file.name, 0),
            'weight_sum': round(sum(r[4] for r in rows), 1)}


KINDS = {1: 'different', 2: 'related', 4: 'same', 6: 'same or related', 3: 'different or related'}


def kinds(rows):
    """Row counts by target, exact classes and partial labels."""
    counts = {}
    for row in rows:
        counts[KINDS[row[0]]] = counts.get(KINDS[row[0]], 0) + 1
    return dict(sorted(counts.items()))


def describe_state(path):
    """The file name and SHA-256 of an input file `private_file` validated."""
    return {'file': path.name, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}  # NOSONAR


def split(rows):
    """A tenth of the texts is held out, and a pair is held out only when both of its texts are; pairs that straddle
    the split are dropped, so no held-out text was trained on."""
    def held(pieces):
        return zlib.crc32(' '.join(map(str, pieces)).encode()) % 10 == 0  # unchanged since v11: same held-out texts
    fit = [r for r in rows if not held(r[2]) and not held(r[3])]
    return fit, [r for r in rows if held(r[2]) and held(r[3])]


def tensors(tokenizer, rows):
    """[CLS] a [SEP] b [SEP] per row as int32 arrays filled in place (no Python lists of ids), plus the allowed
    classes (a boolean row of three) and weights; one row of 256 ids costs a kilobyte instead of tens."""
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
            torch.tensor([[bool(r[0] & 1 << c) for c in range(3)] for r in rows]),
            torch.tensor([float(r[4]) for r in rows]))


def partial_loss(logits, allowed, smoothing=SMOOTHING):
    """Cross-entropy against the classes a row allows (#627): -log of their summed probability, label-smoothed. For an
    exact label this is `cross_entropy(..., label_smoothing=smoothing)`; a partial label (`01`, `12`) lets the model
    place the mass on either class."""
    logp = torch.log_softmax(logits, dim=1)
    target = torch.logsumexp(logp.masked_fill(~allowed, float('-inf')), dim=1)
    return -(1 - smoothing) * target - smoothing / logp.shape[1] * logp.sum(dim=1)


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
    """Probabilities (different, related, same) per row."""
    model.eval()
    scores = []
    with torch.no_grad():
        for start in range(0, len(data[0]), batch):
            ids, mask, types = (t[start:start + batch].to(device) for t in data[:3])
            logits = model(input_ids=ids.long(), attention_mask=mask.long(), token_type_ids=types.long()).logits
            scores.extend(torch.softmax(logits.float(), dim=1).cpu().tolist())
    return scores


def held_out_line(name, epoch, probabilities, masks):
    """Same against not same (rows that allow only `same` against rows that exclude it, on p_same) and one story
    against different (rows within same-or-related against exact `different`, on p_same + p_related)."""
    same = [(p[2], m == 4) for p, m in zip(probabilities, masks, strict=True) if m == 4 or not m & 4]
    story = [(p[1] + p[2], not m & 1) for p, m in zip(probabilities, masks, strict=True) if m == 1 or not m & 1]
    def numbers(pairs):
        scores, labels = [s for s, _ in pairs], [y for _, y in pairs]
        return auc(scores, labels), at_threshold(scores, labels, 0.9)
    same_auc, same_at = numbers(same)
    story_auc, story_at = numbers(story)
    return (f'{name} epoch {epoch}: same AUC {same_auc:.4f}, at 0.9 {same_at}; one story AUC {story_auc:.4f}, at 0.9 '
            f'{story_at}'), round(same_auc, 4), round(story_auc, 4)


# Admission rules for a three-way model (#627): `same` admits on p_same; `story` admits on p_same + p_related when
# same outweighs related and p_different is at most 0.10. The cutoff is chosen on tune and on this held-out sweep.
def admits_same(p, cutoff):
    return p[2] >= cutoff


def admits_story(p, cutoff):
    return p[1] + p[2] >= cutoff and p[2] > p[1] and p[0] <= 0.10


RULES = (('same', admits_same, (0.5, 0.6, 0.7, 0.8, 0.85, 0.9, 0.95)),
         ('story', admits_story, (0.8, 0.85, 0.9, 0.93, 0.95, 0.97)))


def sweep(probabilities, masks):
    """Rows that allow only `same` against rows that exclude it, admitted under each rule and cutoff."""
    rows = [(p, m == 4) for p, m in zip(probabilities, masks, strict=True) if m == 4 or not m & 4]
    positives = sum(1 for _, same in rows if same)
    lines = []
    for name, admits, cutoffs in RULES:
        for cutoff in cutoffs:
            admitted = [same for p, same in rows if admits(p, cutoff)]
            tp = sum(admitted)
            lines.append(f'{name} >= {cutoff}: TP {tp}, FP {len(admitted) - tp}, FN {positives - tp}')
    return lines


def run_epoch(model, data, device, optimization, batch):
    """One pass over the training pairs in a fresh order."""
    optimizer, schedule, smoothing = optimization
    model.train()
    order = torch.randperm(len(data[0]))
    for start in range(0, len(order), batch):
        index = order[start:start + batch]
        ids, mask, types, allowed, weight = (t[index].to(device) for t in data)
        logits = model(input_ids=ids.long(), attention_mask=mask.long(), token_type_ids=types.long()).logits
        # Per-row weights (#624): reviewed labels and reader verdicts count five times, same-day negatives twice; no
        # class weight multiplies them (#627).
        (partial_loss(logits, allowed, smoothing) * weight).sum().div(weight.sum().clamp(min=1.0)).backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        optimizer.step()
        schedule.step()
        optimizer.zero_grad()


def fit_stage(model, tokenizer, rows, device, stage, name, report):
    """One training stage on `rows`; per-epoch held-out numbers are printed and the last ones recorded. With
    `stage.frozen`, the embeddings and that many lower encoder layers keep their weights (#627)."""
    epochs, rate, frozen, smoothing = stage.epochs, stage.rate, stage.frozen, stage.smoothing
    fit, held = split(rows)
    print(f'{name}: {len(fit)} training {kinds(fit)}, {len(held)} held out {kinds(held)}, '
          f'{len(rows) - len(fit) - len(held)} straddling dropped')
    require(fit and held, f'{name}: too few pairs to train and hold out')
    for parameter in model.parameters():
        parameter.requires_grad = True
    for module in [model.bert.embeddings, *model.bert.encoder.layer[:frozen]] if frozen else []:
        for parameter in module.parameters():
            parameter.requires_grad = False
    train_data, held_data = tensors(tokenizer, fit), tensors(tokenizer, held)
    optimizer = torch.optim.AdamW([p for p in model.parameters() if p.requires_grad], lr=rate, weight_decay=0.01)
    steps = epochs * math.ceil(len(fit) / BATCH)
    schedule = get_linear_schedule_with_warmup(optimizer, int(0.1 * steps), steps)
    # The final epoch of the decayed schedule is kept: picking the best held-out AUC chose an early, overconfident
    # model that merged four tune pairs below a 0.95 cutoff (24 October 2026).
    masks = [r[0] for r in held]
    for epoch in range(epochs):
        run_epoch(model, train_data, device, (optimizer, schedule, smoothing), BATCH)
        probabilities = predict(model, held_data, device)
        line, same_auc, story_auc = held_out_line(name, epoch + 1, probabilities, masks)
        print(line, flush=True)
        report[name] = {'epochs': epochs, 'rate': rate, 'frozen_layers': frozen, 'smoothing': smoothing,
                        'training': len(fit), 'held_out': len(held), 'held_out_same_auc': same_auc,
                        'held_out_story_auc': story_auc, 'last_epoch': line, 'sweep': sweep(probabilities, masks)}
    print('\n'.join(report[name]['sweep']))
    return held


def sharpen_gdelt(rows, tokenizer, device, batch=256):
    """GDELT hard negatives (group `g:`) allow different or related (#627); a pair whose shipped-MiniLM cosine (mean
    pooled and normalized like `SentenceEmbedder`) is below `GDELT_DIFFERENT` is read as exact `different`."""
    indices = [i for i, r in enumerate(rows) if r[1].startswith('g:') and r[0] == 3]
    if not indices:
        return rows, 0
    encoder = BertModel(CONFIG, add_pooling_layer=True)
    load_shipped(encoder)
    encoder.to(device).eval()

    def embed(pieces):
        vectors = []
        for start in range(0, len(pieces), batch):
            chunk = [[tokenizer.cls, *list(p)[:126], tokenizer.sep] for p in pieces[start:start + batch]]
            width = max(map(len, chunk))
            ids = torch.tensor([c + [tokenizer.pad] * (width - len(c)) for c in chunk], device=device)
            mask = torch.tensor([[1] * len(c) + [0] * (width - len(c)) for c in chunk], device=device)
            with torch.no_grad():
                hidden = encoder(input_ids=ids, attention_mask=mask).last_hidden_state
            pooled = (hidden * mask[..., None]).sum(1) / mask.sum(1, keepdim=True)
            vectors.append(torch.nn.functional.normalize(pooled, dim=1).cpu())
        return torch.cat(vectors)
    a, b = embed([rows[i][2] for i in indices]), embed([rows[i][3] for i in indices])
    cosines = (a * b).sum(1).tolist()
    rows = list(rows)
    sharpened = 0
    for index, cosine in zip(indices, cosines, strict=True):
        if cosine < GDELT_DIFFERENT:
            rows[index] = (1, *rows[index][1:])
            sharpened += 1
    print(f'GDELT: {sharpened} of {len(indices)} hard negatives below cosine {GDELT_DIFFERENT} read as different')
    return rows, sharpened


def train(rows, library=Stage(3, 1.5e-5, FROZEN_LAYERS), pretrain=None, pretraining=Stage(2, 3e-5), init=None,
          out=None):
    """Stage 1 on the public pretraining pairs when given (#624; saved as `pretrain-state.pt` in `out`), or the
    state `init`, then stage 2 on the library pairs with the lower layers frozen (#627)."""
    torch.manual_seed(525)
    tokenizer = Tokenizer()
    device = torch.device('mps' if torch.backends.mps.is_available() else 'cpu')
    model = BertForSequenceClassification(CONFIG)
    load_shipped(model.bert)
    if init:
        model.load_state_dict(torch.load(init, weights_only=True))
    model.to(device)
    report = {}
    if pretrain:
        pretrain, report['gdelt_sharpened'] = sharpen_gdelt(pretrain, tokenizer, device)
        fit_stage(model, tokenizer, pretrain, device, pretraining, 'pretrain', report)
        if out:
            torch.save(model.state_dict(), pathlib.Path(out) / 'pretrain-state.pt')
    held = fit_stage(model, tokenizer, rows, device, library, 'library', report)
    return model.cpu().eval(), tokenizer, held, report


class Scorer(torch.nn.Module):
    """The exported function: the probabilities that two texts are different stories, related acts of one story, or
    one event (#627). Embeddings and the attention mask are spelled out for a fixed length, because the converter
    cannot trace the library's shape arithmetic."""

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
        return torch.softmax(logits, dim=1)


def export(model, tokenizer, held, out):
    scorer = Scorer(model).eval()
    example = tuple(torch.tensor([v]) for v in tokenizer.encode_ids(held[0][2], held[0][3]))
    traced = torch.jit.trace(scorer, example)
    inputs = [ct.TensorType(name=n, shape=(1, MAX_LENGTH), dtype=np.int32)
              for n in ('input_ids', 'attention_mask', 'token_type_ids')]
    mlmodel = ct.convert(
        traced, inputs=inputs, outputs=[ct.TensorType(name='probabilities')], convert_to='mlprogram',
        minimum_deployment_target=ct.target.macOS15, compute_precision=ct.precision.FLOAT16)
    mlmodel.short_description = 'Probabilities that two news reports are different, related or one event (#627)'
    mlmodel.author = 'News'
    mlmodel.license = 'Derived from sentence-transformers/all-MiniLM-L6-v2, Apache License 2.0'
    path = pathlib.Path(out) / 'pairscorer.mlpackage'
    mlmodel.save(str(path))
    worst = 0.0
    for row in held[:64]:
        a, b = row[2], row[3]
        ids, mask, types = tokenizer.encode_ids(a, b)
        with torch.no_grad():
            ours = scorer(torch.tensor([ids]), torch.tensor([mask]), torch.tensor([types]))[0].numpy()
        theirs = np.ravel(mlmodel.predict({
            'input_ids': np.array([ids], dtype=np.int32), 'attention_mask': np.array([mask], dtype=np.int32),
            'token_type_ids': np.array([types], dtype=np.int32)})['probabilities'])
        worst = max(worst, float(np.abs(ours - theirs).max()))
    require(worst < 0.05, f'Core ML and PyTorch differ by {worst:.3f}')
    print(f'wrote {path}; Core ML matches PyTorch within {worst:.4f} on 64 held-out pairs')


def self_check():
    tokenizer = Tokenizer()
    require(tokenizer.words('Erdoğan, Sánchez!') == ['erdogan', ',', 'sanchez', '!'], 'Words fold and split as Swift')
    ids, mask, types = tokenizer.encode_pair('a ' * 300, 'b ' * 10)
    require(len(ids) == MAX_LENGTH and sum(mask) == MAX_LENGTH and types.count(1) == 11, 'Longest-first truncation')
    require(abs(auc([0.1, 0.4, 0.35, 0.8], [False, False, True, True]) - 0.75) < 1e-9, 'AUC by ranks')
    rows = [(4, 'g', np.array([7, 8], dtype=np.int32), np.array([9], dtype=np.int32), 1.0),
            (3, 'h', np.array([10], dtype=np.int32), np.array([11, 12], dtype=np.int32), 5.0)]
    fit, held = split(rows)
    require(not {tuple(r[2]) for r in fit} & {tuple(r[2]) for r in held}, 'No held-out text is trained on')
    built = tensors(tokenizer, rows)
    require(built[4].tolist() == [1.0, 5.0], 'Row weights travel with the tensors')
    require(built[0][0, :6].tolist() == [tokenizer.cls, 7, 8, tokenizer.sep, 9, tokenizer.sep]
            and built[2][0, :6].tolist() == [0, 0, 0, 0, 1, 1] and int(built[1][0].sum()) == 6,
            'Tensors match encode_ids')
    require(built[0][0].tolist() == tokenizer.encode_ids([7, 8], [9])[0], 'Array rows equal the list encoder')
    require([targets(r) for r in ({'label': '1'}, {'label': '0'}, {'label': '2', 'marginal': ''},
                                  {'label': '1', 'marginal': '12'}, {'label': '0', 'marginal': '01'})]
            == [{2}, {0}, {2}, {1, 2}, {0, 1}], 'Binary and three-way rows read by the contract')
    require(built[3].tolist() == [[False, False, True], [True, True, False]], 'Allowed classes travel as masks')
    logits = torch.tensor([[0.3, -1.0, 2.0], [1.5, 0.2, -0.4]])
    exact = torch.tensor([[False, False, True], [True, False, False]])
    expected = torch.nn.functional.cross_entropy(logits, torch.tensor([2, 0]), reduction='none',
                                                 label_smoothing=SMOOTHING)
    require(torch.allclose(partial_loss(logits, exact), expected), 'An exact label is smoothed cross-entropy')
    story = torch.tensor([[False, True, True]])
    require(float(partial_loss(torch.tensor([[-9.0, 4.0, 0.0]]), story, 0.0)) < 0.02
            and float(partial_loss(torch.tensor([[-9.0, 0.0, 4.0]]), story, 0.0)) < 0.02
            and float(partial_loss(torch.tensor([[4.0, 0.0, 0.0]]), story, 0.0)) > 3,
            'A partial label sums its classes')
    require(fold('Erdoğan meets Sánchez, again!') == 'erdogan meets sanchez again',
            'Headlines fold for the leak check')
    swept = sweep([[0.02, 0.08, 0.90], [0.05, 0.60, 0.35], [0.30, 0.05, 0.65]], [4, 2, 1])
    require('same >= 0.9: TP 1, FP 0, FN 0' in swept and 'same >= 0.6: TP 1, FP 1, FN 0' in swept
            and 'story >= 0.9: TP 1, FP 0, FN 0' in swept, 'Held-out sweep under both admission rules')
    print('Pair model training self-check passed')


def main(argv):
    """PAIRS.csv OUT_DIR [--pretrain A.csv ...] [--init STATE.pt]: train, export and write metadata.json."""
    parser = argparse.ArgumentParser()
    parser.add_argument('pairs')
    parser.add_argument('out')
    parser.add_argument('--pretrain', nargs='*', default=[])
    parser.add_argument('--pretrain-epochs', type=int, default=2)
    parser.add_argument('--pretrain-cap', type=int, default=120_000, help='rows kept per pretraining CSV')
    parser.add_argument('--epochs', type=int, default=3)
    parser.add_argument('--rate', type=float, default=1.5e-5)
    parser.add_argument('--init', type=private_file,
                        help='a pretrain-state.pt to start stage 2 from instead of stage 1')
    parser.add_argument('--exclude-headlines', type=private_file,
                        help='folded headlines, one a line, whose rows are left out (#627)')
    parser.add_argument('--frozen', type=int, default=FROZEN_LAYERS, help='lower encoder layers frozen in stage 2')
    parser.add_argument('--smoothing', type=float, default=SMOOTHING, help='label smoothing of the stage-2 loss')
    parser.add_argument('--sweep', action='store_true',
                        help=f'no training: the held-out sweep of OUT_DIR/{STATE} on PAIRS.csv')
    args = parser.parse_args(argv)
    if args.exclude_headlines:
        EXCLUDED.update(line.strip() for line in args.exclude_headlines.read_text().splitlines())  # NOSONAR
        EXCLUDED.discard('')
    rows = read_pairs(args.pairs)
    if args.sweep:
        model = BertForSequenceClassification(CONFIG)
        model.load_state_dict(torch.load(pathlib.Path(args.out) / STATE, weights_only=True))
        device = torch.device('mps' if torch.backends.mps.is_available() else 'cpu')
        held = split(rows)[1]
        print('\n'.join(sweep(predict(model.to(device), tensors(Tokenizer(), held), device), [r[0] for r in held])))
        return
    pretrain = [r for path in args.pretrain for r in read_pairs(path, cap=args.pretrain_cap)]
    trained, tok, held_out, report = train(
        rows, Stage(args.epochs, args.rate, args.frozen, args.smoothing), pretrain or None,
        Stage(args.pretrain_epochs, 3e-5), args.init, args.out)
    out = pathlib.Path(args.out)
    torch.save(trained.state_dict(), out / STATE)
    export(trained, tok, held_out, args.out)
    metadata = {
        'model': 'pairscorer', 'base': 'sentence-transformers/all-MiniLM-L6-v2 (shipped minilm.mlmodelc weights)',
        'inputs': {'library': describe(args.pairs, rows),
                   'pretrain': [describe(path, read_pairs(path, cap=args.pretrain_cap)) for path in args.pretrain]},
        'pretrain_cap': args.pretrain_cap, 'init': args.init and describe_state(args.init),
        'excluded_headlines': args.exclude_headlines and describe_state(args.exclude_headlines),
        'classes': list(CLASSES), 'output': 'probabilities', 'smoothing': SMOOTHING,
        'stages': report, 'batch': BATCH,
        'versions': {'python': platform.python_version(), 'torch': torch.__version__,
                     'transformers': __import__('transformers').__version__, 'coremltools': ct.__version__},
    }
    text = json.dumps(metadata, indent=1, sort_keys=True) + '\n'
    # OUT_DIR is the operator's own output directory, named on the command line.
    (out / 'metadata.json').write_text(text)  # NOSONAR
    print(f'wrote {out / "metadata.json"}')


if __name__ == '__main__':
    if len(sys.argv) >= 2 and sys.argv[1] == '--check-shipped':
        path = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else SHIPPED
        check_shipped(path)
    elif len(sys.argv) >= 3 and sys.argv[1] != '--export':
        main(sys.argv[1:])
    elif len(sys.argv) == 4 and sys.argv[1] == '--export':
        rows = read_pairs(sys.argv[2])
        model = BertForSequenceClassification(CONFIG)
        state = pathlib.Path(sys.argv[3]).resolve() / STATE
        require(state.is_file(), f'Train first: the output directory has no {STATE}')
        model.load_state_dict(torch.load(state, weights_only=True))
        export(model.eval(), Tokenizer(), split(rows)[1], sys.argv[3])
    elif len(sys.argv) == 1:
        self_check()
    else:
        sys.exit('usage: train_pair_model.py PAIRS.csv OUT_DIR [--pretrain A.csv ...] | --export PAIRS.csv OUT_DIR '
                 '| --check-shipped')
