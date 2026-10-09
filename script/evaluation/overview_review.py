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
LINE_FIELDS = {'lines': 'lines', 'malformed': 'malformedLines',
               'deterministicRejections': 'deterministicRejections', 'modelRejections': 'modelRejections'}
DEFAULT_TARGET = 30
# #308 asks for refusal, format and weak-draft causes. A prose answer without protocol lines ("unstructured") is usually
# a refusal written as text, so it counts there; the raw causes stay in `fallbackCauses`.
FALLBACK_GROUPS = {'refusal': ('refusal', 'unstructured'), 'format': ('lineCount',), 'weakDraft': ('weakDraft',),
                   'notAsked': ('noPassages',), 'modelUnavailableOrError': ('unavailable', 'contextWindow', 'error')}
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


def write_new_sheet(path, columns, rows):
    """Creates a private reviewer sheet; never replaces one that may already hold a reviewer's labels."""
    out = io.StringIO()
    writer = csv.DictWriter(out, columns, lineterminator='\n')
    writer.writeheader()
    writer.writerows(rows)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'w') as output:
        output.write(out.getvalue())
    return len(rows)


def label_sheet(path, columns, labels):
    """Self-check helper: fills the sheet's label column in row order, as a reviewer would."""
    with path.open(newline='') as sheet_file:
        rows = list(csv.DictReader(sheet_file))
    for row, label in zip(rows, labels):
        row['label'] = label
    with path.open('w', newline='') as output:
        writer = csv.DictWriter(output, columns, lineterminator='\n')
        writer.writeheader()
        writer.writerows(rows)
    return rows


def sheet(directory):
    directory = private_run(directory)
    rows = [{'claim': f"{index}:{fact['id']}", 'overview': index, 'section': section,
             'publisher': citation.get('sourceName') or '', 'text': fact['text'], 'passage': passage, 'label': '', 'note': ''}
            for index, record in accepted_records(runs(directory)) for section, fact, citation, passage in claims(record)]
    return write_new_sheet(directory / SHEET, COLUMNS, rows)


def read_sheet_labels(path, key_column, allowed, expected):
    """Reviewer labels from a sheet whose rows are exactly `expected`; a sheet from another run is rejected."""
    labels = {}
    with path.open(newline='') as sheet_file:
        for row in csv.DictReader(sheet_file):
            key = row.get(key_column)
            label = (row.get('label') or '').strip().lower()
            require(label in ('',) + tuple(allowed), f'Unknown label {label!r} for {key_column} {key}')
            require(key not in labels, f'Duplicate {key_column} {key}')
            labels[key] = label or None
    require(set(labels) == set(expected), f'{path.name} does not list exactly the {key_column}s of this run; rebuild it')
    return labels


def claim_keys(records):
    return {f"{index}:{fact['id']}" for index, record in accepted_records(records) for _, fact, _, _ in claims(record)}


def accepted_records(records):
    return [(index, record) for index, record in records if cause(record) == 'accepted']


def quantiles(samples):
    return {'p50': percentile(samples, 50), 'p95': percentile(samples, 95)}


def total(counts, names):
    return sum(counts.get(name, 0) for name in names)


def line_counts(records):
    lines = dict.fromkeys(LINE_FIELDS, 0)
    for _, record in records:
        outcome = record.get('outcome') or {}
        for key, field in LINE_FIELDS.items():
            lines[key] += outcome.get(field, 0)
    return lines


def overview_metrics(records):
    """Acceptance, fallback causes, model line counts and latency over every attempted live event."""
    causes = {}
    for _, record in records:
        causes[cause(record)] = causes.get(cause(record), 0) + 1
    durations = [record.get('durationSeconds', 0.0) for _, record in records]
    accepted = [record.get('durationSeconds', 0.0) for _, record in accepted_records(records)]
    overviews = {'attempted': len(records), 'accepted': rate(causes.get('accepted', 0), len(records)),
                 'fallbackCauses': dict(sorted(causes.items())),
                 'fallbackGroups': {group: total(causes, names) for group, names in FALLBACK_GROUPS.items()},
                 'modelFailures': total(causes, FAILURES), 'lineCounts': line_counts(records)}
    return overviews, {'all': quantiles(durations), 'accepted': quantiles(accepted)}


def claim_rows(records, labels):
    """Per retained claim: reviewer label, longest copied run, claim length and, for introductions, best fact Jaccard."""
    for index, record in accepted_records(records):
        facts = [fact['text'] for fact in record['document']['facts']]
        for section, fact, _, passage in claims(record):
            run, length = longest_shared_run(fact['text'], passage)
            similarity = max((jaccard(fact['text'], other) for other in facts), default=0.0) if section == 'introduction' else None
            yield labels.get(f"{index}:{fact['id']}"), run, length, similarity


def label_metrics(rows, audits):
    counts = {label: sum(row[0] == label for row in rows) for label in LABELS}
    retained, labelled = len(rows), sum(counts.values())
    return {'retained': retained, 'labelled': labelled, 'unlabelled': retained - labelled,
            **{label: rate(counts[label], labelled) for label in LABELS},
            'criticalUpperBound95': (wilson(counts['critical'], labelled) or [None, None])[1],
            'auditorHeuristic': {'unsupported': sum(a.get('unsupportedClaims', 0) for a in audits),
                                 'critical': sum(a.get('totalCriticalErrors', 0) for a in audits)}}


def verbatim_metrics(rows):
    copied = [row[1] for row in rows]
    whole = sum(0 < row[2] == row[1] for row in rows)
    return {'medianLongestCopiedRun': percentile(copied, 50),
            'claimsCopyingAtLeast8Words': rate(sum(run >= 8 for run in copied), len(rows)),
            'claimsCopiedWhole': rate(whole, len(rows))}


def repetition_metrics(rows):
    intro = [row[3] for row in rows if row[3] is not None]
    return {'sentences': len(intro), 'repeatingAFact': rate(sum(value >= 0.6 for value in intro), len(intro)),
            'medianBestFactJaccard': percentile(intro, 50), 'threshold': 0.6}


def claim_metrics(records, labels):
    """Labelled claim rates, verbatim overlap and introduction repetition for accepted overviews."""
    rows = list(claim_rows(records, labels))
    audits = [record['audit'] for _, record in accepted_records(records)]
    return label_metrics(rows, audits), verbatim_metrics(rows), repetition_metrics(rows)


def run_json(directory, name):
    path = directory / name
    return json.loads(path.read_text()) if path.exists() else None


def report(directory):
    directory = private_run(directory)
    records = runs(directory)
    sheet_path = directory / SHEET
    labels = read_sheet_labels(sheet_path, 'claim', LABELS, claim_keys(records)) if sheet_path.exists() else {}
    overviews, latency = overview_metrics(records)
    claims_report, verbatim, repetition = claim_metrics(records, labels)
    target = (run_json(directory, 'overviews.json') or {}).get('target', DEFAULT_TARGET)
    result = {
        'overviews': overviews, 'latencySeconds': latency, 'claims': claims_report,
        'verbatim': verbatim, 'introductionRepetition': repetition,
        'decisionInputs': {'labellingComplete': claims_report['retained'] > 0 and claims_report['unlabelled'] == 0,
                           'criticalErrorObserved': claims_report['critical']['count'] > 0,
                           'acceptedTarget': target, 'acceptedTargetMet': overviews['accepted']['count'] >= target},
        'limitations': 'Labels come from the reviewer sheet; the auditor heuristic is not a label. Verbatim runs and '
                       'Jaccard repetition are lexical measures. Latency includes per-sentence verification calls.',
    }
    coverage = run_json(directory, 'perspectives.json')
    if coverage is not None:
        result['perspectiveCoverage'] = {**coverage, 'twoOrMoreRate': rate(coverage.get('twoOrMore', 0), coverage.get('events', 0))}
    (directory / REPORT).write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    return result


def fixture_record(result, seconds, failure=None):
    """A synthetic live record: one passage, two introduction sentences and three facts citing it."""
    passage = {'id': 'pass-1', 'articleID': 'a1', 'text': 'Officials said the bridge reopened on Monday after repairs costing $4m.', 'fingerprint': 'f'}
    citation = {'id': 'c1', 'articleID': 'a1', 'passageID': 'pass-1', 'passageFingerprint': 'f', 'quote': passage['text'], 'sourceName': 'Publisher A'}

    def fact(i, text):
        return {'id': f'model_claim_{i}', 'text': text, 'citationIDs': ['c1']}
    document = {'eventID': f'e-{seconds}', 'citations': {'c1': citation},
                'facts': [fact(2, 'The bridge reopened on Monday after repairs costing $4m.'), fact(3, 'Repairs cost $4m.'), fact(4, 'Officials confirmed it.')],
                'evidenceSections': {'introduction': [fact(0, 'The bridge reopened on Monday.'), fact(1, 'Officials gave the cost.')]}}
    outcome = None if failure else {'result': result, 'lines': 6, 'malformedLines': 1, 'deterministicRejections': 0, 'modelRejections': 0}
    return {'document': document, 'passages': [passage], 'audit': {'unsupportedClaims': 0, 'totalCriticalErrors': 0},
            'durationSeconds': seconds, 'failure': failure, 'outcome': outcome, 'sources': 2}


def expect_rejected(action, error, message):
    try:
        action()
    except error:
        return
    raise AssertionError(message)


def check_measures():
    require(wilson(0, 0) is None, 'Wilson interval needs trials')
    low, high = wilson(0, 30)
    require(math.isclose(low, 0.0, abs_tol=1e-12), 'Wilson lower bound')
    require(math.isclose(high, 0.1135, abs_tol=1e-3), 'Wilson upper bound')
    require(math.isclose(percentile([4.0, 1.0, 3.0, 2.0], 50), 2.5), 'Median interpolates like the Swift tracker')
    require(math.isclose(percentile([1.0, 2.0, 3.0, 4.0], 95), 3.85), 'p95 interpolates like the Swift tracker')
    require(longest_shared_run('The council approved the repairs.', 'Yesterday the council approved the repairs at noon.') == (5, 5), 'Longest copied word run')
    require(math.isclose(jaccard('The bridge reopened on Monday.', 'The bridge reopened Monday after repairs.'), 0.6), 'Content-word Jaccard')


def check_sheet(directory):
    for index, item in enumerate([fixture_record('accepted', 4.0), fixture_record('weakDraft', 6.0), fixture_record(None, 1.0, 'refusal')], 1):
        (directory / f'overview-private-live-{index}.json').write_text(json.dumps(item))
    (directory / 'perspectives.json').write_text(json.dumps({'events': 4, 'twoOrMore': 1, 'one': 1, 'none': 2}))
    require(sheet(directory) == 5, 'Sheet lists the five retained claims of the accepted overview')
    expect_rejected(lambda: sheet(directory), FileExistsError, 'A labelled sheet was replaced')
    with (directory / SHEET).open(newline='') as sheet_file:
        rows = list(csv.DictReader(sheet_file))
    require([row['claim'] for row in rows][:2] == ['1:model_claim_0', '1:model_claim_1'], 'Sheet lists the introduction first')
    require(rows[0]['section'] == 'introduction', 'Introduction rows are marked')
    unlabelled = report(directory)
    require(unlabelled['claims']['unlabelled'] == 5, 'Unlabelled claims are counted')
    require(not unlabelled['decisionInputs']['labellingComplete'], 'Unlabelled claims leave labelling incomplete')
    label_sheet(directory / SHEET, COLUMNS, ['supported', 'supported', 'supported', 'unsupported', 'critical'])


def check_report(directory):
    result = report(directory)
    overviews, claims_report = result['overviews'], result['claims']
    require((overviews['attempted'], overviews['accepted']['count'], overviews['modelFailures']) == (3, 1, 1), 'Attempted, accepted and failed counts')
    require(overviews['fallbackCauses'] == {'accepted': 1, 'refusal': 1, 'weakDraft': 1}, 'Raw fallback causes')
    require(overviews['lineCounts']['malformed'] == 2, 'Malformed lines')
    groups = overviews['fallbackGroups']
    require((groups['refusal'], groups['format'], groups['weakDraft']) == (1, 0, 1), 'Fallback groups')
    latency = result['latencySeconds']
    expected = {'all': {'p50': 4.0, 'p95': 5.8}, 'accepted': {'p50': 4.0, 'p95': 4.0}}
    require(all(math.isclose(latency[group][key], value) for group, values in expected.items() for key, value in values.items()),
            'Latency percentiles')
    require((claims_report['retained'], claims_report['labelled'], claims_report['critical']['count']) == (5, 5, 1), 'Labelled claim counts')
    require(math.isclose(claims_report['criticalUpperBound95'], wilson(1, 5)[1]), 'Critical-error Wilson upper bound')
    verbatim = result['verbatim']
    require((verbatim['claimsCopiedWhole']['count'], verbatim['claimsCopyingAtLeast8Words']['count']) == (2, 1), 'Verbatim copy counts')
    require(result['introductionRepetition']['repeatingAFact']['count'] == 0, 'Introduction repetition')
    decision = result['decisionInputs']
    require(decision['labellingComplete'] and decision['criticalErrorObserved'], 'Decision inputs')
    require(decision['acceptedTarget'] == DEFAULT_TARGET, 'Default target without a run summary')
    require(math.isclose(result['perspectiveCoverage']['twoOrMoreRate']['rate'], 0.25), 'Perspective coverage rate')
    (directory / 'overviews.json').write_text(json.dumps({'target': 1}))
    require(report(directory)['decisionInputs']['acceptedTargetMet'], 'The run summary sets the target')
    public = (directory / REPORT).read_text()
    require('bridge' not in public.lower() and 'Publisher A' not in public, 'Report must not carry publisher or model text')
    (directory / SHEET).write_text('claim,label\n1:model_claim_0,supported\n')
    expect_rejected(lambda: report(directory), ValueError, 'A sheet missing claims was accepted')
    (directory / SHEET).write_text('claim,label\n1:model_claim_0,maybe\n')
    expect_rejected(lambda: report(directory), ValueError, 'Unknown label accepted')


def self_check():
    check_measures()
    with tempfile.TemporaryDirectory() as temporary:
        directory = pathlib.Path(temporary)
        check_sheet(directory)
        check_report(directory)
    print('Overview review self-check passed')


def main(doc, commands, check, noun):
    """`sheet RUN` and `report RUN` subcommands; no arguments runs the self-check."""
    parser = argparse.ArgumentParser(description=doc, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('command', nargs='?', choices=['sheet', 'report'])
    parser.add_argument('run', nargs='?', type=pathlib.Path)
    args = parser.parse_args()
    if args.command is None:
        check()
    elif args.run is None:
        parser.error('a run directory is required')
    elif args.command == 'sheet':
        try:
            print(f"Wrote {commands['sheet'](args.run)} {noun} to the run's review sheet")
        except FileExistsError as error:
            parser.exit(1, f'{error.filename} already exists and may hold labels; it was left unchanged.\n')
    else:
        print(json.dumps(commands['report'](args.run), indent=2, sort_keys=True))


if __name__ == '__main__':
    main(__doc__, {'sheet': sheet, 'report': report}, self_check, 'claims')
