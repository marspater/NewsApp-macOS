#!/usr/bin/env python3
"""Blind reader comparison of the three Lead rankings (#934): build the sheet, score filled sheets, aggregates only.

A run directory holds `lead-rankings-private.json` from `./test.sh --today-shadow` (script/today_lead.sh pack puts
it there): every story in the top 20 of at least one ranking (publisher count, Briefing signals, Z2 score) with its
place in each. That file is the key; readers never open it.

`sheet RUN` writes RUN/lead-review-private.csv: those stories in a shuffled order with headline, summary and
publisher, and no place, score or lane. Each reader fills a copy named lead-review-private-<reader>.csv, writing
`lead` (belongs among the day's most important stories) or `not` in the label column.
`report RUN [RUN ...]` reads every reader copy of every run (one run per snapshot day) and writes
lead-evaluation.json into the first run: precision at 5, 10 and 20 per ranking, per reader and day and pooled, how far
the rankings' top 20s overlap, and how far the readers agree. It contains no story text.
A key from `script/today_lead.sh arms` (#999) names the three arms `current`, `base` and `base+mmr` as its rankings
and is scored the same way; a report takes runs of one kind. NDCG@10 counts `lead` as grade 1.
With no arguments, the script checks itself on synthetic runs.
"""
import argparse
import hashlib
import itertools
import json
import math
import pathlib
import shutil
import tempfile

from overview_review import (
    expect_rejected,
    label_sheet,
    private_run,
    rate,
    read_sheet_labels,
    require,
    write_new_sheet,
)

LABELS = ('lead', 'not')
RANKINGS = ('publisherCount', 'briefing', 'z2')
ARMS = ('current', 'base', 'base+mmr')
DEPTHS = (5, 10, 20)
SOURCE = 'lead-rankings-private.json'
SHEET = 'lead-review-private.csv'
REPORT = 'lead-evaluation.json'
COLUMNS = ['story', 'publisher', 'title', 'summary', 'label', 'note']


def key(directory):
    path = directory / SOURCE
    require(path.exists(), f'No {SOURCE} in the run directory; run script/today_lead.sh pack first')
    data = json.loads(path.read_text())
    used = set().union(*(row['ranks'] for row in data['stories']))
    kinds = [names for names in (RANKINGS, ARMS) if used <= set(names)]
    require(kinds and all(row['ranks'] for row in data['stories']), 'Unknown ranking in the key')
    data['rankings'] = kinds[0]
    return data


def review_rows(data):
    """The key's stories in an order that depends only on their ids, so it says nothing about a ranking."""
    rows = [{'story': row['id'], 'publisher': row['publisher'], 'title': row['title'], 'summary': row['summary'],
             'label': '', 'note': ''} for row in data['stories']]
    salt = '\n'.join(sorted(row['story'] for row in rows))
    return sorted(rows, key=lambda row: hashlib.sha256(f"{salt}\n{row['story']}".encode()).hexdigest())


def sheet(directory):
    directory = private_run(directory)
    return write_new_sheet(directory / SHEET, COLUMNS, review_rows(key(directory)))


def top(data, ranking, depth):
    return [row['id'] for row in data['stories'] if row['ranks'].get(ranking, depth + 1) <= depth]


def ndcg(data, ranking, labels, depth=10):
    """NDCG of a ranking's top, `lead` as grade 1 and an unlabelled story as 0; the ideal list holds every story the
    reader called `lead` on the sheet, whichever ranking put it there. None when the reader called none."""
    gain = sum(1 / math.log2(row['ranks'][ranking] + 1) for row in data['stories']
               if row['ranks'].get(ranking, depth + 1) <= depth and labels.get(row['id']) == 'lead')
    leads = sum(label == 'lead' for label in labels.values())
    return gain / sum(1 / math.log2(place + 1) for place in range(1, min(depth, leads) + 1)) if leads else None


def precision(data, labels):
    """Per ranking and depth: Lead-worthy stories among the labelled ones of that ranking's top; and NDCG@10."""
    result = {}
    for ranking in data['rankings']:
        result[ranking] = {'ndcgAt10': ndcg(data, ranking, labels)}
        for depth in DEPTHS:
            judged = [labels[story] for story in top(data, ranking, depth) if labels.get(story)]
            result[ranking][f'at{depth}'] = rate(sum(label == 'lead' for label in judged), len(judged))
    return result


def kappa(first, second):
    """Cohen's kappa of two readers over the stories both labelled; None when chance agreement is total."""
    shared = [story for story in first if first[story] and second.get(story)]
    if not shared:
        return {'stories': 0, 'agree': 0, 'kappa': None}
    agree = sum(first[story] == second[story] for story in shared)
    share = lambda labels: sum(labels[story] == 'lead' for story in shared) / len(shared)
    chance = share(first) * share(second) + (1 - share(first)) * (1 - share(second))
    return {'stories': len(shared), 'agree': agree,
            'kappa': None if chance == 1 else (agree / len(shared) - chance) / (1 - chance)}


def day(directory):
    directory = private_run(directory)
    data = key(directory)
    expected = review_rows(data)
    readers = {}
    for path in sorted(directory.glob('lead-review-private-*.csv')):
        readers[path.stem.removeprefix('lead-review-private-')] = read_sheet_labels(path, 'story', LABELS, expected)
    overlap = {f'{a}/{b}': len(set(top(data, a, DEPTHS[-1])) & set(top(data, b, DEPTHS[-1])))
               for a, b in itertools.combinations(data['rankings'], 2)}
    return {'run': directory.name, 'rankings': list(data['rankings']), 'pool': data['pool'], 'candidates': data['candidates'], 'sheetStories': len(expected),
            'top20Overlap': overlap,
            'unlabelled': {name: sum(not labels.get(row['story']) for row in expected) for name, labels in readers.items()},
            'perReader': {name: precision(data, labels) for name, labels in readers.items()},
            'agreement': {f'{a}/{b}': kappa(readers[a], readers[b]) for a, b in itertools.combinations(sorted(readers), 2)}}


def pooled(days):
    """Every reader and day counted once per ranking and depth; NDCG@10 as the mean over readers and days."""
    result = {}
    for ranking in days[0]['rankings']:
        scores = [reader[ranking]['ndcgAt10'] for entry in days for reader in entry['perReader'].values()]
        scores = [score for score in scores if score is not None]
        result[ranking] = {'ndcgAt10': sum(scores) / len(scores) if scores else None}
        for depth in DEPTHS:
            cells = [reader[ranking][f'at{depth}'] for entry in days for reader in entry['perReader'].values()]
            result[ranking][f'at{depth}'] = rate(sum(cell['count'] for cell in cells), sum(cell['of'] for cell in cells))
    return result


def snapshot_identity(directory, data):
    """Identity key for one snapshot day so the same run cannot count twice even when copied."""
    manifest_path = directory / 'manifest.json'
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    return (
        manifest.get('day'),
        manifest.get('clock'),
        data['nowTimestamp'],
        data['pool'],
        tuple(row['id'] for row in data['stories']),
    )


def report(directories):
    resolved = [private_run(pathlib.Path(directory)) for directory in directories]
    require(len(set(resolved)) == len(resolved), 'Each run directory may be passed at most once')
    identities = set()
    days = []
    for directory in resolved:
        identities.add(snapshot_identity(directory, key(directory)))
        days.append(day(directory))
    require(len(identities) == len(resolved), 'Each snapshot may be counted at most once')
    require(all(entry['rankings'] == days[0]['rankings'] for entry in days), 'A report takes runs of one kind')
    readers = sorted({name for entry in days for name in entry['perReader']})
    result = {
        'days': days, 'pooled': pooled(days),
        'decisionInputs': {
            'days': len(days), 'readers': len(readers),
            'labellingComplete': bool(readers) and all(
                bool(entry['perReader']) and not any(entry['unlabelled'].values()) for entry in days
            ),
            'multiReaderMultiDay': len(days) >= 2 and all(len(entry['perReader']) >= 2 for entry in days),
            'rankingsDiffer': any(count < DEPTHS[-1] for entry in days for count in entry['top20Overlap'].values()),
        },
        'limitations': 'A label judges the headline, summary and publisher of one report of the story. Precision is '
                       'taken over the labelled stories of a ranking\'s top; an incomplete sheet narrows it. Rankings '
                       'whose top 20s hold the same stories cannot be told apart at 20, only by their order at 5 and '
                       '10. Readers see one shuffled list a day, so a story two rankings share is judged once.',
    }
    (resolved[0] / REPORT).write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    return result


def fixture(directory, pool='page', now_timestamp=0):
    """24 stories: Z2 and Briefing share a top 20, publisher count swaps four of them; s1 to s6 are Lead-worthy."""
    stories = []
    for index in range(1, 25):
        ranks = {}
        if index <= 20:
            ranks['z2'] = index
            ranks['briefing'] = 21 - index
        if index > 4:
            ranks['publisherCount'] = index - 4
        stories.append({'id': f's{index}', 'publisher': 'Publisher A', 'title': f'Headline {index}',
                        'summary': f'Private summary {index}', 'ranks': ranks})
    (directory / SOURCE).write_text(json.dumps(
        {'pool': pool, 'nowTimestamp': now_timestamp, 'candidates': 150, 'depth': 20, 'stories': stories}))


def arm_fixture(directory):
    """22 stories: `current` ranks s1 to s20, `base` the reverse, `base+mmr` s3 to s22."""
    stories = [{'id': f's{index}', 'publisher': 'Publisher A', 'title': f'Headline {index}',
                'summary': f'Private summary {index}',
                'ranks': {arm: place for arm, place in (('current', index), ('base', 21 - index), ('base+mmr', index - 2))
                          if 1 <= place <= 20}} for index in range(1, 23)]
    (directory / SOURCE).write_text(json.dumps(
        {'pool': 'page', 'nowTimestamp': 0, 'candidates': 150, 'depth': 20, 'stories': stories}))


def fill(directory, reader, lead):
    path = directory / f'lead-review-private-{reader}.csv'
    shutil.copy(directory / SHEET, path)
    with path.open() as handle:
        order = [line.split(',')[0] for line in handle.read().splitlines()[1:]]
    label_sheet(path, COLUMNS, ['lead' if story in lead else 'not' for story in order])


def self_check():
    with tempfile.TemporaryDirectory() as one, tempfile.TemporaryDirectory() as two, \
            tempfile.TemporaryDirectory() as clone_root:
        first, second = pathlib.Path(one), pathlib.Path(two)
        fixture(first)
        fixture(second, now_timestamp=86400)
        require(sheet(first) == 24 and sheet(second) == 24, 'The sheet lists the union of the three top 20s')
        expect_rejected(lambda: sheet(first), FileExistsError, 'A sheet that may hold labels was replaced')
        text = (first / SHEET).read_text()
        require('rank' not in text and 'z2' not in text and 'briefing' not in text, 'The sheet names no ranking')
        require([row.split(',')[0] for row in text.splitlines()[1:]] != [f's{index}' for index in range(1, 25)],
                'The sheet is shuffled')
        require(text == (second / SHEET).read_text(), 'The same stories give the same order')
        require(not report([first])['decisionInputs']['labellingComplete'], 'No reader sheet, no complete labelling')
        strong = {f's{index}' for index in range(1, 7)}
        fill(first, 'a', strong)
        fill(first, 'b', strong | {'s7'})
        require(not report([first, second])['decisionInputs']['labellingComplete'],
                'Unlabelled second day prevents complete labelling')
        expect_rejected(lambda: report([first, first]), ValueError, 'Same run directory rejected')
        clone = pathlib.Path(clone_root) / 'copy'
        shutil.copytree(first, clone)
        expect_rejected(lambda: report([first, clone]), ValueError, 'Copied snapshot rejected')
        fill(second, 'a', strong)
        fill(second, 'b', strong)
        result = report([first, second])
        z2 = result['days'][0]['perReader']['a']['z2']
        require((z2['at5']['count'], z2['at10']['count'], z2['at20']['count']) == (5, 6, 6), 'Z2 precision counts')
        require(result['days'][0]['perReader']['a']['briefing']['at5']['count'] == 0, 'Briefing ranks them last')
        require(result['days'][0]['perReader']['a']['publisherCount']['at5']['count'] == 2, 'Publisher count at 5')
        require(result['days'][0]['top20Overlap'] == {'publisherCount/briefing': 16, 'publisherCount/z2': 16,
                                                     'briefing/z2': 20}, 'Top-20 overlap')
        require(result['pooled']['z2']['at5'] == rate(20, 20), 'Pooled over two readers and two days')
        agreement = result['days'][0]['agreement']['a/b']
        require((agreement['stories'], agreement['agree']) == (24, 23) and 0.88 < agreement['kappa'] < 0.9, 'Kappa')
        require(result['days'][1]['agreement']['a/b']['kappa'] == 1, 'Full agreement')
        inputs = result['decisionInputs']
        require(inputs == {'days': 2, 'readers': 2, 'labellingComplete': True, 'multiReaderMultiDay': True,
                           'rankingsDiffer': True}, 'Decision inputs')
        public = (first / REPORT).read_text()
        require('Headline' not in public and 'Private summary' not in public, 'The report carries no story text')
        (second / 'lead-review-private-c.csv').write_text((second / SHEET).read_text().replace('Headline 3', 'Edited'))
        expect_rejected(lambda: report([second]), ValueError, 'A sheet with a changed headline was scored')
        reader = result['days'][0]['perReader']['a']
        require(reader['z2']['ndcgAt10'] == 1 and reader['briefing']['ndcgAt10'] == 0, 'NDCG@10 of first and last places')
        require(result['pooled']['z2']['ndcgAt10'] == 1, 'Pooled NDCG@10')
    with tempfile.TemporaryDirectory() as three, tempfile.TemporaryDirectory() as mixed:
        arms, other = pathlib.Path(three), pathlib.Path(mixed)
        arm_fixture(arms)
        fixture(other, now_timestamp=1)
        require(sheet(arms) == 22 and sheet(other) == 24, 'The arm sheet lists the union of the three top 20s')
        require(not any(arm in (arms / SHEET).read_text() for arm in ARMS), 'The sheet names no arm')
        fill(arms, 'a', {'s1', 's2', 's3'})
        expect_rejected(lambda: report([arms, other]), ValueError, 'Arm and Z2 runs scored together')
        scored = report([arms])
        reader = scored['days'][0]['perReader']['a']
        require(scored['days'][0]['rankings'] == list(ARMS) and set(scored['pooled']) == set(ARMS), 'Arms are scored')
        require([reader[arm]['at5']['count'] for arm in ARMS] == [3, 0, 1], 'Arm precision at 5')
        ideal = 1 + 1 / math.log2(3) + 0.5
        require(reader['current']['ndcgAt10'] == 1 and reader['base']['ndcgAt10'] == 0
                and abs(reader['base+mmr']['ndcgAt10'] - 1 / ideal) < 1e-12, 'Arm NDCG@10')
        require(scored['days'][0]['top20Overlap'] == {'current/base': 20, 'current/base+mmr': 18, 'base/base+mmr': 18},
                'Arm overlap')
        fill(arms, 'b', set())
        require(report([arms])['days'][0]['perReader']['b']['current']['ndcgAt10'] is None, 'No lead, no NDCG')
    print('lead_review self-check passed')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('command', nargs='?', choices=['sheet', 'report'])
    parser.add_argument('runs', nargs='*', type=pathlib.Path)
    args = parser.parse_args()
    if args.command is None:
        self_check()
    elif not args.runs or (args.command == 'sheet' and len(args.runs) != 1):
        parser.error('sheet takes one run directory, report one or more')
    else:
        try:
            if args.command == 'sheet':
                print(f'Wrote {sheet(args.runs[0])} stories to the run\'s review sheet')
            else:
                print(json.dumps(report(args.runs), indent=2, sort_keys=True))
        except FileExistsError as error:
            parser.exit(1, f'{error.filename} already exists and may hold labels; it was left unchanged.\n')
        except ValueError as error:
            parser.exit(1, f'{error}\n')
