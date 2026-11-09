#!/usr/bin/env python3
"""Fit the evidence head (#737) on `./test.sh --pair-signals` CSVs of reviewed pairs.

`fit_evidence_head.py FIT.csv [FIT2.csv ...] [--validate VAL.csv ...]` fits a logistic regression of `same` against
every other label on two signals of a pair, the sentence-embedding cosine and the hours between the reports (capped
at 96 and scaled to 0...1, as `PairEvidenceHead.probability` does), over the pairs of different publishers that have a
cosine. It reports five-fold numbers out of fold, the folds grouped by connected articles so no report is on both
sides, picks the lowest cutoff whose out-of-fold precision is at least 0.95, and prints the weights as
`NEWS_EVIDENCE_HEAD=bias,cosine,gap,cutoff`. Validation files are scored once at that cutoff, never swept. Pair-level
numbers are a screen: the replays (tune, authored corpus, `--library-holdout`) are the gate.
With no arguments the script checks itself on synthetic pairs. Standard library only; reads ids and numbers, no text.
"""
import csv
import math
import os
import pathlib
import random
import sys

GAP_SCALE = 96.0
TARGET_PRECISION = 0.95
FOLDS = 5


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read(path):
    """An export CSV the caller owns, outside any Git checkout: the pairs come from a private library copy."""
    file = pathlib.Path(path).resolve()
    require(file.suffix == '.csv' and file.is_file() and file.stat().st_uid == os.getuid(), 'Use an export CSV you own')
    require(not any((parent / '.git').exists() for parent in file.parents), 'Keep private exports outside Git checkouts')
    with file.open(newline='') as handle:
        return [row for row in csv.DictReader(handle) if row['cosine'] and row['same_publisher'] == '0']


def features(row):
    return [1.0, float(row['cosine']), min(max(float(row['gap_hours']), 0.0), GAP_SCALE) / GAP_SCALE]


def sigmoid(z):
    return 1 / (1 + math.exp(-max(-30.0, min(30.0, z))))


def probability(weights, row):
    return sigmoid(sum(w * x for w, x in zip(weights, features(row))))


def fit(rows, steps=20000, rate=1.0):
    """Full-batch gradient descent on the mean log loss; three weights and a few hundred rows."""
    xs, ys = [features(r) for r in rows], [1.0 if r['label'] == 'same' else 0.0 for r in rows]
    weights = [0.0, 0.0, 0.0]
    for _ in range(steps):
        gradient = [0.0, 0.0, 0.0]
        for x, y in zip(xs, ys):
            error = sigmoid(sum(w * v for w, v in zip(weights, x))) - y
            for index, value in enumerate(x):
                gradient[index] += error * value
        weights = [w - rate * g / len(xs) for w, g in zip(weights, gradient)]
    return weights


def folds(rows):
    """A fold per row; rows that share an article (directly or through other pairs) share a fold."""
    parent = {}

    def find(item):
        while parent.setdefault(item, item) != item:
            parent[item] = parent[parent[item]]
            item = parent[item]
        return item

    for row in rows:
        parent[find(row['a'])] = find(row['b'])
    groups = sorted({find(row['a']) for row in rows})
    random.Random(737).shuffle(groups)
    fold = {group: index % FOLDS for index, group in enumerate(groups)}
    return [fold[find(row['a'])] for row in rows]


def auc(positives, negatives):
    if not positives or not negatives:
        return float('nan')
    wins = sum((p > n) + 0.5 * (p == n) for p in positives for n in negatives)
    return wins / (len(positives) * len(negatives))


def counts(scored, cutoff):
    """(same at or above the cutoff, others at or above it, all same)."""
    hits = sum(1 for p, label in scored if p >= cutoff and label == 'same')
    wrong = sum(1 for p, label in scored if p >= cutoff and label != 'same')
    return hits, wrong, sum(1 for _, label in scored if label == 'same')


def choose_cutoff(scored):
    """The lowest cutoff whose precision reaches the target, rounded up to two decimals."""
    chosen = 1.0
    for cutoff in sorted({p for p, _ in scored}, reverse=True):
        hits, wrong, _ = counts(scored, cutoff)
        if hits / max(1, hits + wrong) >= TARGET_PRECISION:
            chosen = cutoff
    return math.ceil(chosen * 100) / 100


def line(name, scored, cutoff):
    hits, wrong, total = counts(scored, cutoff)
    same = [p for p, label in scored if label == 'same']
    rest = [p for p, label in scored if label != 'same']
    return (f'{name}: {len(scored)} pairs, AUC {auc(same, rest):.3f}; at {cutoff:.2f} same {hits} of {total}, '
            f'others {wrong} of {len(rest)}, precision {hits / max(1, hits + wrong):.3f}')


def run(fit_paths, validation_paths):
    rows = [row for path in fit_paths for row in read(path)]
    require(len({(r['a'], r['b']) for r in rows}) == len(rows), 'A pair appears twice in the fit files')
    assigned = folds(rows)
    out_of_fold = []
    for fold in range(FOLDS):
        weights = fit([r for r, f in zip(rows, assigned) if f != fold])
        out_of_fold += [(probability(weights, r), r['label']) for r, f in zip(rows, assigned) if f == fold]
    cutoff = choose_cutoff(out_of_fold)
    weights = fit(rows)
    print(line('fit, out of fold', out_of_fold, cutoff))
    print(line('fit, in sample', [(probability(weights, r), r['label']) for r in rows], cutoff))
    fit_ids = {article for r in rows for article in (r['a'], r['b'])}
    for path in validation_paths:
        held = read(path)
        require(not any(r['a'] in fit_ids or r['b'] in fit_ids for r in held), f'{path} shares an article with the fit')
        print(line(f'validation {pathlib.Path(path).parent.name}', [(probability(weights, r), r['label']) for r in held],
                   cutoff))
    print('NEWS_EVIDENCE_HEAD=' + ','.join(f'{w:.4f}' for w in weights) + f',{cutoff:.2f}')
    return weights, cutoff


def self_check():
    rng = random.Random(1)
    rows = []
    for index in range(400):
        same = index % 3 == 0
        cosine = min(0.99, max(0.05, rng.gauss(0.8 if same else 0.5, 0.08)))
        gap = abs(rng.gauss(4 if same else 30, 6))
        rows.append({'a': f'a{index}', 'b': f'b{index}', 'label': 'same' if same else 'topic',
                     'cosine': f'{cosine:.4f}', 'gap_hours': f'{gap:.2f}', 'same_publisher': '0'})
    weights = fit(rows, steps=3000)
    require(weights[1] > 0 > weights[2], 'The head must rise with the cosine and fall with the gap')
    scored = [(probability(weights, r), r['label']) for r in rows]
    cutoff = choose_cutoff(scored)
    hits, wrong, total = counts(scored, cutoff)
    require(hits / max(1, hits + wrong) >= TARGET_PRECISION and hits > total // 2, 'The cutoff must keep the precision')
    require(len(set(folds(rows + [{'a': 'a0', 'b': 'b1'}])[i] for i in (0, 1, 400))) == 1, 'Linked pairs share a fold')
    print('fit_evidence_head.py: self-check passed')


if __name__ == '__main__':
    arguments = sys.argv[1:]
    if not arguments:
        self_check()
    else:
        split = arguments.index('--validate') if '--validate' in arguments else len(arguments)
        run(arguments[:split], arguments[split + 1:])
