#!/usr/bin/env python3
"""Print a fixed pseudo-random sample of one decision class from a `--review-pairs` export (#551), or turn its
reviewed labels into weighted training rows (#625).

Rows are sorted by the SHA-256 of the two article ids, so a rerun draws the same rows.
Usage: sample_pairs.py ~/news-eval/review/pairs-review.csv match 0 200
       sample_pairs.py EXPORT match 0 200 --labels labels-match.txt --snapshot copy.sqlite3 --out reviewed-pairs.csv \
           --holdout library-holdout.json [--prefix]
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
    parser.add_argument('--labels', type=pathlib.Path, help='index-label lines of this class (#625)')
    parser.add_argument('--snapshot', type=pathlib.Path, help='the library copy the export came from')
    parser.add_argument('--out', type=pathlib.Path, help='training CSV to append the labelled rows to')
    parser.add_argument('--holdout', type=pathlib.Path,
                        help='the library holdout JSON (#579): rows naming one of its articles are left out')
    parser.add_argument('--prefix', action='store_true',
                        help='prepend the gap-and-publisher words (#626); off, as the app and the exporter default')
    args = parser.parse_args(argv)
    if args.labels:
        if not (args.snapshot and args.out) or '.git' in [p.name for p in [args.out, *args.out.parents]]:
            parser.error('--labels needs --snapshot and --out, outside the checkout')
        written = export_labels(args.export, args.kind, args.labels, args.snapshot, args.out, args.holdout,
                                args.prefix)
        print(f'{args.kind}: {written} rows written')
        return
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



# --- reviewed labels as training rows (#625) ---------------------------------------------------------------------

HEADER = ['label', 'group', 'text_a', 'text_b', 'pieces_a', 'pieces_b', 'weight', 'marginal']
LABELS = {'different': 0, 'related': 1, 'same': 2}


def read_verdicts(labels):
    """`index label` lines of a labels file, by index."""
    verdicts = {}
    with labels.open(encoding='utf-8') as handle:
        for line in handle:
            parts = line.split()
            if len(parts) == 2 and parts[0].isdigit():
                verdicts[int(parts[0])] = parts[1]
    return verdicts


def holdout_ids(holdout):
    """Article ids of the library holdout's pairs; none without a holdout file."""
    import json
    return {x for pair in json.loads(holdout.read_text()) for x in (pair['a'], pair['b'])} if holdout else set()


def library_texts(snapshot):
    """The matching text (headline and the first 600 plain lead characters) of an article id in the library copy,
    opened read-only by a validated path: a regular .sqlite3 file outside any app container; None when missing."""
    import re
    import sqlite3
    import urllib.parse
    copy = pathlib.Path(snapshot).expanduser().resolve()
    if not copy.is_file() or copy.suffix != '.sqlite3' or '/Library/Containers/' in str(copy):
        raise SystemExit(f'{snapshot} is not a library copy')
    db = sqlite3.connect('file:' + urllib.parse.quote(str(copy)) + '?mode=ro', uri=True)
    tag, space = re.compile(r'<[^>]+>'), re.compile(r'\s+')

    def text(article_id):
        query = "SELECT title, coalesce(description, '') FROM articles WHERE id = ?"
        found = db.execute(query, (article_id,)).fetchone()
        if not found:
            return None
        title = space.sub(' ', tag.sub(' ', found[0])).strip()
        lead = space.sub(' ', tag.sub(' ', found[1].replace('&nbsp;', ' ').replace('&amp;', '&')))[:600]
        return title + '\n' + lead
    return text


def require_header(out):
    """An existing training CSV must already have the three-way header; returns whether the file exists."""
    if not out.exists():
        return False
    with out.open(newline='', encoding='utf-8') as handle:
        if next(csv.reader(handle), None) != HEADER:
            raise SystemExit(f'{out} has another header; write the three-way rows to a new file')
    return True


def labelled_rows(export, kind, verdicts, held_out):
    """(index, row, label) of the labelled rows of one class in the fixed order, without library-holdout articles."""
    with export.open(newline='', encoding='utf-8') as handle:
        rows = [row for row in csv.DictReader(handle) if CLASSES[kind](row)]
    rows.sort(key=order)
    for index, row in enumerate(rows, start=1):
        verdict = verdicts.get(index)
        if verdict in LABELS and not {row['article_id'], row['other_article_id']} & held_out:
            yield index, row, LABELS[verdict]


def export_labels(export, kind, labels, snapshot, out, holdout=None, prefixed=False):
    """Writes the labelled rows of one class as weighted training rows in the three-way contract of
    `train_pair_model.py` (#627, weight 5): `different` 0, `related` 1, `same` 2, all exact. Texts come from the
    library copy (read-only), the pieces from the app's tokenizer port. A row naming an article of the library holdout
    (`holdout`, #579) is left out: the holdout stays the gate."""
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'training'))
    from wordpiece import Tokenizer, pair_prefix
    text, tokenizer = library_texts(snapshot), Tokenizer()
    exists = require_header(out)
    written = 0
    with out.open('a', newline='', encoding='utf-8') as handle:
        # Local training rows, never opened as a spreadsheet.
        writer = csv.writer(handle)  # nosemgrep: python.lang.security.use-defusedcsv.use-defusedcsv
        if not exists:
            writer.writerow(HEADER)
        for index, row, label in labelled_rows(export, kind, read_verdicts(labels), holdout_ids(holdout)):
            a, b = text(row['article_id']), text(row['other_article_id'])
            if not a or not b:
                continue
            if prefixed:
                # The prefix an earlier model read (#626): the pair's gap and whether one publisher wrote both.
                prefix = pair_prefix(abs(float(row['published_a']) - float(row['published_b'])) / 3600,
                                     row['source_a'] == row['source_b'])
                a, b = prefix + a, prefix + b
            writer.writerow([label, f'r:{kind}:{index}', a, b, ' '.join(map(str, tokenizer.pieces(a))),
                             ' '.join(map(str, tokenizer.pieces(b))), 5, ''])
            written += 1
    out.chmod(0o600)
    return written


if __name__ == '__main__':
    main()
