#!/usr/bin/env python3
"""Build pretraining pairs for the pair model (#623, M11) from public event-clustered news, in the `--export-pairs`
CSV format plus a `weight` column, outside the checkout.

    pretrain_pairs.py wcep OUT_DIR [--split train] [--clusters N]
        WCEP-10 (Hugging Face `ccdv/WCEP-10`, pinned revision; Ghalandari et al. 2020): positives are pairs of
        articles inside one event cluster (cap 15 per cluster), negatives are pairs across clusters whose synthetic
        headlines share a capitalized name (cap twice the positives). Headline = first sentence, lead = the next 600
        characters.
    pretrain_pairs.py gdelt OUT_DIR --from YYYYMMDD --to YYYYMMDD [--slots-per-day 8] [--cap 100000]
        GDELT 2.1 Events, Mentions and GKG files of the range (downloaded into OUT_DIR/gdelt, resumable): hard
        negatives with real headlines: two events with the same Actor1 and Actor2 names and action country, different
        event ids, one to seven days apart, whose headlines share a capitalized name. Shared event ids are never used
        as positives.
    pretrain_pairs.py semeval OUT_DIR
        SemEval-2022 Task 8 (Zenodo 6507872): English-English pairs; overall similarity 1 is label 1, 3 and 4 are
        label 0, 2 is dropped; page text from the Internet Archive (cached under OUT_DIR/semeval), weight 2.
    pretrain_pairs.py --self-check
        Synthetic clusters, events and pages through the same code, no downloads.

Everything is written with 0600 permissions and never overwrites; a path inside a Git checkout is refused. Only
https URLs of the three sources are opened.
"""
import argparse
import csv
import hashlib
import html
import http.client
import io
import json
import os
import pathlib
import re
import sys
import threading
import time
import urllib.error
import urllib.request
import zipfile
from concurrent.futures import ThreadPoolExecutor
from datetime import date, timedelta

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from wordpiece import Tokenizer, require

HEADER = ['label', 'group', 'text_a', 'text_b', 'pieces_a', 'pieces_b', 'weight']
LEAD = 600
SENTENCE_END = re.compile(r'(?<=[.!?])\s+(?=[A-Z"\'“‘])')
CAPITALIZED = re.compile(r"\b[A-Z][a-zA-Z'’-]{3,}\b")
TAG = re.compile(r'<[^>]+>')
WHITESPACE = re.compile(r'\s+')
TITLE = re.compile(r'<title[^>]*>(.*?)</title>', re.DOTALL | re.IGNORECASE)
PARAGRAPH = re.compile(r'<p[^>]*>(.*?)</p>', re.DOTALL | re.IGNORECASE)
PAGE_TITLE = re.compile(r'<PAGE_TITLE>(.*?)</PAGE_TITLE>')
GDELT = 'https://data.gdeltproject.org/gdeltv2/'
ZENODO = 'https://zenodo.org/api/records/6507872/files/'
ARCHIVE = 'https://web.archive.org/'
# The dataset repository's commit read on 24 October 2026 (`HfApi().list_repo_commits`); bump deliberately.
WCEP_REVISION = 'e231ece6b9131ef38a8eff15c5ec40f3fa211289'
WCEP_POSITIVES_PER_CLUSTER = 15
GDELT_SAMPLE = 30
FETCH_WORKERS = 3


def private_directory(value):
    path = pathlib.Path(value).expanduser().resolve()
    require(not any((parent / '.git').exists() for parent in [path, *path.parents]),
            'Keep the pairs outside Git checkouts')
    path.mkdir(parents=True, exist_ok=True)
    os.chmod(path, 0o700)
    return path


def fetch(url, timeout=120, limit=None):
    """Bytes of one https resource of the three sources; anything else is refused before a socket is opened."""
    require(url.startswith((GDELT, ZENODO, ARCHIVE)), f'Refusing to open {url}')
    # The scheme and host are checked above, so the custom-scheme concern of B310 does not apply.
    request = urllib.request.Request(url, headers={'User-Agent': 'NewsApp-pretrain/1.0 (research; see #623)'})
    try:
        with OPENER.open(request, timeout=timeout) as response:  # nosec B310
            return response.read(limit) if limit else response.read()
    except http.client.IncompleteRead as error:
        # A truncated body is a connection failure like any other, so every caller's OSError handling covers it.
        raise ConnectionError(f'incomplete read from {url}') from error


class SourceRedirects(urllib.request.HTTPRedirectHandler):
    """Redirects stay on the three sources' https hosts; anything else is refused as a connection error."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not newurl.startswith(SOURCE_ORIGINS):
            raise urllib.error.URLError(f'refusing a redirect to {newurl}')
        return super().redirect_request(req, fp, code, msg, headers, newurl)


SOURCE_ORIGINS = ('https://data.gdeltproject.org/', 'https://zenodo.org/', 'https://web.archive.org/')
OPENER = urllib.request.build_opener(SourceRedirects())


def order(a, b):
    """A fixed pseudo-random order (FNV-1a of the two keys), as the Swift exporter uses."""
    value = 14_695_981_039_346_656_037
    for byte in (a + b).encode():
        value = ((value ^ byte) * 1_099_511_628_211) & 0xFFFFFFFFFFFFFFFF
    return value


def yyyymmdd(value):
    """A calendar day from an eight-digit GDELT day; None when it is not one."""
    try:
        return date(int(value[:4]), int(value[4:6]), int(value[6:8]))
    except ValueError:
        return None


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


def names_in(headline):
    return {name.lower() for name in CAPITALIZED.findall(headline)}


class Writer:
    """Rows go to a `.part` file that `close` publishes under the final name, so an interrupted build leaves no
    header-only CSV that would block the next run; the link step fails if the final file appeared meanwhile."""

    def __init__(self, path, tokenizer):
        require(not path.exists(), f'{path} exists; remove it to rebuild')
        self.path = path
        self.part = path.with_name(f'{path.name}.{os.getpid()}.part')  # one partial file per build
        self.handle = self.part.open('w', newline='', encoding='utf-8')
        os.chmod(self.part, 0o600)
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
        pieces = [' '.join(map(str, self.tokenizer.pieces(text))) for text in (text_a, text_b)]
        self.csv.writerow([label, group, text_a, text_b, pieces[0], pieces[1], f'{weight:g}'])
        self.rows += 1
        return True

    def close(self):
        self.handle.close()
        os.link(self.part, self.path)
        self.part.unlink()


# --- WCEP-10 ---------------------------------------------------------------------------------------------------------

def wcep_clusters(split, limit, cache):
    """Clusters of article texts from the WCEP-10 split (`train.zip` holds `train.txt`, one JSON object per line)."""
    from huggingface_hub import hf_hub_download
    archive = hf_hub_download('ccdv/WCEP-10', f'{split}.zip', repo_type='dataset', revision=WCEP_REVISION,
                              local_dir=str(cache))
    with zipfile.ZipFile(archive) as z:
        name = next(n for n in z.namelist() if n.endswith('.txt'))
        with z.open(name) as handle:
            for index, line in enumerate(io.TextIOWrapper(handle, encoding='utf-8')):
                if limit and index >= limit:
                    break
                row = json.loads(line)
                yield f'{split}-{index}', [d for d in row['document'] if isinstance(d, str)]


def cluster_texts(documents):
    """Up to ten (headline, lead) pairs of a cluster; a headline under four words is skipped."""
    texts = []
    for document in documents:
        parsed = headline_and_lead(document)
        if parsed and len(parsed[0].split()) >= 4:
            texts.append(parsed)
    return texts[:10]


def wcep_positives(cluster, texts, writer):
    """Pairs inside one cluster, capped, in the fixed order."""
    pairs = [(i, j) for i in range(len(texts)) for j in range(i + 1, len(texts))]
    pairs.sort(key=lambda p, cluster=cluster: order(f'{cluster}:{p[0]}', f'{cluster}:{p[1]}'))
    return sum(1 for i, j in pairs[:WCEP_POSITIVES_PER_CLUSTER]
               if writer.write(1, 'w:' + cluster, pair_text(*texts[i]), pair_text(*texts[j])))


def texts_by_name(headlines):
    """Text keys grouped by each capitalized name their headline carries, at most 40 per name."""
    by_name = {}
    for key, (headline, _) in headlines.items():
        for name in names_in(headline):
            by_name.setdefault(name, []).append(key)
    return [keys[:40] for keys in by_name.values()]


def cross_cluster_pairs(sample):
    """Unordered pairs of keys from different clusters."""
    return {(a, b) if a < b else (b, a) for n, a in enumerate(sample) for b in sample[n + 1:] if a[0] != b[0]}


def wcep_negative_candidates(headlines):
    """Pairs of texts from different clusters whose headlines share a capitalized name, in the fixed order."""
    candidates = set()
    for sample in texts_by_name(headlines):
        candidates |= cross_cluster_pairs(sample)
    return sorted(candidates, key=lambda c: order(f'{c[0][0]}:{c[0][1]}', f'{c[1][0]}:{c[1][1]}'))


def build_wcep(clusters, writer):
    """Pairs inside a cluster are one event; pairs across clusters that share a capitalized headline name are not."""
    headlines = {}
    positives = 0
    for cluster, documents in clusters:
        texts = cluster_texts(documents)
        positives += wcep_positives(cluster, texts, writer)
        for index, text in enumerate(texts):
            headlines[(cluster, index)] = text
    negatives = 0
    for a, b in wcep_negative_candidates(headlines):
        if negatives >= 2 * positives:
            break
        if writer.write(0, 'wn:' + a[0], pair_text(*headlines[a]), pair_text(*headlines[b])):
            negatives += 1
    return positives, negatives


# --- GDELT ------------------------------------------------------------------------------------------------------------

def gdelt_slots(start, end, per_day):
    """Fifteen-minute file stamps, `per_day` of them a day, from `start` to `end` inclusive."""
    step = 24 // per_day
    day = yyyymmdd(start)
    last = yyyymmdd(end)
    require(day and last and day <= last, 'Give --from and --to as YYYYMMDD, from first')
    while day <= last:
        for hour in range(0, 24, step):
            yield f'{day:%Y%m%d}{hour:02d}0000'
        day += timedelta(days=1)


def gdelt_download(slot, kind, cache):
    """One GDELT file, cached; `kind` is export, mentions or gkg. A missing 15-minute file is normal and skipped."""
    suffix = {'export': 'export.CSV.zip', 'mentions': 'mentions.CSV.zip', 'gkg': 'gkg.csv.zip'}[kind]
    target = cache / f'{slot}.{suffix}'
    if not target.exists():
        try:
            target.write_bytes(fetch(GDELT + target.name))
            os.chmod(target, 0o600)
        except OSError as error:  # URLError and TimeoutError are OSErrors
            print(f'    skip {target.name}: {error}', file=sys.stderr)
            return None
    return target


def read_zip_tsv(path):
    with zipfile.ZipFile(path) as z:
        for name in z.namelist():
            with z.open(name) as handle:
                for line in io.TextIOWrapper(handle, encoding='utf-8', errors='replace'):
                    yield line.rstrip('\n').split('\t')


def gdelt_file_rows(slot, kind, cache, width):
    """Rows of one cached GDELT file that have at least `width` columns; none when the file is missing."""
    path = gdelt_download(slot, kind, cache)
    return (row for row in read_zip_tsv(path) if len(row) >= width) if path else ()


def gdelt_events(rows, events):
    """Events with both actors: id → (day, Actor1Name, Actor2Name, ActionGeo country)."""
    for row in rows:
        if row[6] and row[16]:
            events[row[0]] = (row[1], row[6], row[16], row[53])


def gdelt_mentions(rows, mentions):
    """Web mentions (type 1): event id → article URLs."""
    for row in rows:
        if row[3] == '1':
            mentions.setdefault(row[0], []).append(row[5])


def gdelt_titles(rows, titles):
    """Page titles from the GKG extras: article URL → decoded title."""
    for row in rows:
        if match := PAGE_TITLE.search(row[26]):
            titles[row[4]] = html.unescape(match.group(1)).strip()


def gdelt_rows(slots, cache):
    """Events (id → day, actors, country), mentions (id → urls) and page titles (url → title) of the slots."""
    events, mentions, titles = {}, {}, {}
    for slot in slots:
        gdelt_events(gdelt_file_rows(slot, 'export', cache, 61), events)
        gdelt_mentions(gdelt_file_rows(slot, 'mentions', cache, 6), mentions)
        gdelt_titles(gdelt_file_rows(slot, 'gkg', cache, 27), titles)
    return events, mentions, titles


FRONT_PAGE = re.compile(r'(home|news)\b', re.IGNORECASE)  # a site's front page, not "Newsom" or "Homeowners"


def gdelt_title(event_id, mentions, titles):
    """A usable headline of one event: four words or more and not a site's front page."""
    for url in mentions.get(event_id, []):
        title = titles.get(url)
        if title and len(title.split()) >= 4 and not FRONT_PAGE.match(title):
            return title
    return None


def gdelt_candidates(events, mentions, titles):
    """Same coded actors and country is coarse ("POLICE", "UNITED STATES"); the headlines must also share a name, so
    the pair is the same-topic-different-story case the model confuses, not two unrelated reports."""
    groups = {}
    for event_id, (day, actor1, actor2, country) in events.items():
        title = gdelt_title(event_id, mentions, titles)
        if title and (when := yyyymmdd(day)):
            groups.setdefault((actor1, actor2, country), []).append((event_id, when, title, names_in(title)))
    candidates = []
    for members in groups.values():
        members = sorted(members)[:GDELT_SAMPLE]
        for n, (a_id, a_day, a_title, a_names) in enumerate(members):
            for b_id, b_day, b_title, b_names in members[n + 1:]:
                gap = abs((a_day - b_day).days)
                if 1 <= gap <= 7 and a_title.lower() != b_title.lower() and a_names & b_names:
                    candidates.append((a_id, b_id, a_title, b_title))
    return sorted(candidates, key=lambda c: order(c[0], c[1]))


def build_gdelt(events, mentions, titles, writer, cap):
    """Same actors and country, different event and day, one to seven days apart: a hard negative."""
    written = 0
    for a_id, _, a_title, b_title in gdelt_candidates(events, mentions, titles):
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
            target.write_bytes(fetch(ZENODO + name + '/content'))
            os.chmod(target, 0o600)
        with target.open(newline='', encoding='utf-8') as handle:
            for row in csv.DictReader(handle):
                if row.get('url1_lang') == 'en' and row.get('url2_lang') == 'en':
                    yield (row['pair_id'], row.get('ia_link1') or row['link1'], row.get('ia_link2') or row['link2'],
                           float(row.get('Overall') or row.get('OVERALL')))


def page_fields(body):
    """Title and lead of an HTML page, or None when it has no title or under 200 characters of paragraphs."""
    title = TITLE.search(body)
    text = ' '.join(WHITESPACE.sub(' ', TAG.sub(' ', html.unescape(p))).strip() for p in PARAGRAPH.findall(body))
    if not title or len(text) < 200:
        return None
    headline = WHITESPACE.sub(' ', html.unescape(TAG.sub(' ', title.group(1)))).strip()[:200]
    return {'title': headline, 'lead': text[:LEAD]}


def archived_page(url, cache, attempts=3):
    """Title and first paragraphs of a page from the Internet Archive, cached by URL hash. A page the archive does
    not have (404, 403) is cached as None; a rate limit, server error or timeout is retried with a pause and never
    cached, so a later run fetches it again."""
    key = hashlib.sha256(url.encode()).hexdigest()
    target = cache / 'pages' / (key + '.json')
    if target.exists():
        return json.loads(target.read_text())
    archived = url if url.startswith(ARCHIVE) else ARCHIVE + 'web/2020id_/' + url
    for attempt in range(attempts):
        try:
            result = page_fields(fetch(archived, timeout=60, limit=400_000).decode('utf-8', errors='replace'))
            break
        except urllib.error.HTTPError as error:
            if error.code in (403, 404, 410):
                result = None
                break
            time.sleep(15 * (attempt + 1))
        except (OSError, ValueError):  # URLError and TimeoutError are OSErrors
            time.sleep(15 * (attempt + 1))
    else:
        return None
    target.parent.mkdir(exist_ok=True)
    # Written beside the target and moved into place, so an interrupted write never leaves a half file to parse.
    partial = target.with_name(f'{key}.{os.getpid()}.{threading.get_ident()}.tmp')
    partial.write_text(json.dumps(result))
    os.chmod(partial, 0o600)
    os.replace(partial, target)
    return result


def semeval_label(overall):
    """Overall similarity 1 (most similar) is one story, 3 and 4 are not, 2 is ambiguous and dropped."""
    if overall < 1.5:
        return 1
    if overall >= 2.5:
        return 0
    return None


def build_semeval(pairs, writer, page, workers=FETCH_WORKERS):
    """Labelled pairs whose two pages are available; pages are fetched a few at a time."""
    pairs = [pair for pair in pairs if semeval_label(pair[3]) is not None]
    urls = sorted({url for pair in pairs for url in pair[1:3]})  # one fetch per page, however many pairs cite it
    with ThreadPoolExecutor(max_workers=workers) as pool:
        pages = dict(zip(urls, pool.map(page, urls), strict=True))
    written = 0
    for pair_id, link1, link2, overall in pairs:
        a, b = pages.get(link1), pages.get(link2)
        if a and b and writer.write(semeval_label(overall), 's:' + pair_id, pair_text(a['title'], a['lead']),
                                    pair_text(b['title'], b['lead']), 2):
            written += 1
    return written


# --- entry points -----------------------------------------------------------------------------------------------------

def summarize(path):
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    with path.open(newline='', encoding='utf-8') as handle:
        rows = list(csv.DictReader(handle))
    positives = sum(1 for r in rows if r['label'] == '1')
    print(f'    {path.name}: {len(rows)} pairs, {positives} same event, {len(rows) - positives} different; '
          f'sha256 {digest}')


def self_check():
    import tempfile
    tokenizer = Tokenizer()
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
        actors = ('GOVERNMENT', 'PROTESTER', 'FR')
        events = {'1': ('20260101', *actors), '2': ('20260103', *actors), '3': ('20260101', *actors),
                  '4': ('20260120', *actors), '5': ('20260102', *actors)}
        mentions = {'1': ['u1'], '2': ['u2'], '3': ['u3'], '4': ['u4'], '5': ['u5']}
        titles = {'u1': 'Police clear protest camp in Paris after night of clashes',
                  'u2': 'Paris court fines protest leaders over camp',
                  'u3': 'Police clear protest camp in Paris after night of clashes',
                  'u4': 'Protest season ends in Paris', 'u5': 'Lyon bakery wins national prize'}
        writer = Writer(out / 'gdelt.csv', tokenizer)
        written = build_gdelt(events, mentions, titles, writer, cap=10)
        writer.close()
        # 1–2 and 3–2 qualify but carry the same two texts, so one row; 1–3 share a day; 4 is too far away; 5 shares
        # no headline name.
        require(written == 1, f'GDELT self-check: {written} negatives')
        pages = {'a': {'title': 'Storm hits coast', 'lead': 'x' * 300},
                 'b': {'title': 'Coastal storm batters towns', 'lead': 'y' * 300},
                 'c': {'title': 'Budget vote delayed', 'lead': 'z' * 300}}
        writer = Writer(out / 'semeval.csv', tokenizer)
        written = build_semeval([('p1', 'a', 'b', 1.0), ('p2', 'a', 'c', 3.7), ('p3', 'b', 'c', 2.0)], writer,
                                pages.get, workers=1)
        writer.close()
        require(written == 2, f'SemEval self-check: {written} pairs (the ambiguous 2 dropped)')
        with (out / 'semeval.csv').open(newline='') as handle:
            rows = list(csv.DictReader(handle))
        require(rows[0]['weight'] == '2' and rows[0]['label'] == '1' and rows[1]['label'] == '0',
                'SemEval labels and weight')
        require(list(gdelt_slots('20260101', '20260102', 2)) == ['20260101000000', '20260101120000', '20260102000000',
                                                                 '20260102120000'], 'GDELT slots')
    print('pretrain_pairs self-check passed')


def parse(argv):
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
    return parser.parse_args(argv)


def run_wcep(args, out, tokenizer):
    writer = Writer(out / 'wcep-pairs.csv', tokenizer)
    positives, negatives = build_wcep(wcep_clusters(args.split, args.clusters, out / 'wcep'), writer)
    writer.close()
    print(f'    WCEP-10 {args.split} (revision {WCEP_REVISION[:12]}): {positives} positives, {negatives} negatives')
    summarize(out / 'wcep-pairs.csv')


def run_gdelt(args, out, tokenizer):
    cache = out / 'gdelt'
    cache.mkdir(exist_ok=True)
    events, mentions, titles = gdelt_rows(gdelt_slots(args.start, args.end, args.slots_per_day), cache)
    print(f'    GDELT {args.start}-{args.end}: {len(events)} events with two actors, {len(titles)} titled pages')
    writer = Writer(out / 'gdelt-negatives.csv', tokenizer)
    written = build_gdelt(events, mentions, titles, writer, args.cap)
    writer.close()
    print(f'    {written} hard negatives')
    summarize(out / 'gdelt-negatives.csv')


def run_semeval(_args, out, tokenizer):
    cache = out / 'semeval'
    cache.mkdir(exist_ok=True)
    writer = Writer(out / 'semeval-pairs.csv', tokenizer)
    written = build_semeval(semeval_pairs(cache), writer, lambda url: archived_page(url, cache))
    writer.close()
    print(f'    SemEval-2022 Task 8: {written} English pairs')
    summarize(out / 'semeval-pairs.csv')


def main(argv=None):
    args = parse(argv)
    if args.self_check:
        self_check()
        return
    require(args.command, 'wcep, gdelt or semeval')
    {'wcep': run_wcep, 'gdelt': run_gdelt, 'semeval': run_semeval}[args.command](args, private_directory(args.out),
                                                                                  Tokenizer())


if __name__ == '__main__':
    main()
