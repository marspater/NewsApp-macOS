#!/usr/bin/env python3
"""Validate the frozen corpus and score pair-ID predictions without reading text."""
import argparse
import collections
import copy
import hashlib
import json
import pathlib

LABELS = {'same_document', 'same_event', 'different'}
DEFAULT = pathlib.Path(__file__).resolve().parents[2] / 'Tests/Fixtures/story-corpus/corpus-v1.json'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate(corpus):
    require(corpus['version'] == 1 and corpus['releaseEligible'] is False, 'Unexpected corpus version or release claim')
    docs = {d['id']: d for d in corpus['documents']}
    events = {e['id']: e for e in corpus['events']}
    require(len(docs) == len(corpus['documents']) and len(events) == len(corpus['events']), 'Duplicate document/event ID')
    groups, pair_ids, edges = {}, set(), set()
    for event in events.values():
        require(event['split'] in {'tuning', 'holdout'}, 'Unknown split')
        require(groups.setdefault(event['group'], event['split']) == event['split'], 'Family leaks across splits')
    for doc in docs.values():
        require(doc['event'] in events, 'Unknown document event')
        require(doc['language'] in {'en', 'uk', 'pl', 'undetermined'}, 'Unknown language')
        require(doc['provenance'].startswith('authored') or not doc.get('body'), 'Public publisher body')
    for pair in corpus['pairs']:
        require(pair['id'] not in pair_ids, 'Duplicate pair ID')
        pair_ids.add(pair['id'])
        edge = tuple(sorted([pair['left'], pair['right']]))
        require(edge not in edges and edge[0] != edge[1], 'Duplicate/self pair')
        edges.add(edge)
        require(pair['label'] in LABELS, 'Unknown label')
        require(all(key in docs for key in edge), 'Unknown pair document')
        left, right = [docs[key] for key in edge]
        require(all(events[d['event']]['split'] == pair['split'] for d in [left, right]), 'Pair crosses splits')
        require((left['event'] == right['event']) == (pair['label'] != 'different'), 'Label contradicts event IDs')
    require(len(corpus['pairs']) == 460, 'Expected frozen 460-pair corpus')
    require(sum(e['provenance'] == 'w2e-author-relevance' for e in events.values()) == 100, 'Expected 100 imported events')
    return docs


def metrics(pairs, predictions):
    covered = [p for p in pairs if predictions[p['id']] is not None]
    result = {'pairs': len(pairs), 'evaluated': len(covered), 'abstained': len(pairs) - len(covered),
              'accuracyEvaluated': sum(predictions[p['id']] == p['label'] for p in covered) / len(covered) if covered else None,
              'labels': {}}
    for label in sorted(LABELS):
        tp = sum(p['label'] == label and predictions[p['id']] == label for p in covered)
        fp = sum(p['label'] != label and predictions[p['id']] == label for p in covered)
        fn = sum(p['label'] == label and predictions[p['id']] != label for p in covered)
        actual = sum(p['label'] == label for p in pairs)
        result['labels'][label] = {'truePositive': tp, 'falsePositive': fp, 'falseNegativeEvaluated': fn,
                                  'actual': actual, 'precision': tp / (tp + fp) if tp + fp else None,
                                  'recallEvaluated': tp / (tp + fn) if tp + fn else None,
                                  'recallAll': tp / actual if actual else None}
    return result


def report(corpus, prediction, split):
    docs = validate(corpus)
    pairs = [p for p in corpus['pairs'] if p['split'] == split]
    task = prediction['task']
    require(task in {'three_way', 'document_identity'}, 'Unknown evaluation task')
    if task == 'document_identity':
        pairs = [dict(p, label='different' if p['label'] == 'same_event' else p['label']) for p in pairs]
    predictions = prediction['predictions']
    require(set(predictions) == {p['id'] for p in pairs}, 'Predictions must cover exactly the requested split (null for abstentions)')
    allowed = LABELS if task == 'three_way' else {'same_document', 'different'}
    require(all(value is None or value in allowed for value in predictions.values()), 'Unknown predicted label')
    result = {'algorithm': prediction['algorithm'], 'task': task, 'split': split, 'releaseGatePassed': False,
              'limitations': ['Imported topic labels still need independent event/document review.',
                              'Publisher text and verified languages are absent from public URL records.',
                              'Authored controls cannot establish real-publisher fingerprint precision.'],
              'overall': metrics(pairs, predictions)}
    for field in ['language', 'source', 'provenance']:
        buckets = collections.defaultdict(list)
        for pair in pairs:
            key = pair['provenance'] if field == 'provenance' else '+'.join(sorted({docs[pair['left']][field], docs[pair['right']][field]}))
            buckets[key].append(pair)
        result['by' + field.title()] = {key: metrics(value, predictions) for key, value in sorted(buckets.items())}
    result['errors'] = [p['id'] for p in pairs if predictions[p['id']] is not None and predictions[p['id']] != p['label']]
    return result


def self_check(corpus):
    validate(corpus)
    mutations = [lambda c: c['events'][0].update(split='holdout'),
                 lambda c: c['pairs'][0].update(label='invalid'),
                 lambda c: c['pairs'].append(c['pairs'][0]),
                 lambda c: c['documents'][0].update(body='Publisher text must stay private')]
    for mutation in mutations:
        bad = copy.deepcopy(corpus)
        mutation(bad)
        try:
            validate(bad)
        except ValueError:
            continue
        raise AssertionError('Invalid corpus accepted')
    pairs = [{'id': 'a', 'label': 'same_document'}, {'id': 'b', 'label': 'different'}, {'id': 'c', 'label': 'same_document'}]
    sample = metrics(pairs, {'a': 'same_document', 'b': 'same_document', 'c': None})
    assert sample['labels']['same_document']['precision'] == 0.5
    assert sample['labels']['same_document']['recallAll'] == 0.5
    assert sample['abstained'] == 1
    tuning = [p for p in corpus['pairs'] if p['split'] == 'tuning']
    prediction = {'algorithm': 'self-check', 'task': 'three_way',
                  'predictions': {p['id']: p['label'] for p in tuning}}
    result = report(corpus, prediction, 'tuning')
    assert result['overall']['accuracyEvaluated'] == 1 and not result['releaseGatePassed']
    prediction['task'] = 'document_identity'
    prediction['predictions'] = {p['id']: 'different' if p['label'] == 'same_event' else p['label'] for p in tuning}
    assert report(corpus, prediction, 'tuning')['overall']['accuracyEvaluated'] == 1
    prediction['predictions'].pop(tuning[0]['id'])
    try:
        report(corpus, prediction, 'tuning')
    except ValueError:
        return
    raise AssertionError('Missing prediction accepted')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--corpus', type=pathlib.Path, default=DEFAULT)
    parser.add_argument('--predictions', type=pathlib.Path)
    parser.add_argument('--holdout', action='store_true', help='Explicitly unseal evaluation holdout; never tune against its results')
    args = parser.parse_args()
    raw = args.corpus.read_bytes()
    corpus = json.loads(raw)
    expected = args.corpus.with_suffix('.sha256').read_text().split()[0]
    require(hashlib.sha256(raw).hexdigest() == expected, 'Corpus changed: version the corpus instead of replacing its holdout')
    self_check(corpus)
    if args.predictions:
        print(json.dumps(report(corpus, json.loads(args.predictions.read_text()), 'holdout' if args.holdout else 'tuning'), indent=2))
    else:
        print('Validated 460 pairs, 100 imported events, 30 multilingual control families; no holdout predictions run.')
