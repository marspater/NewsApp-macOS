#!/usr/bin/env python3
"""Build pretraining pairs for the pair model (#623, M11) from public event-clustered news, in the `--export-pairs`
CSV format plus a `weight` column, outside the checkout.

    pretrain_pairs.py wcep OUT_DIR [--split train] [--clusters N]
        WCEP-10 (Hugging Face `ccdv/WCEP-10`; Ghalandari et al. 2020): positives are pairs of articles inside one
        event cluster (cap 15 per cluster), negatives are pairs across clusters whose synthetic headlines share a
        capitalized name (cap twice the positives). Headline = first sentence, lead = the next 600 characters.
    pretrain_pairs.py gdelt OUT_DIR --from YYYYMMDD --to YYYYMMDD [--slots-per-day 8] [--cap 100000]
        GDELT 2.1 Events, Mentions and GKG files of the range (downloaded into OUT_DIR/gdelt, resumable): hard
        negatives with real headlines: two events with the same Actor1 and Actor2 names and action country, different
        event ids, one to seven days apart. Shared event ids are never used as positives.
    pretrain_pairs.py semeval OUT_DIR
        SemEval-2022 Task 8 (Zenodo 6507872): English-English pairs; overall similarity 1 is label 1, 3 and 4 are
        label 0, 2 is dropped; page text from the Internet Archive (cached under OUT_DIR/semeval), weight 2.
    pretrain_pairs.py --self-check
        Synthetic clusters and events through the same code, no downloads.

Everything is written with 0600 permissions and never overwrites; a path inside a Git checkout is refused.
"""
import argparse
import csv
import gzip
import hashlib
import html
import io
import json
import os
import pathlib
import re
import sys
import urllib.request
import zipfile
from datetime import datetime, timedelta

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from wordpiece import Tokenizer, require  # noqa: E402

HEADER = ['label', 'group', 'text_a', 'text_b', 'pieces_a', 'pieces_b', 'weight']
LEAD = 600
SENTENCE_END = re.compile(r'(?<=[.!?])\s+(?=[A-Z"\'“‘])')
CAPITALIZED = re.compile(r"\b[A-Z][a-zA-Z'’-]{3,}\b")
TAG = re.compile(r'<[^>]+>')
WHITESPACE = re.compile(r'\s+')
GDELT = 'https://data.gdeltproject.org/gdeltv2/'
ZENODO = 'https://zenodo.org/api/records/6507872/files/'


def private_directory(value):
    path = pathlib.Path(value).expanduser().resolve()
    require(not any((parent / '.git').exists() for parent in [path, *path.parents]), 'Keep the pairs outside Git checkouts')
    path.mkdir(parents=True, exist_ok=True)
    os.chmod(path, 0o700)
    return path


def order(a, b):
    """A fixed pseudo-random order (FNV-1a of the two keys), as the Swift exporter uses."""
    value = 14_695_981_039_346_656_037
    for byte in (a + b).encode():
        value = ((value ^ byte) * 1_099_511_628_211) & 0xFFFFFFFFFFFFFFFF
    return value


def headline_and_lead(text):
    """The first sentence as the headline and the next `LEAD` characters as the lead, the shape of `matchingText`."""
    plain = WHITESPACE.sub(' ', TAG.sub(' ', text)).strip()
    if not plain:
        return None
    parts = SENTENCE_END.split(plain, maxsplit=1)
    headline = parts[0][:200].strip()
    lead = (parts[1] if len(parts) > 1 else '')[:LEAD].strip()
    return headline, lead


def pair_text(headline, lead):
    return headline + '\n' + lead


class Writer:
    def __init__(self, path, tokenizer):
        require(not path.exists(), f'{path} exists; remove it to rebuild')
        self.handle = path.open('w', newline='', encoding='utf-8')
        os.chmod(path, 0o600)
        self.csv = csv.writer(self.handle)
        self.csv.writerow(HEADER)
        self.tokenizer = tokenizer
        self.rows = 0
        self.seen = set()

    def write(self, label, group, text_a, text_b, weight=1.0):
        key = tuple(sorted((text_a, text_b)))
        if text_a == text_b or key in self.seen:
            return False
        self.seen.add(key)
        pieces = ' '.join(map(str, self.tokenizer.pieces(text_a))), ' '.join(map(str, self.tokenizer.pieces(text_b)))
        self.csv.writerow([label, group, text_a, text_b, pieces[0], pieces[1], f'{weight:g}'])
        self.rows += 1
        return True

    def close(self):
        self.handle.close()


# --- WCEP-10 ---------------------------------------------------------------------------------------------------------

def wcep_clusters(split, limit, cache):
    """Clusters of article texts from the WCEP-10 split (`train.zip` holds `train.txt`, one JSON object per line)."""
    from huggingface_hub import hf_hub_download
    archive = hf_hub_download('ccdv/WCEP-10', f'{split}.zip', repo_type='dataset', local_dir=str(cache))
    with zipfile.ZipFile(archive) as z:
        name = next(n for n in z.namelist() if n.endswith('.txt'))
        with z.open(name) as handle:
            for index, line in enumerate(io.TextIOWrapper(handle, encoding='utf-8')):
                if limit and index >= limit:
                    break
                row = json.loads(line)
                yield f'{split}-{index}', [d for d in row['document'] if isinstance(d, str)]


def build_wcep(clusters, writer, positives_per_cluster=15):
    """Pairs inside a cluster are one event; pairs across clusters that share a capitalized headline name are not."""
    headlines = {}
    positives = 0
    for cluster, documents in clusters:
        texts = []
        for document in documents:
            parsed = headline_and_lead(document)
            if parsed and len(parsed[0].split()) >= 4:
                texts.append(parsed)
        texts = texts[:10]
        for index, (headline, _) in enumerate(texts):
            headlines[(cluster, index)] = headline
        pairs = [(i, j) for i in range(len(texts)) for j in range(i + 1, len(texts))]
        pairs.sort(key=lambda p: order(f'{cluster}:{p[0]}', f'{cluster}:{p[1]}'))
        for i, j in pairs[:positives_per_cluster]:
            if writer.write(1, 'w:' + cluster, pair_text(*texts[i]), pair_text(*texts[j])):
                positives += 1
        for index, text in enumerate(texts):
            headlines[(cluster, index)] = text
    by_name = {}
    for key, (headline, _) in headlines.items():
        for name in set(CAPITALIZED.findall(headline)):
            by_name.setdefault(name.lower(), []).append(key)
    candidates = set()
    for keys in by_name.values():
        sample = keys[:40]
        for n, a in enumerate(sample):
            for b in sample[n + 1:]:
                if a[0] != b[0]:
                    candidates.add((a, b) if a < b else (b, a))
    negatives = 0
    for a, b in sorted(candidates, key=lambda c: order(f'{c[0][0]}:{c[0][1]}', f'{c[1][0]}:{c[1][1]}')):
        if negatives >= 2 * positives:
            break
        if writer.write(0, 'wn:' + a[0], pair_text(*headlines[a]), pair_text(*headlines[b])):
            negatives += 1
    return positives, negatives


# --- GDELT ------------------------------------------------------------------------------------------------------------

def gdelt_slots(start, end, per_day):
    step = 24 // per_day
    day = datetime.strptime(start, '%Y%m%d')
    last = datetime.strptime(end, '%Y%m%d')
    while day <= last:
        for hour in range(0, 24, step):
            yield (day + timedelta(hours=hour)).strftime('%Y%m%d%H%M%S')
        day += timedelta(days=1)


def gdelt_download(slot, kind, cache):
    """One GDELT file, cached; `kind` is export, mentions or gkg."""
    suffix = {'export': 'export.CSV.zip', 'mentions': 'mentions.CSV.zip', 'gkg': 'gkg.csv.zip'}[kind]
    target = cache / f'{slot}.{suffix}'
    if not target.exists():
        try:
            with urllib.request.urlopen(GDELT + target.name, timeout=120) as response:
                target.write_bytes(response.read())
            os.chmod(target, 0o600)
        except Exception as error:  # a missing 15-minute file is normal; the slot is skipped
            print(f'    skip {target.name}: {error}', file=sys.stderr)
            return None
    return target


def read_zip_tsv(path):
    with zipfile.ZipFile(path) as z:
        for name in z.namelist():
            with z.open(name) as handle:
                for line in io.TextIOWrapper(handle, encoding='utf-8', errors='replace'):
                    yield line.rstrip('\n').split('\t')


def gdelt_rows(slots, cache):
    """Events (id → day, actors, country), mentions (id → urls) and page titles (url → title) of the slots."""
    events, mentions, titles = {}, {}, {}
    for slot in slots:
        export = gdelt_download(slot, 'export', cache)
        if export:
            for row in read_zip_tsv(export):
                if len(row) >= 61 and row[6] and row[16]:
                    events[row[0]] = (row[1], row[6], row[16], row[53])
        mention = gdelt_download(slot, 'mentions', cache)
        if mention:
            for row in read_zip_tsv(mention):
                if len(row) >= 6 and row[3] == '1':
                    mentions.setdefault(row[0], []).append(row[5])
        gkg = gdelt_download(slot, 'gkg', cache)
        if gkg:
            for row in read_zip_tsv(gkg):
                if len(row) >= 27:
                    match = re.search(r'<PAGE_TITLE>(.*?)</PAGE_TITLE>', row[26])
                    if match:
                        titles[row[4]] = html.unescape(match.group(1)).strip()
    return events, mentions, titles


def build_gdelt(events, mentions, titles, writer, cap):
    """Same actors and country, different event and day, one to seven days apart: a hard negative."""
    def title_of(event_id):
        for url in mentions.get(event_id, []):
            title = titles.get(url)
            if title and len(title.split()) >= 4 and not title.lower().startswith(('home', 'news')):
                return title
        return None
    groups = {}
    for event_id, (day, actor1, actor2, country) in events.items():
        title = title_of(event_id)
        if title:
            groups.setdefault((actor1, actor2, country), []).append((event_id, day, title))
    candidates = []
    for members in groups.values():
        members = sorted(members)[:30]
        for n, (a_id, a_day, a_title) in enumerate(members):
            for b_id, b_day, b_title in members[n + 1:]:
                try:
                    gap = abs((datetime.strptime(a_day, '%Y%m%d') - datetime.strptime(b_day, '%Y%m%d')).days)
                except ValueError:
                    continue
                # Same coded actors is coarse ("POLICE", "UNITED STATES"); the headlines must also share a name, so the
                # pair is the same-topic-different-story case the model confuses, not two unrelated reports.
                shared = {n.lower() for n in CAPITALIZED.findall(a_title)} & {n.lower() for n in CAPITALIZED.findall(b_title)}
                if 1 <= gap <= 7 and a_title.lower() != b_title.lower() and shared:
                    candidates.append((a_id, b_id, a_title, b_title))
    candidates.sort(key=lambda c: order(c[0], c[1]))
    written = 0
    for a_id, b_id, a_title, b_title in candidates:
        if written >= cap:
            break
        if writer.write(0, 'g:' + a_id, pair_text(a_title, ''), pair_text(b_title, '')):
            written += 1
    return written


# --- SemEval-2022 Task 8 ----------------------------------------------------------------------------------------------

def semeval_pairs(cache):
    """English-English pairs with their overall similarity, from the Zenodo training and evaluation CSVs."""
    for name in ('semeval-2022_task8_train-data_batch.csv', 'final_eval_data.csv'):
        target = cache / name
        if not target.exists():
            with urllib.request.urlopen(ZENODO + name + '/content', timeout=120) as response:
                target.write_bytes(response.read())
            os.chmod(target, 0o600)
        with target.open(newline='', encoding='utf-8') as handle:
            for row in csv.DictReader(handle):
                if row.get('url1_lang') == 'en' and row.get('url2_lang') == 'en':
                    yield row['pair_id'], row.get('ia_link1') or row['link1'], row.get('ia_link2') or row['link2'], float(row.get('Overall') or row.get('OVERALL'))


def archived_page(url, cache):
    """Title and first paragraph of a page from the Internet Archive, cached by URL hash; None when unavailable."""
    key = hashlib.sha256(url.encode()).hexdigest()
    target = cache / 'pages' / (key + '.json')
    if target.exists():
        return json.loads(target.read_text())
    result = None
    try:
        with urllib.request.urlopen(url if url.startswith('https://web.archive.org/') else 'https://web.archive.org/web/2020id_/' + url, timeout=60) as response:
            body = response.read(400_000).decode('utf-8', errors='replace')
        title = re.search(r'<title[^>]*>(.*?)</title>', body, re.S | re.I)
        paragraphs = re.findall(r'<p[^>]*>(.*?)</p>', body, re.S | re.I)
        text = ' '.join(WHITESPACE.sub(' ', TAG.sub(' ', html.unescape(p))).strip() for p in paragraphs)
        if title and len(text) >= 200:
            result = {'title': WHITESPACE.sub(' ', html.unescape(TAG.sub(' ', title.group(1)))).strip()[:200],
                      'lead': text[:LEAD]}
    except Exception:
        result = None
    target.parent.mkdir(exist_ok=True)
    target.write_text(json.dumps(result))
    os.chmod(target, 0o600)
    return result


def build_semeval(pairs, writer, fetch, workers=6):
    """Overall similarity 1 (most similar) is one story, 3 and 4 are not, 2 is ambiguous and dropped. Pages are
    fetched a few at a time (the Internet Archive tolerates about that many)."""
    from concurrent.futures import ThreadPoolExecutor
    pairs = [(pair_id, link1, link2, overall) for pair_id, link1, link2, overall in pairs
             if overall < 1.5 or overall >= 2.5]
    with ThreadPoolExecutor(max_workers=workers) as pool:
        pages = dict(zip((url for pair in pairs for url in pair[1:3]),
                         pool.map(fetch, (url for pair in pairs for url in pair[1:3]))))
    written = 0
    for pair_id, link1, link2, overall in pairs:
        label = 1 if overall < 1.5 else 0
        a, b = pages.get(link1), pages.get(link2)
        if not a or not b:
            continue
        if writer.write(label, 's:' + pair_id, pair_text(a['title'], a['lead']), pair_text(b['title'], b['lead']), 2):
            written += 1
    return written


# --- entry points -----------------------------------------------------------------------------------------------------

def summarize(path):
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    with path.open(newline='', encoding='utf-8') as handle:
        rows = list(csv.DictReader(handle))
    positives = sum(1 for r in rows if r['label'] == '1')
    print(f'    {path.name}: {len(rows)} pairs, {positives} same event, {len(rows) - positives} different; sha256 {digest}')


def self_check():
    tokenizer = Tokenizer()
    import tempfile
    with tempfile.TemporaryDirectory() as directory:
        out = pathlib.Path(directory)
        clusters = [
            ('c1', ['Mount Rainier erupts after weeks of tremors. Ash fell across the valley on Monday as crews moved.',
                    'Rainier eruption forces evacuations in Washington. Thousands left towns below the volcano.',
                    'Volcano Rainier sends ash cloud over Seattle. Flights were cancelled through the afternoon.']),
            ('c2', ['Seattle council passes housing levy. The measure funds new apartments near transit lines.',
                    'Housing levy clears Seattle council vote. Backers say rents will ease within years.']),
        ]
        writer = Writer(out / 'wcep.csv', tokenizer)
        positives, negatives = build_wcep(clusters, writer)
        writer.close()
        require(positives == 4 and negatives >= 1, f'WCEP self-check: {positives} positives, {negatives} negatives')
        events = {'1': ('20260101', 'GOVERNMENT', 'PROTESTER', 'FR'), '2': ('20260103', 'GOVERNMENT', 'PROTESTER', 'FR'),
                  '3': ('20260101', 'GOVERNMENT', 'PROTESTER', 'FR'), '4': ('20260120', 'GOVERNMENT', 'PROTESTER', 'FR')}
        mentions = {'1': ['u1'], '2': ['u2'], '3': ['u3'], '4': ['u4']}
        titles = {'u1': 'Police clear protest camp in Paris after night of clashes', 'u2': 'Paris court fines protest leaders',
                  'u3': 'Police clear protest camp in Paris after night of clashes', 'u4': 'Protest season ends in Paris'}
        writer = Writer(out / 'gdelt.csv', tokenizer)
        written = build_gdelt(events, mentions, titles, writer, cap=10)
        writer.close()
        # 1–2 and 3–2 qualify but carry the same two texts, so one row; 1–3 share a day; 4 is too far away.
        require(written == 1, f'GDELT self-check: {written} negatives (same day, far apart and repeated texts excluded)')
        pages = {'a': {'title': 'Storm hits coast', 'lead': 'x' * 300}, 'b': {'title': 'Coastal storm batters towns', 'lead': 'y' * 300},
                 'c': {'title': 'Budget vote delayed', 'lead': 'z' * 300}}
        writer = Writer(out / 'semeval.csv', tokenizer)
        written = build_semeval([('p1', 'a', 'b', 1.0), ('p2', 'a', 'c', 3.7), ('p3', 'b', 'c', 2.0)], writer, pages.get)
        writer.close()
        require(written == 2, f'SemEval self-check: {written} pairs (the ambiguous 2 dropped)')
        with (out / 'semeval.csv').open(newline='') as handle:
            rows = list(csv.DictReader(handle))
        require(rows[0]['weight'] == '2' and rows[0]['label'] == '1' and rows[1]['label'] == '0', 'SemEval labels and weight')
    print('pretrain_pairs self-check passed')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--self-check', action='store_true')
    sub = parser.add_subparsers(dest='command')
    wcep = sub.add_parser('wcep')
    wcep.add_argument('out')
    wcep.add_argument('--split', default='train')
    wcep.add_argument('--clusters', type=int, default=0)
    gdelt = sub.add_parser('gdelt')
    gdelt.add_argument('out')
    gdelt.add_argument('--from', dest='start', required=True)
    gdelt.add_argument('--to', dest='end', required=True)
    gdelt.add_argument('--slots-per-day', type=int, default=8)
    gdelt.add_argument('--cap', type=int, default=100_000)
    semeval = sub.add_parser('semeval')
    semeval.add_argument('out')
    args = parser.parse_args(argv)
    if args.self_check:
        self_check()
        return 0
    require(args.command, 'wcep, gdelt or semeval')
    out = private_directory(args.out)
    tokenizer = Tokenizer()
    if args.command == 'wcep':
        writer = Writer(out / 'wcep-pairs.csv', tokenizer)
        positives, negatives = build_wcep(wcep_clusters(args.split, args.clusters, out / 'wcep'), writer)
        writer.close()
        print(f'    WCEP-10 {args.split}: {positives} positives, {negatives} negatives')
        summarize(out / 'wcep-pairs.csv')
    elif args.command == 'gdelt':
        cache = out / 'gdelt'
        cache.mkdir(exist_ok=True)
        events, mentions, titles = gdelt_rows(gdelt_slots(args.start, args.end, args.slots_per_day), cache)
        print(f'    GDELT {args.start}-{args.end}: {len(events)} events with two actors, {len(titles)} titled pages')
        writer = Writer(out / 'gdelt-negatives.csv', tokenizer)
        written = build_gdelt(events, mentions, titles, writer, args.cap)
        writer.close()
        print(f'    {written} hard negatives')
        summarize(out / 'gdelt-negatives.csv')
    else:
        cache = out / 'semeval'
        cache.mkdir(exist_ok=True)
        writer = Writer(out / 'semeval-pairs.csv', tokenizer)
        written = build_semeval(semeval_pairs(cache), writer, lambda url: archived_page(url, cache))
        writer.close()
        print(f'    SemEval-2022 Task 8: {written} English pairs')
        summarize(out / 'semeval-pairs.csv')
    return 0


if __name__ == '__main__':
    sys.exit(main())
