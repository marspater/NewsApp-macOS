#!/usr/bin/env python3
"""Fine-tune the sentence encoder on news pairs (#628, M18) and export it like `convert_minilm.py`.
Mars's Mac only, never CI: run it from the virtual environment built from `script/training/requirements.txt`.

`train_embedding.py OUT_DIR --pairs A.csv [B.csv ...] --exclude-headlines FILE --holdout HOLDOUT.json
--tune-corpus CORPUS.json` starts from
`sentence-transformers/all-MiniLM-L6-v2` at the revision `convert_minilm.py` pins (the weights the app ships) and
trains the mean-pooled, normalized vector `SentenceEmbedder.embed` returns on rows of the pairs contract
(`train_pair_model.py`):
- positives: exact `same` rows (label 2, no marginal): cross-publisher rule matches of a re-clustered library copy
  (`--export-pairs`, group `e:`) and reviewed `same` labels (`sample_pairs.py --labels`, group `r:`, weight 5);
- hard negatives: exact `different` rows (label 0, no marginal): clean same-day cross-story negatives (`s:`, weight 2)
  and reviewed `different` labels, plus GDELT same-actor negatives (`g:`, partial `01`: never one occurrence).
Related acts (label 1), far-apart negatives (`n:`) and WCEP-10 rows (no dates, so the 18 h rule cannot be applied)
are left out. The loss is in-batch contrastive (each positive's partner against every other text of the batch, both
directions, scale 20; texts of one event are never each other's negatives) plus CoSENT over the batch's labelled pairs,
which ranks every positive's cosine above every hard negative's, each row scaled by its weight.
Rows naming a headline of `--exclude-headlines` (folded headlines of the library holdout and the tune corpus), of the
library holdout file or of the corpus's tune split are left out, and the run fails if one remains. A tenth of the texts (CRC-32) is held out and
reported against the base model: cosine AUC and the share of pairs above the 0.55 veto and the 0.70 rescue.
Writes OUT_DIR/minilm.mlpackage (one function per length, `convert_minilm.convert`), OUT_DIR/embedding-state.pt and
OUT_DIR/metadata.json (inputs with SHA-256, counts, held-out numbers, versions). A model ships only after the Swift
gates and with `SentenceEmbedder.modelVersion` bumped.
`train_embedding.py --self-check` trains a tiny random encoder on synthetic rows, without downloads.
"""
import argparse
import csv
import hashlib
import itertools
import json
import math
import pathlib
import platform
import re
import sys
import unicodedata
import zlib

import numpy as np
import torch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from convert_minilm import LENGTHS, MAX_TOKENS, convert, describe
from wordpiece import Tokenizer, require

SCALE = 20.0  # cosine temperature of both losses (1/0.05)
BATCH = 32  # positive pairs per step, with as many hard negative pairs
csv.field_size_limit(sys.maxsize)


def fold(text):
    """A headline as the leakage check compares it (`train_pair_model.fold`): accents stripped, case folded, words."""
    text = ''.join(c for c in unicodedata.normalize('NFKD', text) if not unicodedata.combining(c)).casefold()
    return ' '.join(re.findall(r'[0-9a-z]+', text))


def headline(text):
    return fold(text.split('\n', 1)[0])


def kind(row):
    """'positive', 'negative' or None (left out) for one CSV row, by the rules in the module docstring."""
    group, label, marginal = row['group'], row['label'], row.get('marginal') or ''
    if group.startswith(('n:', 'w:')):
        return None
    if label == '2' and not marginal:
        return 'positive'
    if (label == '0' and not marginal) or group.startswith('g:'):
        return 'negative'
    return None


def read_rows(paths, excluded):
    """Training rows as dicts (kind, group, a, b, weight) and per-file counts; a row naming an excluded headline is
    dropped and counted."""
    rows, counts = [], {}
    for path in paths:
        tally = {'positive': 0, 'negative': 0, 'left_out': 0, 'excluded_headline': 0}
        with open(path, newline='', encoding='utf-8') as handle:
            for row in csv.DictReader(handle):
                which = kind(row)
                if which is None:
                    tally['left_out'] += 1
                elif headline(row['text_a']) in excluded or headline(row['text_b']) in excluded:
                    tally['excluded_headline'] += 1
                else:
                    tally[which] += 1
                    rows.append({'kind': which, 'group': row['group'], 'a': row['text_a'], 'b': row['text_b'],
                                 'weight': float(row.get('weight') or 1)})
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        counts[path.name] = {'sha256': digest, **tally}
    return rows, counts


def private_file(value):
    """An input file, which must be a regular file outside this checkout."""
    path = pathlib.Path(value).expanduser().resolve()
    checkout = pathlib.Path(__file__).resolve().parents[2]
    if not path.is_file() or checkout in path.parents:
        raise argparse.ArgumentTypeError(f'{value} is not a private file outside the checkout')
    return path


def held(text):
    return zlib.crc32(text.encode()) % 10 == 0


def split(rows):
    """A tenth of the texts is held out; a pair is held out when both texts are, dropped when it straddles."""
    fit = [r for r in rows if not held(r['a']) and not held(r['b'])]
    return fit, [r for r in rows if held(r['a']) and held(r['b'])]


def embed(bert, tokenizer, texts, device):
    """Mean over the tokens present, L2-normalized: `SentenceEmbedder.embed` in PyTorch."""
    ids = [tokenizer.encode_single(t, max_length=MAX_TOKENS) for t in texts]
    width = max(len(i) for i in ids)
    tokens = torch.zeros(len(ids), width, dtype=torch.long)
    mask = torch.zeros(len(ids), width, dtype=torch.long)
    for row, sequence in enumerate(ids):
        tokens[row, :len(sequence)], mask[row, :len(sequence)] = torch.tensor(sequence), 1
    tokens, mask = tokens.to(device), mask.to(device)
    hidden = bert(input_ids=tokens, attention_mask=mask).last_hidden_state
    weights = mask.unsqueeze(-1).to(hidden.dtype)
    return torch.nn.functional.normalize((hidden * weights).sum(1) / weights.sum(1), dim=-1)


def losses(bert, tokenizer, positives, negatives, device):
    """In-batch contrastive loss over the positives plus CoSENT over every labelled pair of the batch."""
    a = embed(bert, tokenizer, [r['a'] for r in positives], device)
    b = embed(bert, tokenizer, [r['b'] for r in positives], device)
    weights = torch.tensor([r['weight'] for r in positives], device=device)
    logits = SCALE * a @ b.T
    groups = [r['group'] for r in positives]
    same = torch.tensor([[gi == gj and i != j for j, gj in enumerate(groups)] for i, gi in enumerate(groups)],
                        device=device)
    logits = logits.masked_fill(same, -1e4)  # two reports of one event are not each other's negatives
    target = torch.arange(len(positives), device=device)
    contrastive = ((torch.nn.functional.cross_entropy(logits, target, reduction='none')
                    + torch.nn.functional.cross_entropy(logits.T, target, reduction='none')) / 2 * weights).sum()
    contrastive = contrastive / weights.sum()
    cosines = (a * b).sum(-1)
    if negatives:
        na = embed(bert, tokenizer, [r['a'] for r in negatives], device)
        nb = embed(bert, tokenizer, [r['b'] for r in negatives], device)
        negative_cosines = (na * nb).sum(-1)
        negative_weights = torch.tensor([r['weight'] for r in negatives], device=device)
        gaps = SCALE * (negative_cosines[:, None] - cosines[None, :])
        pair_weights = negative_weights[:, None] * weights[None, :]
        cosent = torch.logsumexp(torch.cat([torch.zeros(1, device=device),
                                            (gaps + pair_weights.log()).flatten()]), 0)
    else:
        cosent = torch.zeros((), device=device)
    return contrastive, cosent


def cosines(bert, tokenizer, rows, device, batch=64):
    bert.eval()
    out = []
    with torch.no_grad():
        for start in range(0, len(rows), batch):
            chunk = rows[start:start + batch]
            a = embed(bert, tokenizer, [r['a'] for r in chunk], device)
            b = embed(bert, tokenizer, [r['b'] for r in chunk], device)
            out.extend((a * b).sum(-1).cpu().tolist())
    return out


def evaluate(bert, tokenizer, rows, device):
    """Cosine AUC and the share of positives and negatives at the 0.55 veto and the 0.70 rescue."""
    from train_pair_model import auc
    scores = cosines(bert, tokenizer, rows, device)
    labels = [r['kind'] == 'positive' for r in rows]
    report = {'pairs': len(rows), 'positives': sum(labels), 'auc': round(auc(scores, labels), 4)}
    for cutoff in (0.55, 0.70):
        report[f'positives_at_{cutoff}'] = round(float(np.mean([s >= cutoff for s, y in zip(scores, labels) if y])), 4)
        report[f'negatives_at_{cutoff}'] = round(float(np.mean([s >= cutoff for s, y in zip(scores, labels) if not y])), 4)
    report['positive_cosine_median'] = round(float(np.median([s for s, y in zip(scores, labels) if y])), 4)
    report['negative_cosine_median'] = round(float(np.median([s for s, y in zip(scores, labels) if not y])), 4)
    return report


def train(bert, tokenizer, rows, device, epochs, rate, seed=628):
    """`epochs` passes over the positives in a fixed shuffled order, each batch with as many hard negatives."""
    generator = np.random.default_rng(seed)
    positives = [r for r in rows if r['kind'] == 'positive']
    negatives = [r for r in rows if r['kind'] == 'negative']
    steps = epochs * math.ceil(len(positives) / BATCH)
    optimizer = torch.optim.AdamW(bert.parameters(), lr=rate, weight_decay=0.01)
    warmup = max(1, steps // 10)
    schedule = torch.optim.lr_scheduler.LambdaLR(
        optimizer, lambda step: min((step + 1) / warmup, max(0.0, (steps - step) / max(1, steps - warmup))))
    history = []
    for epoch in range(epochs):
        order = generator.permutation(len(positives))
        negative_order = generator.permutation(len(negatives)) if negatives else []
        bert.train()
        total = [0.0, 0.0]
        for step, start in enumerate(range(0, len(order), BATCH)):
            batch = [positives[i] for i in order[start:start + BATCH]]
            picked = [negatives[negative_order[(step * BATCH + k) % len(negatives)]] for k in range(BATCH)] \
                if negatives else []
            contrastive, cosent = losses(bert, tokenizer, batch, picked, device)
            loss = contrastive + cosent
            optimizer.zero_grad()
            loss.backward()
            torch.nn.utils.clip_grad_norm_(bert.parameters(), 1.0)
            optimizer.step()
            schedule.step()
            total[0] += contrastive.item()
            total[1] += cosent.item()
        batches = math.ceil(len(order) / BATCH)
        history.append({'epoch': epoch + 1, 'contrastive': round(total[0] / batches, 4),
                        'cosent': round(total[1] / batches, 4)})
        print(f'epoch {epoch + 1}: contrastive {history[-1]["contrastive"]}, cosent {history[-1]["cosent"]}',
              flush=True)
    return history


def holdout_headlines(path):
    """Both headlines of every library-holdout pair (#579), folded."""
    return {fold(item[key]) for item in json.loads(path.read_text()) for key in ('title_a', 'title_b')}


def tune_headlines(path):
    """The folded headlines of the tune split of the private corpus; the holdout split's entries are skipped."""
    return {fold(item['title']) for item in json.loads(path.read_text())['articles']
            if item.get('split') == 'tune'}


def main(argv):
    from convert_minilm import HUB_MODEL, HUB_REVISION
    from transformers import BertModel
    parser = argparse.ArgumentParser()
    parser.add_argument('out')
    parser.add_argument('--pairs', nargs='+', required=True, type=private_file)
    parser.add_argument('--exclude-headlines', required=True, type=private_file)
    parser.add_argument('--holdout', required=True, type=private_file, help='the library holdout JSON (#579), whose headlines are left out')
    parser.add_argument('--tune-corpus', required=True, type=private_file, help='the private event corpus; its tune headlines are left out')
    parser.add_argument('--epochs', type=int, default=1)
    parser.add_argument('--rate', type=float, default=2e-5)
    parser.add_argument('--dry-run', action='store_true', help='counts and the leakage check only')
    args = parser.parse_args(argv)
    out = pathlib.Path(args.out).resolve()
    require(not any((parent / '.git').exists() for parent in [out, *out.parents]), 'Write outside Git checkouts')
    excluded = {line.strip() for line in args.exclude_headlines.read_text().splitlines() if line.strip()}
    excluded |= holdout_headlines(args.holdout) | tune_headlines(args.tune_corpus)
    rows, counts = read_rows(args.pairs, excluded)
    leaked = [r for r in rows if headline(r['a']) in excluded or headline(r['b']) in excluded]
    require(not leaked, f'{len(leaked)} rows name an excluded headline')
    fit, held_out = split(rows)
    summary = {'inputs': counts, 'excluded_headlines': len(excluded),
               'fit': {'positive': sum(r['kind'] == 'positive' for r in fit),
                       'negative': sum(r['kind'] == 'negative' for r in fit)},
               'held_out': {'positive': sum(r['kind'] == 'positive' for r in held_out),
                            'negative': sum(r['kind'] == 'negative' for r in held_out)}}
    print(json.dumps(summary, indent=1))
    if args.dry_run:
        return
    out.mkdir(parents=True, exist_ok=True)
    torch.manual_seed(628)
    device = torch.device('mps' if torch.backends.mps.is_available() else 'cpu')
    tokenizer = Tokenizer()
    bert = BertModel.from_pretrained(HUB_MODEL, revision=HUB_REVISION, attn_implementation='eager').to(device)
    summary['held_out_base'] = evaluate(bert, tokenizer, held_out, device)
    print('base', summary['held_out_base'], flush=True)
    summary['history'] = train(bert, tokenizer, fit, device, args.epochs, args.rate)
    summary['held_out_tuned'] = evaluate(bert, tokenizer, held_out, device)
    print('tuned', summary['held_out_tuned'], flush=True)
    bert = bert.cpu().eval()
    torch.save(bert.state_dict(), out / 'embedding-state.pt')
    convert(bert, LENGTHS, out / 'minilm.mlpackage', describe)
    metadata = {'model': 'minilm', 'base': f'{HUB_MODEL}@{HUB_REVISION}', 'epochs': args.epochs, 'rate': args.rate,
                'batch': BATCH, 'scale': SCALE, 'functions': [f'length_{n}' for n in LENGTHS], **summary,
                'versions': {'python': platform.python_version(), 'torch': torch.__version__,
                             'transformers': __import__('transformers').__version__,
                             'coremltools': __import__('coremltools').__version__}}
    # OUT_DIR is the operator's own output directory, named on the command line.
    (out / 'metadata.json').write_text(json.dumps(metadata, indent=1, sort_keys=True) + '\n')  # NOSONAR
    print(f'wrote {out / "minilm.mlpackage"}')


def self_check():
    """Row selection, the exclusion and one tiny training run whose loss falls."""
    from transformers import BertConfig, BertModel
    rows = [{'group': 'e:1', 'label': '2', 'marginal': ''}, {'group': 'n:x', 'label': '0', 'marginal': '01'},
            {'group': 'g:1', 'label': '0', 'marginal': '01'}, {'group': 's:x', 'label': '0', 'marginal': ''},
            {'group': 'r:match:1', 'label': '1', 'marginal': ''}, {'group': 'w:1', 'label': '2', 'marginal': ''}]
    require([kind(r) for r in rows] == ['positive', None, 'negative', 'negative', None, None], 'row selection')
    require(fold('Erdoğan’s visit: 2 days') == 'erdogan s visit 2 days', 'fold')
    torch.manual_seed(1)
    config = BertConfig(vocab_size=30522, hidden_size=32, num_hidden_layers=2, num_attention_heads=4,
                        intermediate_size=64, max_position_embeddings=512, attn_implementation='eager')
    bert, tokenizer = BertModel(config, add_pooling_layer=True), Tokenizer()
    topics = ['earthquake turkey', 'election france', 'flood spain', 'strike germany', 'storm ireland',
              'vote brazil', 'fire greece', 'crash nepal']
    data = [{'kind': 'positive', 'group': f'e:{t}', 'a': f'{t} kills many', 'b': f'{t} toll rises', 'weight': 1.0}
            for t in topics]
    data += [{'kind': 'negative', 'group': 's:x', 'a': f'{t} kills many', 'b': f'{u} toll rises', 'weight': 2.0}
             for t, u in itertools.pairwise(topics)]
    device = torch.device('cpu')
    before = sum(float(x) for x in losses(bert, tokenizer, data[:8], data[8:], device))
    global BATCH
    BATCH = 8
    train(bert, tokenizer, data, device, epochs=30, rate=1e-3)
    after = sum(float(x) for x in losses(bert.eval(), tokenizer, data[:8], data[8:], device))
    require(after < before, f'loss did not fall: {before:.3f} -> {after:.3f}')
    print('train_embedding self-check passed')


if __name__ == '__main__':
    if sys.argv[1:] == ['--self-check']:
        self_check()
    elif sys.argv[1:] and not sys.argv[1].startswith('--'):
        main(sys.argv[1:])
    else:
        sys.exit(__doc__)
