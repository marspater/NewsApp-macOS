#!/usr/bin/env python3
"""Prepare the #308 claim-review sheet from a private `--overviews-live` run and report aggregates only.

`sheet RUN` writes RUN/claims-review-private.csv: one row per retained model claim of each accepted live overview,
with its cited passage. An independent reviewer fills `label` with supported, unsupported or critical.
`report RUN` writes RUN/overview-evaluation.json with counts, rates, Wilson 95% bounds, latency, fallback causes,
verbatim overlap, introduction/fact repetition and the #313 perspective coverage. It contains no publisher or model
text. With no arguments, the script checks itself on a synthetic run.
"""
import argparse
import csv
import io
import json
import math
import os
import pathlib
import re
import tempfile

LABELS = ('supported', 'unsupported', 'critical')
SHEET = 'claims-review-private.csv'
REPORT = 'overview-evaluation.json'
COLUMNS = ['claim', 'overview', 'section', 'publisher', 'text', 'passage', 'label', 'note']
FAILURES = ('unavailable', 'refusal', 'contextWindow', 'error')
STOPWORDS = set('a an and are as at be by for from has have in is it its of on or that the their to was were will with'.split())


def require(condition, message):
    if not condition:
        raise ValueError(message)


def wilson(successes, trials, z=1.96):
    """Wilson score interval, matching StoryCorpus.wilson."""
    if trials == 0:
        return None
    p = successes / trials
    denominator = 1 + z * z / trials
    centre = (p + z * z / (2 * trials)) / denominator
    margin = z * math.sqrt(p * (1 - p) / trials + z * z / (4 * trials * trials)) / denominator
    return [max(0.0, centre - margin), min(1.0, centre + margin)]


def rate(successes, trials):
    return {'count': successes, 'of': trials, 'rate': successes / trials if trials else None, 'wilson95': wilson(successes, trials)}


def percentile(samples, percent):
    """Linear interpolation, matching OverviewTimingTracker.calculatePercentile."""
    if not samples:
        return None
    ordered = sorted(samples)
    index = (len(ordered) - 1) * percent / 100
    lower, upper = math.floor(index), math.ceil(index)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (index - lower)


def words(text):
    return re.findall(r"[a-z0-9]+(?:['’][a-z]+)?", text.lower())


def longest_shared_run(claim, passage):
    """Longest run of consecutive words the claim copies from its passage."""
    a, b = words(claim), words(passage)
    best, previous = 0, [0] * (len(b) + 1)
    for left in a:
        current = [0] * (len(b) + 1)
        for j, right in enumerate(b, 1):
            if left == right:
                current[j] = previous[j - 1] + 1
                best = max(best, current[j])
        previous = current
    return best, len(a)


def jaccard(left, right):
    a = {w for w in words(left) if w not in STOPWORDS}
    b = {w for w in words(right) if w not in STOPWORDS}
    return len(a & b) / len(a | b) if a | b else 0.0


def private_run(path):
    directory = path.resolve(strict=True)
    require(directory.is_dir() and directory.stat().st_uid == os.getuid(), 'Use an existing run directory owned by you')
    require(not any((parent / '.git').exists() for parent in (directory, *directory.parents)), 'Keep publisher text outside Git checkouts')
    return directory


def runs(directory):
    """Live overview records in measurement order."""
    files = sorted(directory.glob('overview-private-live-*.json'), key=lambda f: int(f.stem.rsplit('-', 1)[1]))
    require(files, 'No overview-private-live-*.json files in the run directory')
    return [(f.stem.rsplit('-', 1)[1], json.loads(f.read_text())) for f in files]


def cause(record):
    if record.get('failure'):
        return record['failure']
    return (record.get('outcome') or {}).get('result', 'unknown')


def claims(record):
    """Retained model claims of an accepted overview, introduction first."""
    document = record['document']
    sections = document.get('evidenceSections') or {}
    passages = {p['id']: p for p in record['passages']}
    citations = document['citations']
    for section, facts in (('introduction', sections.get('introduction') or []), ('fact', document['facts'])):
        for fact in facts:
            citation = citations[fact['citationIDs'][0]]
            passage = passages.get(citation['passageID'], {}).get('text', citation['quote'])
            yield section, fact, citation, passage


def sheet(directory):
    directory = private_run(directory)
    out = io.StringIO()
    writer = csv.DictWriter(out, COLUMNS, lineterminator='\n')
    writer.writeheader()
    rows = 0
    for index, record in runs(directory):
        if cause(record) != 'accepted':
            continue
        for section, fact, citation, passage in claims(record):
            writer.writerow({'claim': f"{index}:{fact['id']}", 'overview': index, 'section': section,
                             'publisher': citation.get('sourceName') or '', 'text': fact['text'], 'passage': passage,
                             'label': '', 'note': ''})
            rows += 1
    # Never replace a sheet that may already hold a reviewer's labels.
    descriptor = os.open(directory / SHEET, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'w') as output:
        output.write(out.getvalue())
    return rows


def read_labels(path):
    labels = {}
    with path.open(newline='') as sheet_file:
        for row in csv.DictReader(sheet_file):
            label = (row.get('label') or '').strip().lower()
            require(label in ('',) + LABELS, f"Unknown label {label!r} for claim {row['claim']}")
            require(row['claim'] not in labels, f"Duplicate claim {row['claim']}")
            labels[row['claim']] = label or None
    return labels


def report(directory):
    directory = private_run(directory)
    records = runs(directory)
    sheet_path = directory / SHEET
    labels = read_labels(sheet_path) if sheet_path.exists() else {}
    causes, durations, accepted_durations = {}, [], []
    lines = {'lines': 0, 'malformed': 0, 'deterministicRejections': 0, 'modelRejections': 0}
    counts = {label: 0 for label in LABELS}
    retained = unlabelled = full_copies = long_copies = 0
    runs_copied, intro_sentences, repeated_intro, intro_similarity = [], 0, 0, []
    auditor = {'unsupported': 0, 'critical': 0}
    for index, record in records:
        kind = cause(record)
        causes[kind] = causes.get(kind, 0) + 1
        durations.append(record.get('durationSeconds', 0.0))
        for key, field in (('lines', 'lines'), ('malformed', 'malformedLines'),
                           ('deterministicRejections', 'deterministicRejections'), ('modelRejections', 'modelRejections')):
            lines[key] += (record.get('outcome') or {}).get(field, 0)
        if kind != 'accepted':
            continue
        accepted_durations.append(record.get('durationSeconds', 0.0))
        auditor['unsupported'] += record['audit'].get('unsupportedClaims', 0)
        auditor['critical'] += record['audit'].get('totalCriticalErrors', 0)
        facts = [fact['text'] for fact in record['document']['facts']]
        for section, fact, _, passage in claims(record):
            retained += 1
            label = labels.get(f"{index}:{fact['id']}")
            if label:
                counts[label] += 1
            else:
                unlabelled += 1
            run, length = longest_shared_run(fact['text'], passage)
            runs_copied.append(run)
            long_copies += run >= 8
            full_copies += length > 0 and run == length
            if section == 'introduction':
                intro_sentences += 1
                best = max((jaccard(fact['text'], other) for other in facts), default=0.0)
                intro_similarity.append(best)
                repeated_intro += best >= 0.6
    attempted, labelled = len(records), sum(counts.values())
    result = {
        'overviews': {'attempted': attempted, 'accepted': rate(causes.get('accepted', 0), attempted),
                      'fallbackCauses': dict(sorted(causes.items())),
                      'modelFailures': sum(causes.get(name, 0) for name in FAILURES), 'lineCounts': lines},
        'latencySeconds': {'all': {'p50': percentile(durations, 50), 'p95': percentile(durations, 95)},
                           'accepted': {'p50': percentile(accepted_durations, 50), 'p95': percentile(accepted_durations, 95)}},
        'claims': {'retained': retained, 'labelled': labelled, 'unlabelled': unlabelled,
                   'supported': rate(counts['supported'], labelled), 'unsupported': rate(counts['unsupported'], labelled),
                   'critical': rate(counts['critical'], labelled),
                   'criticalUpperBound95': (wilson(counts['critical'], labelled) or [None, None])[1],
                   'auditorHeuristic': auditor},
        'verbatim': {'medianLongestCopiedRun': percentile(runs_copied, 50),
                     'claimsCopyingAtLeast8Words': rate(long_copies, retained),
                     'claimsCopiedWhole': rate(full_copies, retained)},
        'introductionRepetition': {'sentences': intro_sentences, 'repeatingAFact': rate(repeated_intro, intro_sentences),
                                   'medianBestFactJaccard': percentile(intro_similarity, 50), 'threshold': 0.6},
        'decisionInputs': {'labellingComplete': retained > 0 and unlabelled == 0,
                           'criticalErrorObserved': counts['critical'] > 0,
                           'acceptedTarget': 30, 'acceptedTargetMet': causes.get('accepted', 0) >= 30},
        'limitations': 'Labels come from the reviewer sheet; the auditor heuristic is not a label. Verbatim runs and '
                       'Jaccard repetition are lexical measures. Latency includes per-sentence verification calls.',
    }
    perspectives = directory / 'perspectives.json'
    if perspectives.exists():
        coverage = json.loads(perspectives.read_text())
        result['perspectiveCoverage'] = {**coverage, 'twoOrMoreRate': rate(coverage.get('twoOrMore', 0), coverage.get('events', 0))}
    text = json.dumps(result, indent=2, sort_keys=True)
    (directory / REPORT).write_text(text + '\n')
    return result


def self_check():
    assert wilson(0, 0) is None
    low, high = wilson(0, 30)
    assert low == 0.0 and abs(high - 0.1135) < 1e-3, high
    assert percentile([4.0, 1.0, 3.0, 2.0], 50) == 2.5 and abs(percentile([1.0, 2.0, 3.0, 4.0], 95) - 3.85) < 1e-9
    assert longest_shared_run('The council approved the repairs.', 'Yesterday the council approved the repairs at noon.') == (5, 5)
    assert jaccard('The bridge reopened on Monday.', 'The bridge reopened Monday after repairs.') == 0.6

    def record(result, seconds, failure=None):
        passage = {'id': 'pass-1', 'articleID': 'a1', 'text': 'Officials said the bridge reopened on Monday after repairs costing $4m.', 'fingerprint': 'f'}
        citation = {'id': 'c1', 'articleID': 'a1', 'passageID': 'pass-1', 'passageFingerprint': 'f', 'quote': passage['text'], 'sourceName': 'Publisher A'}
        fact = lambda i, text: {'id': f'model_claim_{i}', 'text': text, 'citationIDs': ['c1']}
        document = {'eventID': f'e-{seconds}', 'citations': {'c1': citation},
                    'facts': [fact(2, 'The bridge reopened on Monday after repairs costing $4m.'), fact(3, 'Repairs cost $4m.'), fact(4, 'Officials confirmed it.')],
                    'evidenceSections': {'introduction': [fact(0, 'The bridge reopened on Monday.'), fact(1, 'Officials gave the cost.')]}}
        outcome = None if failure else {'result': result, 'lines': 6, 'malformedLines': 1, 'deterministicRejections': 0, 'modelRejections': 0}
        return {'document': document, 'passages': [passage], 'audit': {'unsupportedClaims': 0, 'totalCriticalErrors': 0},
                'durationSeconds': seconds, 'failure': failure, 'outcome': outcome, 'sources': 2}

    with tempfile.TemporaryDirectory() as temporary:
        directory = pathlib.Path(temporary)
        for index, item in enumerate([record('accepted', 4.0), record('weakDraft', 6.0), record(None, 1.0, 'refusal')], 1):
            (directory / f'overview-private-live-{index}.json').write_text(json.dumps(item))
        (directory / 'perspectives.json').write_text(json.dumps({'events': 4, 'twoOrMore': 1, 'one': 1, 'none': 2}))
        assert sheet(directory) == 5
        try:
            sheet(directory)
            raise AssertionError('A labelled sheet was replaced')
        except FileExistsError:
            pass
        rows = list(csv.DictReader((directory / SHEET).open()))
        assert [row['claim'] for row in rows][:2] == ['1:model_claim_0', '1:model_claim_1'] and rows[0]['section'] == 'introduction'
        unlabelled = report(directory)
        assert unlabelled['claims']['unlabelled'] == 5 and not unlabelled['decisionInputs']['labellingComplete']
        for row, label in zip(rows, ['supported', 'supported', 'supported', 'unsupported', 'critical']):
            row['label'] = label
        with (directory / SHEET).open('w', newline='') as output:
            writer = csv.DictWriter(output, COLUMNS, lineterminator='\n')
            writer.writeheader()
            writer.writerows(rows)
        result = report(directory)
        assert result['overviews']['attempted'] == 3 and result['overviews']['accepted']['count'] == 1
        assert result['overviews']['fallbackCauses'] == {'accepted': 1, 'refusal': 1, 'weakDraft': 1}
        assert result['overviews']['modelFailures'] == 1 and result['overviews']['lineCounts']['malformed'] == 2
        assert result['latencySeconds']['all']['p50'] == 4.0 and result['latencySeconds']['accepted']['p95'] == 4.0
        claims_report = result['claims']
        assert (claims_report['retained'], claims_report['labelled'], claims_report['critical']['count']) == (5, 5, 1)
        assert abs(claims_report['criticalUpperBound95'] - wilson(1, 5)[1]) < 1e-12
        assert result['verbatim']['claimsCopiedWhole']['count'] == 2 and result['verbatim']['claimsCopyingAtLeast8Words']['count'] == 1
        assert result['introductionRepetition']['repeatingAFact']['count'] == 0
        assert result['decisionInputs']['labellingComplete'] and result['decisionInputs']['criticalErrorObserved']
        assert result['perspectiveCoverage']['twoOrMoreRate']['rate'] == 0.25
        public = (directory / REPORT).read_text()
        assert 'bridge' not in public.lower() and 'Publisher A' not in public, 'Report must not carry publisher or model text'
        (directory / SHEET).write_text('claim,label\n1:model_claim_0,maybe\n')
        try:
            report(directory)
            raise AssertionError('Unknown label accepted')
        except ValueError:
            pass
    print('Overview review self-check passed')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('command', nargs='?', choices=['sheet', 'report'])
    parser.add_argument('run', nargs='?', type=pathlib.Path)
    args = parser.parse_args()
    if args.command is None:
        self_check()
    elif args.run is None:
        parser.error('a run directory is required')
    elif args.command == 'sheet':
        print(f'Wrote {sheet(args.run)} claims to {args.run / SHEET}')
    else:
        print(json.dumps(report(args.run), indent=2, sort_keys=True))
