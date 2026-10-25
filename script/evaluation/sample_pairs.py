#!/usr/bin/env python3
"""Print a fixed pseudo-random sample of one decision class from a `--review-pairs` export (#551).

Rows are sorted by the SHA-256 of the two article ids, so a rerun draws the same rows.
Usage: sample_pairs.py ~/news-eval/review/pairs-review.csv match 0 200
Classes: match (rule matches), pairModel (model confirmations), related (related-act rows), vetoed, borderline.
The export carries headlines, so it must live outside the checkout; the script refuses a path inside it.
"""
import argparse
import csv
import hashlib
import pathlib
import sys

CLASSES = {
    'match': lambda row: row['decision'] == 'match' and row['reason'] == 'match',
    'pairModel': lambda row: row['decision'] == 'match' and row['reason'] == 'pairModel',
    'related': lambda row: row['decision'] == 'related-act',
    'vetoed': lambda row: row['decision'] == 'vetoed',
    'borderline': lambda row: row['decision'] == 'borderline',
}


def private_export(value):
    """The export file, which must be a regular file outside this checkout."""
    path = pathlib.Path(value).expanduser().resolve()
    checkout = pathlib.Path(__file__).resolve().parents[2]
    if not path.is_file() or checkout in path.parents:
        raise argparse.ArgumentTypeError(f'{value} is not a private export outside the checkout')
    return path


def order(row):
    return hashlib.sha256((row['article_id'] + row['other_article_id']).encode()).hexdigest()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('export', type=private_export)
    parser.add_argument('kind', choices=sorted(CLASSES))
    parser.add_argument('start', type=int)
    parser.add_argument('end', type=int)
    args = parser.parse_args(argv)
    with args.export.open(newline='', encoding='utf-8') as handle:
        rows = [row for row in csv.DictReader(handle) if CLASSES[args.kind](row)]
    rows.sort(key=order)
    print(f'{args.kind}: {len(rows)} rows')
    for index, row in enumerate(rows[args.start:args.end], start=args.start + 1):
        gap = (float(row['published_b']) - float(row['published_a'])) / 3600
        print(
            f"{index:3d} [{gap:+.1f}h s={float(row['score']):.2f}] {row['source_a']}: {row['title_a']}"
            f" || {row['source_b']}: {row['title_b']}"
        )
    return 0


if __name__ == '__main__':
    sys.exit(main())
