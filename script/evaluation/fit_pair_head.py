#!/usr/bin/env python3
"""Fit the matcher's decision head (#524) on `--export-features` CSVs and report pair-level precision and recall.

`fit_pair_head.py TUNE.csv HOLDOUT.csv` fits an L2-regularized logistic regression on the tune split's conflict-free
pairs (hard conflicts keep vetoing in Swift), picks the lowest threshold whose tune precision is at least 0.95, and
prints the weights as a Swift literal with tune and holdout numbers next to the shipped rule's. The holdout is scored
once at that threshold, never swept. Pair-level numbers are a screen: the clustering replay of the head is the gate.
With no arguments, the script checks itself on synthetic pairs. Standard library only; reads ids and numbers, no text.
"""
import csv
import math
import os
import pathlib
import sys

# Feature order is the Swift order in `EventMatchPolicy.headWeights`; the bias comes first.
FEATURES = ('bias', 'what', 'entity', 'time', 'specific', 'anchors', 'keywords', 'toll', 'number', 'cosine')
FULL_TIME_CREDIT, MAXIMUM_TIME_GAP = 6.0, 36.0
TARGET_PRECISION = 0.95


def features(row):
    """The head's inputs from one exported row, each in [0, 1]; mirrors `EventMatcher.headFeatures` in Swift."""
    gap = float(row['gap_hours'])
    time = 1.0 if gap <= FULL_TIME_CREDIT else max(0.0, 1 - (gap - FULL_TIME_CREDIT) / (MAXIMUM_TIME_GAP - FULL_TIME_CREDIT))
    return [
        1.0, float(row['what']), float(row['entity']), time, min(int(row['shared_specific']), 3) / 3,
        min(int(row['shared_anchors']), 5) / 5, min(int(row['shared_keywords']), 8) / 8, float(row['toll_agree']),
        float(row['number_agree']), float(row['cosine'] or 0),
    ]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read(path):
    """An export CSV the caller owns, outside any Git checkout: the rows come from the private corpus."""
    file = pathlib.Path(path).resolve()
    require(file.suffix == '.csv' and file.is_file() and file.stat().st_uid == os.getuid(), 'Use an export CSV you own')
    require(not any((parent / '.git').exists() for parent in file.parents), 'Keep private exports outside Git checkouts')
    with file.open(newline='') as handle:
        return list(csv.DictReader(handle))


def solve(matrix, vector):
    """Gaussian elimination with partial pivoting; small dense systems only."""
    n = len(vector)
    a = [row[:] + [vector[i]] for i, row in enumerate(matrix)]
    for col in range(n):
        pivot = max(range(col, n), key=lambda r, c=col: abs(a[r][c]))
        a[col], a[pivot] = a[pivot], a[col]
        for r in range(n):
            if r != col and a[col][col]:
                factor = a[r][col] / a[col][col]
                a[r] = [x - factor * y for x, y in zip(a[r], a[col])]
    return [a[i][n] / a[i][i] for i in range(n)]


def sigmoid(z):
    return 1 / (1 + math.exp(-max(-30.0, min(30.0, z))))


def newton_terms(w, xs, ys, l2):
    """Hessian and gradient of the L2-penalized log loss at `w`, as `solve` takes them; the bias is not penalized."""
    grad = [l2 * wi if i else 0.0 for i, wi in enumerate(w)]
    hess = [[(l2 if i == j and i else 0.0) for j in range(len(w))] for i in range(len(w))]
    for x, y in zip(xs, ys):
        p = sigmoid(sum(a * b for a, b in zip(w, x)))
        for i, xi in enumerate(x):
            grad[i] += (p - y) * xi
            hess[i] = [h + p * (1 - p) * xi * xj for h, xj in zip(hess[i], x)]
    return hess, grad


def fit(xs, ys, l2=1.0, steps=50):
    """Newton's method on the L2-penalized log loss."""
    w = [0.0] * len(xs[0])
    for _ in range(steps):
        step = solve(*newton_terms(w, xs, ys, l2))
        w = [wi - si for wi, si in zip(w, step)]
        if max(abs(s) for s in step) < 1e-9:
            break
    return w


def score(w, x):
    return sigmoid(sum(a * b for a, b in zip(w, x)))


def metrics(predicted, labels):
    tp = sum(1 for p, y in zip(predicted, labels) if p and y)
    fp = sum(1 for p, y in zip(predicted, labels) if p and not y)
    fn = sum(1 for p, y in zip(predicted, labels) if not p and y)
    precision = tp / (tp + fp) if tp + fp else 1.0
    recall = tp / (tp + fn) if tp + fn else 1.0
    return {'tp': tp, 'fp': fp, 'fn': fn, 'precision': round(precision, 3), 'recall': round(recall, 3)}


def threshold(scores, labels, target=TARGET_PRECISION):
    """The lowest score cutoff whose pairs at or above it reach the target precision (most recall)."""
    best = 1.0
    for cutoff in sorted(set(scores), reverse=True):
        chosen = [y for s, y in zip(scores, labels) if s >= cutoff]
        if sum(chosen) / len(chosen) >= target:
            best = cutoff
    return best


def evaluate(rows, w, cutoff):
    """Pair-level scores over every exported pair: a conflict always predicts different, like the Swift vetoes."""
    labels = [row['label'] == '1' for row in rows]
    head = [not row['conflict'] and score(w, features(row)) >= cutoff for row in rows]
    rule = [row['is_match'] == '1' for row in rows]
    return metrics(head, labels), metrics(rule, labels)


def report(tune_rows, holdout_rows):
    free = [row for row in tune_rows if not row['conflict']]
    xs, ys = [features(row) for row in free], [1.0 if row['label'] == '1' else 0.0 for row in free]
    w = fit(xs, ys)
    cutoff = threshold([score(w, x) for x in xs], ys)
    tune_head, tune_rule = evaluate(tune_rows, w, cutoff)
    holdout_head, holdout_rule = evaluate(holdout_rows, w, cutoff)
    print(f'conflict-free tune pairs: {len(free)} ({int(sum(ys))} same event)')
    print('weights (Swift):')
    print('    static let headWeights: [Double] = [' + ', '.join(f'{v:.4f}' for v in w) + ']')
    print(f'    static let headThreshold = {cutoff:.4f}')
    for name, value in zip(FEATURES, w):
        print(f'      {name:9s} {value:+.4f}')
    print(f'tune    head {tune_head}  rule {tune_rule}')
    print(f'holdout head {holdout_head}  rule {holdout_rule}')
    return w, cutoff, holdout_head


def self_check():
    def spread(i, k):
        """A fixed, evenly spread value in [0, 1) for row i and column k (no randomness needed)."""
        return (i * 7919 + k * 104729) % 1000 / 1000

    def row(i, label):
        cosine = 0.7 + 0.25 * spread(i, 1) if label else 0.3 + 0.45 * spread(i, 1)
        return {
            'label': '1' if label else '0', 'gap_hours': f'{30 * spread(i, 2):.2f}', 'what': f'{spread(i, 3):.3f}',
            'entity': f'{spread(i, 4):.3f}', 'shared_specific': str(int(4 * spread(i, 5))),
            'shared_anchors': str(int(6 * spread(i, 6))), 'shared_keywords': str(int(9 * spread(i, 7))),
            'toll_agree': '0', 'number_agree': '0', 'cosine': f'{cosine:.4f}', 'conflict': '',
            'is_match': '1' if cosine > 0.85 else '0',
        }
    tune = [row(i, i % 3 == 0) for i in range(300)]
    holdout = [row(i, i % 3 == 0) for i in range(300, 420)]
    holdout.append(dict(row(420, True), conflict='places'))
    w, _, holdout_head = report(tune, holdout)
    require(w[FEATURES.index('cosine')] > 1, 'Cosine separates the synthetic pairs, so it carries positive weight')
    require(holdout_head['precision'] >= 0.9 and holdout_head['recall'] > 0.5, 'The fit generalizes to the holdout')
    require(holdout_head['fn'] >= 1, 'A conflicting pair is never predicted the same event')
    solved = solve([[2, 1], [1, 3]], [3, 5])
    require(all(abs(a - b) < 1e-12 for a, b in zip(solved, [0.8, 1.4])), 'The solver solves a small system')
    print('Pair head fit self-check passed')


if __name__ == '__main__':
    if len(sys.argv) == 3:
        report(read(sys.argv[1]), read(sys.argv[2]))
    elif len(sys.argv) == 1:
        self_check()
    else:
        sys.exit('usage: fit_pair_head.py TUNE.csv HOLDOUT.csv')
