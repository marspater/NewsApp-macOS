#!/usr/bin/env python3
"""Validate the provisional source labels and prepare private reviewer evidence."""
import argparse
import csv
import hashlib
import io
import json
import math
import os
import pathlib
import tempfile
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).resolve().parents[2]
DEFAULT = ROOT / 'Tests/Fixtures/story-corpus/publisher-review-v2.json'
LABELS = {'same_document', 'same_event', 'different'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate(manifest):
    require(manifest['version'] == 2 and manifest['releaseEligible'] is False, 'Proposals cannot claim a release gate')
    documents = {d['id']: d for d in manifest['documents']}
    events = {e['id']: e for e in manifest['events']}
    require(len(documents) == len(manifest['documents']) and len(events) == len(manifest['events']), 'Duplicate IDs')
    families, urls, edges, identifiers = {}, {}, set(), set()
    for event in events.values():
        expected = 'holdout' if int(hashlib.sha256(('news-review-v2:' + event['family']).encode()).hexdigest()[:8], 16) % 10 >= 7 else 'tune'
        require(event['split'] == expected, 'Family split changed')
        require(families.setdefault(event['family'], expected) == expected, 'Family crosses splits')
        require(event['reviewStatus'] == 'pending', 'Keep approvals in a separate reviewer file')
    for document in documents.values():
        require(document['event'] in events, 'Unknown event')
        require(not any(k in document for k in ('body', 'content', 'description', 'title')), 'Publisher text must stay private')
        split = events[document['event']]['split']
        require(urls.setdefault(document['url'], split) == split, 'Observed URL crosses splits')
    for pair in manifest['pairs']:
        require(pair['id'] not in identifiers, 'Duplicate pair ID')
        identifiers.add(pair['id'])
        edge = tuple(sorted((pair['left'], pair['right'])))
        require(edge not in edges and edge[0] != edge[1], 'Duplicate or self pair')
        edges.add(edge)
        require(all(d in documents for d in edge), 'Unknown pair document')
        left, right = (documents[d] for d in edge)
        require(all(events[d['event']]['split'] == pair['split'] for d in (left, right)), 'Pair crosses splits')
        expected = 'same_document' if left['url'] == right['url'] else 'same_event' if left['event'] == right['event'] else 'different'
        require(pair['proposedLabel'] in LABELS and pair['proposedLabel'] == expected, 'Label contradicts proposed occurrences')
        require(pair['reviewStatus'] == 'pending', 'Proposed labels are not adjudications')
    return documents, events


def private_directory(path):
    directory = path.resolve(strict=True)
    status = directory.stat()
    require(directory.is_dir() and status.st_uid == os.getuid() and status.st_mode & 0o077 == 0, 'Use an existing private directory owned by you (0700)')
    require(not any((parent / '.git').exists() for parent in (directory, *directory.parents)), 'Keep publisher text outside Git checkouts')
    return directory


def write_private(path, text):
    require('..' not in path.parts, 'Output path cannot traverse parent directories')
    directory = private_directory(path.parent)
    # Anchor creation to the checked directory; never follow a replacement symlink.
    directory_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        status = os.fstat(directory_fd)
        require(status.st_uid == os.getuid() and status.st_mode & 0o077 == 0, 'Output directory permissions changed')
        descriptor = os.open(os.path.basename(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory_fd)
    finally:
        os.close(directory_fd)
    with os.fdopen(descriptor, 'w') as output:
        output.write(text)


def prepare(manifest, capture_path, output, labels_path=None):
    documents, events = validate(manifest)
    raw = capture_path.read_bytes()
    require(hashlib.sha256(raw).hexdigest() == manifest['captureSHA256'], 'Capture checksum mismatch')
    capture = json.loads(raw)
    require(capture['version'] == 1, 'Unsupported capture')
    items = {}
    for document in documents.values():
        item = capture['items'][document['captureIndex']]
        require(item['link'] == document['url'], 'Captured URL mismatch')
        require(all(item.get(k) == document[k] for k in ('feed', 'source', 'language', 'published')), 'Captured metadata mismatch')
        items[document['id']] = item
    directory = private_directory(output)
    if labels_path:
        review = json.loads(labels_path.read_text())
        require(bool(review.get('reviewer')) and bool(review.get('reviewedAt')), 'Record the independent reviewer and review date')
        decisions = review['labels']
        require(set(decisions) == {p['id'] for p in manifest['pairs']}, 'Every proposed pair needs an independent decision')
        require(all(decisions[p['id']] == p['proposedLabel'] for p in manifest['pairs']), 'A corrected label needs a new manifest version and revised event assignments')
        require(set(review.get('verifiedTimestampIDs', [])) == set(documents), 'Verify all publisher timestamps before replay')
        # The native clusterer scores all pairs, including links outside the review sample.
        require(review.get('allEventAssignmentsReviewed') is True, 'Review every event assignment, including singleton boundaries')
        require(all(type(d.get('published')) in (int, float) and math.isfinite(d['published']) for d in documents.values()), 'Undated captured inputs require a reviewed exclusion before replay; never invent timestamps')
        articles = [dict(id=d['id'], url=d['url'], title=items[d['id']]['title'], description=items[d['id']]['description'], source=d['source'],
                         published=datetime.fromtimestamp(d['published'], timezone.utc).isoformat().replace('+00:00', 'Z'),
                         event=d['event'], split=events[d['event']]['split']) for d in documents.values()]
        write_private(directory / 'reviewed-event-corpus.json', json.dumps({'articles': articles, 'review': review}, ensure_ascii=False, indent=2) + '\n')
        print('Exported independently reviewed event inputs; no predictions were run.')
        return
    lines = ['# Private publisher review v2', '', 'Provisional labels only. No matcher or embedding predictions have been viewed.',
             'Verify publisher dates and occurrence boundaries, including singletons. Feed timestamps are not independent date evidence.',
             'Review tune first. Keep holdout labels separate from threshold selection. Do not use proposals as acceptance evidence.', '']
    for event in manifest['events']:
        lines += [f"## {event['id']} ({event['split']}; family {event['family']})", '', event['reason'], '']
        for document in documents.values():
            if document['event'] != event['id']:
                continue
            item = items[document['id']]
            lines += [f"### {document['id']}: {item['title']}", '', f"Source: {document['source']} / {document['language']}",
                      f"URL: {document['url']}", f"Feed timestamp: {datetime.fromtimestamp(document['published'], timezone.utc).isoformat() if document.get('published') is not None else 'Unknown (feed supplied no date)'}", '',
                      item['description'], '']
    table = io.StringIO()
    writer = csv.writer(table)
    writer.writerow(['pair', 'split', 'left', 'right', 'proposed_label', 'accepted_label', 'reason'])
    for pair in manifest['pairs']:
        writer.writerow([pair[k] for k in ('id', 'split', 'left', 'right', 'proposedLabel')] + ['', pair['reason']])
    write_private(directory / 'review.md', '\n'.join(lines))
    write_private(directory / 'pairs.csv', table.getvalue())
    print(f"Prepared private evidence for {len(documents)} observations, {len(events)} proposed events and {len(manifest['pairs'])} pairs; approvals remain blank.")


def self_check(manifest):
    import copy
    validate(manifest)
    for mutate in (lambda m: m.update(releaseEligible=True),
                   lambda m: m['pairs'][0].update(proposedLabel='invalid'),
                   lambda m: m['events'][0].update(split='invalid'),
                   lambda m: m['documents'][0].update(body='private text'),
                   lambda m: m['pairs'].append(m['pairs'][0])):
        invalid = copy.deepcopy(manifest)
        mutate(invalid)
        try:
            validate(invalid)
        except ValueError:
            continue
        raise AssertionError('Invalid proposal accepted')
    with tempfile.TemporaryDirectory(prefix='news-label-check-') as path:
        directory = pathlib.Path(path)
        private_directory(directory)
        file = directory / 'check.txt'
        write_private(file, 'original')
        try:
            write_private(file, 'replacement')
        except FileExistsError:
            pass
        else:
            raise AssertionError('Existing reviewer data overwritten')
        assert file.read_text() == 'original' and file.stat().st_mode & 0o077 == 0
        public = directory / 'public'
        public.mkdir(mode=0o755)
        checkout = directory / 'checkout'
        checkout.mkdir(mode=0o700)
        (checkout / '.git').mkdir()
        for unsafe in (public / 'evidence.json', checkout / 'evidence.json', public / '..' / 'escape.json'):
            try:
                write_private(unsafe, 'private evidence')
            except ValueError:
                pass
            else:
                raise AssertionError('Unsafe evidence destination accepted')
            assert not unsafe.exists()
        link = directory / 'existing-link.json'
        link.symlink_to(file)
        try:
            write_private(link, 'replacement')
        except FileExistsError:
            pass
        else:
            raise AssertionError('Existing symlink followed')
        assert link.is_symlink() and file.read_text() == 'original'

    # A label file cannot turn an undated captured input into a replay timestamp.
    with tempfile.TemporaryDirectory(prefix='news-undated-check-') as path:
        directory = pathlib.Path(path)
        event = dict(manifest['events'][0])
        items = [dict(link='https://example.test/' + name, feed='https://example.test/feed', source='Control', language='en', published=date, title='Synthetic control', description='Synthetic control') for name, date in (('a', None), ('b', 1))]
        raw = json.dumps(dict(version=1, items=items))
        capture = directory / 'capture.json'
        write_private(capture, raw)
        documents = [dict(id=name, captureIndex=i, event=event['id'], url=item['link'], **{k: item[k] for k in ('feed', 'source', 'language', 'published')}) for i, (name, item) in enumerate(zip(('a', 'b'), items))]
        proposal = dict(version=2, releaseEligible=False, captureSHA256=hashlib.sha256(raw.encode()).hexdigest(), events=[event], documents=documents, pairs=[dict(id='control', left='a', right='b', split=event['split'], proposedLabel='same_event', reviewStatus='pending', reason='Synthetic control')])
        labels = directory / 'labels.json'
        write_private(labels, json.dumps(dict(reviewer='Synthetic self-check', reviewedAt='2026-10-04', labels={'control': 'same_event'}, verifiedTimestampIDs=['a', 'b'], allEventAssignmentsReviewed=True)))
        packet = directory / 'packet'
        packet.mkdir(mode=0o700)
        from contextlib import redirect_stdout
        with redirect_stdout(io.StringIO()):
            prepare(proposal, capture, packet)
        assert 'Unknown (feed supplied no date)' in (packet / 'review.md').read_text()
        try:
            prepare(proposal, capture, packet, labels)
        except ValueError as error:
            assert 'Undated captured inputs' in str(error)
        else:
            raise AssertionError('Undated evidence exported')
        assert not (packet / 'reviewed-event-corpus.json').exists()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=pathlib.Path, default=DEFAULT)
    parser.add_argument('--capture', type=pathlib.Path)
    parser.add_argument('--output', type=pathlib.Path)
    parser.add_argument('--labels', type=pathlib.Path)
    args = parser.parse_args()
    raw = args.manifest.read_bytes()
    require(hashlib.sha256(raw).hexdigest() == args.manifest.with_suffix('.sha256').read_text().split()[0], 'Frozen proposal changed; version corrections')
    manifest = json.loads(raw)
    self_check(manifest)
    require(bool(args.capture) == bool(args.output), 'Supply both --capture and --output')
    require(not args.labels or args.capture, 'Labels require captured evidence')
    if args.capture:
        prepare(manifest, args.capture, args.output, args.labels)
    else:
        print('Provisional publisher labels and validation self-checks passed; no holdout predictions run.')
