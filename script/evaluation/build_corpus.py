#!/usr/bin/env python3
"""Build metadata-only W2E sample; never copy event summaries or publisher bodies."""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import tempfile
import urllib.parse
import zipfile


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def canonical(url):
    parts = urllib.parse.urlsplit(url)
    query = [(k, v) for k, v in urllib.parse.parse_qsl(parts.query, keep_blank_values=True)
             if not k.lower().startswith('utm_') and k.lower() not in
             {'ref', 'rss_source', 'feedburner', 'fbclid', 'gclid', 'mc_cid', 'mc_eid', 'yclid', 'igshid'}]
    return urllib.parse.urlunsplit(('https' if parts.scheme == 'http' else parts.scheme,
                                  parts.netloc.lower(), parts.path.rstrip('/') or '/',
                                  urllib.parse.urlencode(query), parts.fragment))


def read_groups(path, join):
    group = None
    for line in path.read_text().splitlines():
        if line.startswith('GROUP-'):
            group = line.strip()
        elif line.startswith('TOPIC-'):
            join(group, line.split('\t')[0])


def read_topics(path):
    topics = {}
    current = None
    for line in path.read_text().splitlines():
        if line.startswith('TOPIC-'):
            fields = line.split('\t')
            current = fields[0]
            topics[current] = {'category': fields[1], 'dates': []}
        elif len(line) > 10 and line[4] == '-' and line[7] == '-':
            topics[current]['dates'].append(line.split('\t')[0])
    return topics


def article_rows(text):
    for line in text.splitlines():
        fields = line.split('\t')
        if len(fields) != 2:
            continue
        date, url = fields
        parts = urllib.parse.urlsplit(url)
        if parts.scheme in ('http', 'https') and parts.hostname and not parts.username and not parts.password:
            yield date, url, parts.hostname.lower()


def read_articles(path, topics, join):
    rows, url_owner = {}, {}
    with zipfile.ZipFile(path) as archive:
        # Read members without extracting archive paths to disk.
        for name in sorted(archive.namelist()):
            topic = pathlib.PurePosixPath(name).stem
            if topic not in topics:
                continue
            rows[topic] = list(article_rows(archive.read(name).decode('utf-8')))
            for _, url, _ in rows[topic]:
                key = canonical(url)
                if key in url_owner:
                    join(topic, url_owner[key])
                else:
                    url_owner[key] = topic
    return rows


def candidate_topics(topics, rows, root):
    candidates = []
    for topic, info in topics.items():
        if len(info['dates']) != 1:
            continue
        day = datetime.date.fromisoformat(info['dates'][0])
        docs = []
        for date, url, host in sorted(rows.get(topic, []), key=lambda row: digest(row[1])):
            if abs((datetime.date.fromisoformat(date) - day).days) <= 1 and host not in {d[2] for d in docs}:
                docs.append((date, url, host))
        if len(docs) >= 3:
            candidates.append((topic, root(topic), info, docs[:3]))
    return candidates


def select_topics(candidates):
    selected = []
    groups = set()
    for item in sorted(candidates, key=lambda item: digest('news-corpus-v1:' + item[1])):
        if item[1] not in groups:
            selected.append(item)
            groups.add(item[1])
        if len(selected) == 100:
            break
    assert len(selected) == 100, 'Need 100 disjoint single-event groups'
    return selected


def imported_pairs(selected):
    documents, events, pairs = [], [], []
    for index, (topic, group, info, rows_) in enumerate(selected):
        split = 'tuning' if index < 70 else 'holdout'
        event = 'w2e-' + topic.lower()
        events.append({'id': event, 'group': group, 'split': split, 'category': info['category'],
                       'date': info['dates'][0], 'provenance': 'w2e-author-relevance'})
        for ordinal, (day, url, source) in enumerate(rows_):
            documents.append({'id': f'{event}-{ordinal}', 'event': event, 'url': url, 'source': source,
                              'language': 'undetermined', 'observedDay': day, 'provenance': 'w2e-url'})
        for ordinal in [1, 2]:
            pairs.append({'left': f'{event}-0', 'right': f'{event}-{ordinal}', 'label': 'same_event',
                          'split': split, 'provenance': 'w2e-single-event-topic'})
    return documents, events, pairs


def add_event_negatives(events, pairs):
    # Negatives stay inside a split; different merged topic/URL families are never split apart.
    for split in ['tuning', 'holdout']:
        subset = [e for e in events if e['split'] == split]
        for index, event in enumerate(subset):
            other = subset[(index + 1) % len(subset)]
            pairs.append({'left': event['id'] + '-0', 'right': other['id'] + '-0', 'label': 'different',
                          'split': split, 'provenance': 'w2e-distinct-merged-groups'})


def add_tracking_controls(documents, events, pairs):
    # Derived identity controls, explicitly not independent publisher observations.
    for index, event in enumerate(events[:]):
        original = next(d for d in documents if d['id'] == event['id'] + '-0')
        variant = dict(original, id=original['id'] + '-tracking', provenance='derived-tracking-control')
        p = urllib.parse.urlsplit(original['url'])
        variant['url'] = urllib.parse.urlunsplit(p._replace(query=p.query + ('&' if p.query else '') + 'utm_source=corpus'))
        documents.append(variant)
        pairs.append({'left': original['id'], 'right': variant['id'], 'label': 'same_document',
                      'split': event['split'], 'provenance': 'derived-tracking-control'})


def add_authored_controls(documents, events, pairs):
    # Authored controls are fiction, not additional publisher observations.
    details = {
        'en': [('Quarterly results announced', 'Aster company reported first-quarter revenue of 120 units.', 'Aster company reported second-quarter revenue of 85 units.'),
               ('Workers strike in the northern region', 'Riverport nurses began a strike over staffing at the regional hospital.', 'Hilltown railway drivers began a strike over pensions at the northern depot.'),
               ('Council approves new project', 'Riverport council approved construction of a municipal library.', 'Riverport council approved replacement of the municipal water treatment plant.')],
        'uk': [('Компанія оголосила квартальні результати', 'Компанія Астер повідомила про дохід за перший квартал у розмірі 120 одиниць.', 'Компанія Астер повідомила про дохід за другий квартал у розмірі 85 одиниць.'),
               ('Працівники страйкують у північному регіоні', 'Медсестри Річкового почали страйк через нестачу персоналу в обласній лікарні.', 'Машиністи Гірського почали страйк через пенсійні умови у північному депо.'),
               ('Рада схвалила новий проєкт', 'Рада Річкового схвалила будівництво міської бібліотеки.', 'Рада Річкового схвалила заміну міської станції очищення води.')],
        'pl': [('Spółka ogłosiła wyniki kwartalne', 'Spółka Aster podała przychód za pierwszy kwartał w wysokości 120 jednostek.', 'Spółka Aster podała przychód za drugi kwartał w wysokości 85 jednostek.'),
               ('Pracownicy strajkują w północnym regionie', 'Pielęgniarki Rzecznego rozpoczęły strajk z powodu braków kadrowych w szpitalu.', 'Maszyniści Górskiego rozpoczęli strajk dotyczący emerytur w północnej zajezdni.'),
               ('Rada zatwierdziła nowy projekt', 'Rada Rzecznego zatwierdziła budowę biblioteki miejskiej.', 'Rada Rzecznego zatwierdziła wymianę miejskiej stacji uzdatniania wody.')]
    }
    for language, cases in details.items():
        for index in range(10):
            family = f'control-{language}-{index}'
            split = 'tuning' if index < 7 else 'holdout'
            kind = ['quarterly_reports', 'regional_strikes', 'identical_headlines'][index % 3]
            title, left, right = cases[index % 3]
            for side, text in enumerate([left, right]):
                event = family + f'-event-{side}'
                events.append({'id': event, 'group': family, 'split': split, 'category': kind,
                               'date': f'2026-0{side + 1}-15', 'provenance': 'authored-control'})
                documents.append({'id': event, 'event': event, 'url': f'https://{family}.example/report-{side}',
                                  'source': f'{language}-control-publisher', 'language': language,
                                  'observedDay': f'2026-0{side + 1}-15', 'provenance': 'authored-control',
                                  'title': title, 'body': (text + ' ') * 12 + f' [Fictional case {family}]',
                                  'publishedAt': f'2026-0{side + 1}-15T12:00:00Z'})
            pairs.append({'left': family + '-event-0', 'right': family + '-event-1', 'label': 'different',
                          'split': split, 'provenance': 'authored-' + kind})
            original = documents[-2]
            copy = dict(original, id=original['id'] + '-copy', url=original['url'] + '-copy',
                        body=original['body'].replace(' ', '\n  '), provenance='authored-content-copy')
            documents.append(copy)
            pairs.append({'left': original['id'], 'right': copy['id'], 'label': 'same_document',
                          'split': split, 'provenance': 'authored-content-copy'})


def write_corpus(result, destination):
    # CLI arguments may come from copied/untrusted instructions. Never replace a
    # file, follow an output symlink, or write outside the fixture/temp roots.
    if destination.is_symlink():
        raise ValueError('Output must not be a symlink')
    output = destination.resolve()
    fixture = pathlib.Path(__file__).resolve().parents[2] / 'Tests/Fixtures/story-corpus'
    roots = (fixture.resolve(), pathlib.Path(tempfile.gettempdir()).resolve())
    if output.suffix != '.json' or not any(output.is_relative_to(root) for root in roots):
        raise ValueError('Output must be a new JSON file inside the fixture or temporary directory')
    parent = output.parent.stat()
    if parent.st_uid != os.getuid() or parent.st_mode & 0o022:
        raise ValueError('Output directory must be owned by the current user and not writable by others')
    with output.open('x', encoding='utf-8') as handle:
        handle.write(json.dumps(result, ensure_ascii=False, indent=2) + '\n')


def build(args):
    parents = {}
    def root(key):
        parents.setdefault(key, key)
        if parents[key] != key:
            parents[key] = root(parents[key])
        return parents[key]
    def join(a, b):
        a, b = root(a), root(b)
        parents[max(a, b)] = min(a, b)

    read_groups(args.groups, join)
    topics = read_topics(args.events)
    rows = read_articles(args.articles, topics, join)
    selected = select_topics(candidate_topics(topics, rows, root))
    documents, events, pairs = imported_pairs(selected)
    add_event_negatives(events, pairs)
    add_tracking_controls(documents, events, pairs)
    add_authored_controls(documents, events, pairs)
    for index, pair in enumerate(pairs):
        pair['id'] = f'pair-{index:03d}'
    result = {'version': 1, 'releaseEligible': False, 'documents': documents, 'events': events, 'pairs': pairs,
              'provenance': {'source': 'https://github.com/smutahoang/w2e', 'retrievedOn': '2026-10-02',
                             'authors': 'Tuan-Anh Hoang, Khoi Duy Vo, Wolfgang Nejdl (CIKM 2018)',
                             'inputSHA256': {name: hashlib.sha256(path.read_bytes()).hexdigest()
                                             for name, path in [('articles', args.articles), ('events', args.events), ('groups', args.groups)]},
                             'note': 'Original author topic relevance reused, not a new independent article review. No publisher text or WCEP summaries redistributed. Control bodies are authored fiction. Languages of URL-only records are unknown.'}}
    write_corpus(result, args.output)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for name in ['articles', 'events', 'groups', 'output']:
        parser.add_argument('--' + name, required=True, type=pathlib.Path)
    build(parser.parse_args())
