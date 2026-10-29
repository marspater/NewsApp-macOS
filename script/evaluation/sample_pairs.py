#!/usr/bin/env python3
"""Print a fixed pseudo-random sample of one decision class from a `--review-pairs` export (#551), or turn its
reviewed labels into weighted training rows (#625).

Rows are sorted by the SHA-256 of the two article ids, so a rerun draws the same rows.
Usage: sample_pairs.py ~/news-eval/review/pairs-review.csv match 0 200
       sample_pairs.py EXPORT match 0 200 --labels labels-match.txt --snapshot copy.sqlite3 --out reviewed-pairs.csv
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


def inside_checkout(path):
    """Whether the resolved path lies in this checkout (or any Git checkout): article text never enters one."""
    resolved = pathlib.Path(path).expanduser().resolve()
    checkout = pathlib.Path(__file__).resolve().parents[2]
    return checkout in resolved.parents or any((parent / '.git').exists() for parent in resolved.parents)


def private_export(value):
    """The export file, which must be a regular file outside this checkout."""
    path = pathlib.Path(value).expanduser().resolve()
    if not path.is_file() or inside_checkout(path):
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
    args = parser.parse_args(argv)
    if args.labels:
        if not (args.snapshot and args.out) or inside_checkout(args.out):
            parser.error('--labels needs --snapshot and --out, outside the checkout')
        written = export_labels(args.export, args.kind, args.labels, args.snapshot, args.out)
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

def read_labels(labels):
    """`index label` lines of a labels file as {index: label}; other lines are ignored."""
    verdicts = {}
    with labels.open(encoding='utf-8') as handle:
        for line in handle:
            parts = line.split()
            if len(parts) == 2 and parts[0].isdigit():
                verdicts[int(parts[0])] = parts[1]
    return verdicts


def export_labels(export, kind, labels, snapshot, out):
    """Writes the labelled rows of one class as weighted training rows (`--export-pairs` shape, weight 5): `same`
    is 1, `related` and `different` are 0. Texts come from the library copy (read-only), the pieces from the app's
    tokenizer port. Never for the library holdout, which stays the gate."""
    import re
    import sqlite3
    import urllib.parse
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'training'))
    from wordpiece import Tokenizer
    tag, space = re.compile(r'<[^>]+>'), re.compile(r'\s+')
    with export.open(newline='', encoding='utf-8') as handle:
        rows = [row for row in csv.DictReader(handle) if CLASSES[kind](row)]
    rows.sort(key=order)
    verdicts = read_labels(labels)
    # The copy is opened read-only by a validated path: a regular .sqlite3 file outside any app container.
    copy = pathlib.Path(snapshot).expanduser().resolve()
    if not copy.is_file() or copy.suffix != '.sqlite3' or '/Library/Containers/' in str(copy):
        raise SystemExit(f'{snapshot} is not a library copy')
    db = sqlite3.connect('file:' + urllib.parse.quote(str(copy)) + '?mode=ro', uri=True)
    tokenizer = Tokenizer()

    def text(article_id):
        query = "SELECT title, coalesce(description, '') FROM articles WHERE id = ?"
        found = db.execute(query, (article_id,)).fetchone()
        if not found:
            return None
        title = space.sub(' ', tag.sub(' ', found[0])).strip()
        lead = space.sub(' ', tag.sub(' ', found[1].replace('&nbsp;', ' ').replace('&amp;', '&')))[:600]
        return title + '\n' + lead

    exists = out.exists()
    existing = set()
    if exists:
        # A rerun of the same labels must not double a row's weight; distinct review rounds still append.
        with out.open(newline='', encoding='utf-8') as handle:
            existing = {(row['text_a'], row['text_b']) for row in csv.DictReader(handle)}
    with out.open('a', newline='', encoding='utf-8') as handle:
        # Local training rows, never opened as a spreadsheet.
        writer = csv.writer(handle)  # nosemgrep: python.lang.security.use-defusedcsv.use-defusedcsv
        if not exists:
            writer.writerow(['label', 'group', 'text_a', 'text_b', 'pieces_a', 'pieces_b', 'weight'])
        written = 0
        for index, row in enumerate(rows, start=1):
            verdict = verdicts.get(index)
            a, b = text(row['article_id']), text(row['other_article_id'])
            if verdict not in ('same', 'related', 'different') or not a or not b or (a, b) in existing:
                continue
            existing.add((a, b))
            writer.writerow([1 if verdict == 'same' else 0, f'r:{kind}:{index}', a, b,
                             ' '.join(map(str, tokenizer.pieces(a))), ' '.join(map(str, tokenizer.pieces(b))), 5])
            written += 1
    out.chmod(0o600)
    return written


if __name__ == '__main__':
    main()
