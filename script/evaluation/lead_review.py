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
With no arguments, the script checks itself on synthetic runs.
"""
import argparse
import hashlib
import itertools
import json
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
DEPTHS = (5, 10, 20)
SOURCE = 'lead-rankings-private.json'
SHEET = 'lead-review-private.csv'
REPORT = 'lead-evaluation.json'
COLUMNS = ['story', 'publisher', 'title', 'summary', 'label', 'note']


def key(directory):
    path = directory / SOURCE
    require(path.exists(), f'No {SOURCE} in the run directory; run script/today_lead.sh pack first')
    data = json.loads(path.read_text())
    require(all(set(row['ranks']) <= set(RANKINGS) and row['ranks'] for row in data['stories']), 'Unknown ranking in the key')
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


def precision(data, labels):
    """Per ranking and depth: Lead-worthy stories among the labelled ones of that ranking's top."""
    result = {}
    for ranking in RANKINGS:
        result[ranking] = {}
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
               for a, b in itertools.combinations(RANKINGS, 2)}
    return {'run': directory.name, 'pool': data['pool'], 'candidates': data['candidates'], 'sheetStories': len(expected),
            'top20Overlap': overlap,
            'unlabelled': {name: sum(not labels.get(row['story']) for row in expected) for name, labels in readers.items()},
            'perReader': {name: precision(data, labels) for name, labels in readers.items()},
            'agreement': {f'{a}/{b}': kappa(readers[a], readers[b]) for a, b in itertools.combinations(sorted(readers), 2)}}


def pooled(days):
    """Every reader and day counted once per ranking and depth."""
    result = {}
    for ranking in RANKINGS:
        result[ranking] = {}
        for depth in DEPTHS:
            cells = [reader[ranking][f'at{depth}'] for entry in days for reader in entry['perReader'].values()]
            result[ranking][f'at{depth}'] = rate(sum(cell['count'] for cell in cells), sum(cell['of'] for cell in cells))
    return result


def report(directories):
    days = [day(directory) for directory in directories]
    readers = sorted({name for entry in days for name in entry['perReader']})
    result = {
        'days': days, 'pooled': pooled(days),
        'decisionInputs': {
            'days': len(days), 'readers': len(readers),
            'labellingComplete': bool(readers) and all(not any(entry['unlabelled'].values()) for entry in days),
            'multiReaderMultiDay': len(days) >= 2 and all(len(entry['perReader']) >= 2 for entry in days),
            'rankingsDiffer': any(count < DEPTHS[-1] for entry in days for count in entry['top20Overlap'].values()),
        },
        'limitations': 'A label judges the headline, summary and publisher of one report of the story. Precision is '
                       'taken over the labelled stories of a ranking\'s top; an incomplete sheet narrows it. Rankings '
                       'whose top 20s hold the same stories cannot be told apart at 20, only by their order at 5 and '
                       '10. Readers see one shuffled list a day, so a story two rankings share is judged once.',
    }
    (private_run(directories[0]) / REPORT).write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    return result


def fixture(directory, pool='page'):
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
        {'pool': pool, 'nowTimestamp': 0, 'candidates': 150, 'depth': 20, 'stories': stories}))


def fill(directory, reader, lead):
    path = directory / f'lead-review-private-{reader}.csv'
    shutil.copy(directory / SHEET, path)
    with path.open() as handle:
        order = [line.split(',')[0] for line in handle.read().splitlines()[1:]]
    label_sheet(path, COLUMNS, ['lead' if story in lead else 'not' for story in order])


def self_check():
    with tempfile.TemporaryDirectory() as one, tempfile.TemporaryDirectory() as two:
        first, second = pathlib.Path(one), pathlib.Path(two)
        fixture(first)
        fixture(second)
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
