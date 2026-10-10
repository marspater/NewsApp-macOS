#!/usr/bin/env python3
"""Extract publisher date evidence offline; never substitute modified dates or approve labels."""
import argparse
import hashlib
import json
import tempfile
from collections import Counter
from datetime import datetime, timezone
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urljoin, urlsplit, urlunsplit, parse_qsl, urlencode

from publisher_review import require, write_private, validate as validate_review


def document_key(url):
    try:
        p = urlsplit(url)
    except ValueError:
        return None
    tracking = {'at_medium', 'at_campaign', 'fbclid', 'gclid'}
    query = [(k, v) for k, v in parse_qsl(p.query, keep_blank_values=True) if not k.lower().startswith('utm_') and k.lower() not in tracking]
    return urlunsplit((p.scheme.lower(), p.netloc.lower(), p.path, urlencode(query), ''))


def instant(raw):
    try:
        date = datetime.fromisoformat(raw.replace('Z', '+00:00'))
        return date.timestamp() if date.tzinfo else None
    except (ValueError, TypeError, AttributeError):
        return None


TYPE_KEY = '@type'


class Page(HTMLParser):
    def __init__(self, text, url):
        super().__init__(convert_charrefs=True)
        self.url, self.dates, self.links, self.scripts = url, [], [], []
        self.script = None
        self.cms = []
        self.feed(text)
        self.close()
        self._extract_jsonld()

    def _canonical_identities(self):
        return {document_key(self.url)} | {
            document_key(link['url'])
            for link in self.links
            if link['rel'] == 'canonical'
            and document_key(link['url']) is not None
            and urlsplit(link['url']).netloc == urlsplit(self.url).netloc
        }

    def _jsonld_nodes(self, script):
        try:
            data = json.loads(script)
        except ValueError:
            return []
        if isinstance(data, list):
            nodes = data
        elif isinstance(data, dict):
            nodes = data.get('@graph', [data])
        else:
            nodes = []
        return nodes if isinstance(nodes, list) else []

    def _extract_jsonld_node(self, node, identities):
        if not isinstance(node, dict):
            return
        types = node.get(TYPE_KEY, [])
        types = [types] if isinstance(types, str) else types
        if not isinstance(types, list):
            return
        if not any(t in ('Article', 'NewsArticle', 'ReportageNewsArticle', 'BlogPosting', 'WebPage', 'VideoObject') for t in types):
            return
        identity = node.get('url') or node.get('@id') or node.get('mainEntityOfPage')
        if isinstance(identity, dict):
            identity = identity.get('@id') or identity.get('url')
        if not isinstance(identity, str) or len(identity) > 8192:
            return
        try:
            key = document_key(urljoin(self.url, identity))
        except ValueError:
            return
        if key is None or key not in identities:
            return
        for field in ('datePublished', 'dateModified'):
            self.add(field, node.get(field), 'jsonld:' + field)

    def _extract_jsonld(self):
        identities = self._canonical_identities()
        for script in self.scripts:
            for node in self._jsonld_nodes(script):
                self._extract_jsonld_node(node, identities)

    def add(self, kind, value, field):
        if isinstance(value, str) and len(value) <= 128:
            self.dates.append({'kind': kind, 'field': field, 'raw': value, 'epoch': instant(value)})

    def _parse_africanews_cms(self, attributes):
        if urlsplit(self.url).hostname not in ('africanews.com', 'www.africanews.com'):
            return
        raw = attributes.get('data-content') or ''
        try:
            data = json.loads(raw) if len(raw) <= 1_000_000 else None
        except ValueError:
            data = None
        if isinstance(data, dict) and isinstance(data.get('canonical'), str) and document_key(data['canonical']) == document_key(self.url):
            for field in ('createdAt', 'publishedAt', 'firstPublishedAt', 'lastPublishedAt', 'updatedAt'):
                value = data.get(field)
                if isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= 4_102_444_800:
                    self.cms.append({'field': 'cms:' + field, 'epoch': value})

    def handle_starttag(self, tag, attributes):
        a = dict(attributes)
        if tag == 'div' and a.get('id') == 'jsMainMediaArticle':
            self._parse_africanews_cms(a)
        if tag == 'meta':
            key = (a.get('property') or a.get('name') or a.get('itemprop') or '').lower()
            if key in ('article:published_time', 'og:article:published_time', 'datepublished'):
                self.add('datePublished', a.get('content'), 'meta:' + key)
            if key in ('article:modified_time', 'og:article:modified_time', 'datemodified'):
                self.add('dateModified', a.get('content'), 'meta:' + key)
        if tag == 'link' and a.get('href'):
            for rel in (a.get('rel') or '').lower().split():
                if rel in ('canonical', 'amphtml', 'shortlink', 'alternate'):
                    if len(a['href']) > 8192:
                        continue
                    try:
                        resolved = urljoin(self.url, a['href'])
                    except ValueError:
                        continue
                    self.links.append({'rel': rel, 'url': resolved, 'type': a.get('type', ''), 'language': a.get('hreflang', '')})
        if tag == 'script' and a.get('type', '').lower() == 'application/ld+json':
            self.script = []

    def handle_data(self, text):
        if self.script is not None:
            self.script.append(text)

    def handle_endtag(self, tag):
        if tag == 'script' and self.script is not None:
            self.scripts.append(''.join(self.script))
            self.script = None


def verify(document, record, directory):
    result = {'id': document['id'], 'url': document['url'], 'feedPublished': document.get('published'), 'status': 'fetch-failed'}
    if not record.get('file'):
        return result
    file = Path(record['file'])
    require(file.name == str(file) and file.suffix == '.html', 'Invalid private page path')
    raw = (directory / file).read_bytes()
    require(hashlib.sha256(raw).hexdigest() == record['sha256'], 'Publisher response checksum mismatch')
    page = Page(raw.decode('utf-8', errors='replace'), record['finalURL'])
    result.update(pageSHA256=record['sha256'], fetchedAt=record['fetchedAt'], finalURL=record['finalURL'], dateEvidence=page.dates, observedLinks=page.links)
    if page.cms:
        result['publisherCMS'] = page.cms
    published = {d['epoch'] for d in page.dates if d['kind'] == 'datePublished' and d['epoch'] is not None}
    modified = {d['epoch'] for d in page.dates if d['kind'] == 'dateModified' and d['epoch'] is not None}
    result['status'] = 'no-zoned-publication-time' if not published else 'conflicting-publication-times'
    if len(published) == 1:
        value = next(iter(published))
        result['publisherPublished'] = datetime.fromtimestamp(value, timezone.utc).isoformat().replace('+00:00', 'Z')
        feed = document.get('published')
        result['status'] = 'publisher-time-only'
        if feed is not None:
            result['deltaSeconds'] = value - feed
            if abs(value - feed) < 1:
                result['status'] = 'feed-matches-publication'
            elif any(abs(m - feed) < 1 for m in modified):
                result['status'] = 'feed-matches-modification'
            else:
                result['status'] = 'feed-publication-differs'
    return result


def check_frozen_evidence(root):
    base_raw = (root / 'publisher-review-v2.json').read_bytes()
    base = json.loads(base_raw)
    originals = {d['id']: d for d in base['documents']}
    for name in ('publisher-review-v3', 'publisher-timestamps-v2', 'publisher-review-supplement-v1', 'publisher-review-supplement-v2', 'publisher-url-investigation-v1', 'publisher-diversity-v1', 'publisher-diversity-v2', 'publisher-date-resolutions-v1'):
        file = root / (name + '.json')
        raw = file.read_bytes()
        require(hashlib.sha256(raw).hexdigest() == file.with_suffix('.sha256').read_text().split()[0], 'Frozen evidence changed; version corrections')
        report = json.loads(raw)
        require(report['releaseEligible'] is False, 'Evidence proposals cannot claim release gates')
        def no_text(value):
            if isinstance(value, dict):
                require(not set(value) & {'body', 'content', 'description', 'title'}, 'Keep publisher text private')
                for item in value.values():
                    no_text(item)
            elif isinstance(value, list):
                for item in value:
                    no_text(item)
        no_text(report)
        if name == 'publisher-review-v3':
            expected = json.loads(base_raw)
            expected['supersedesSHA256'] = hashlib.sha256(base_raw).hexdigest()
            expected['assignmentCorrections'] = [{
                'document': 'doc-0305',
                'previousEvent': 'occurrence-0305',
                'event': 'occurrence-0091',
                'basis': 'User-accepted pair review identifies the same terror-charge occurrence in two singleton reports; existing sampled pair labels are unchanged.',
            }]
            next(d for d in expected['documents'] if d['id'] == 'doc-0305')['event'] = 'occurrence-0091'
            expected['events'] = [e for e in expected['events'] if e['id'] != 'occurrence-0305']
            next(e for e in expected['events'] if e['id'] == 'occurrence-0091')['reason'] = 'Both selected reports cover the same October 2 charge for preparing terrorist acts against Nigel Farage; later reactions remain context for this occurrence.'
            require(report == expected, 'Undeclared changes in base assignment correction')
            validate_review(report)
        elif name == 'publisher-timestamps-v2':
            require(report['manifestSHA256'] == hashlib.sha256(base_raw).hexdigest(), 'Wrong date evidence base')
            require({d['id'] for d in report['documents']} == set(originals) and len(report['documents']) == len(originals), 'Missing or duplicate timestamp observations')
            require(report['summary'] == dict(Counter(d['status'] for d in report['documents'])), 'Date summary mismatch')
            for d in report['documents']:
                require(d['url'] == originals[d['id']]['url'] and d['feedPublished'] == originals[d['id']]['published'], 'Captured dates or URLs were rewritten')
                if 'publisherPublished' in d:
                    epoch = instant(d['publisherPublished'])
                    require(epoch is not None and abs(epoch - d['feedPublished'] - d['deltaSeconds']) < 0.001, 'Date comparison mismatch')
        elif name in ('publisher-review-supplement-v1', 'publisher-review-supplement-v2'):
            require(report['baseSHA256'] == hashlib.sha256(base_raw).hexdigest(), 'Wrong supplement base')
            docs = {d['id']: d for d in report['documents']}
            events = {e['id']: e for e in report['events']}
            require(len(docs) == len(report['documents']) and len(events) == len(report['events']), 'Duplicate supplement IDs')
            changes = {c['id']: c for c in report['proposedAssignmentCorrections']}
            for e in events.values():
                expected = 'holdout' if int(hashlib.sha256(('news-review-v2:' + e['family']).encode()).hexdigest()[:8], 16) % 10 >= 7 else 'tune'
                require(e['split'] == expected and e['reviewStatus'] == 'pending', 'Unreviewed family split changed')
            old_events = {e['id']: e for e in base['events']}
            for d in docs.values():
                require(d['event'] in events and d['scope'] in ('event', 'document-only'), 'Invalid supplement assignment')
                if d['id'] in originals:
                    original = originals[d['id']]
                    require(all(d.get(k) == original.get(k) for k in ('url', 'source', 'language', 'feed', 'published', 'captureIndex')), 'Base metadata changed')
                    require(events[d['event']]['split'] == old_events[original['event']]['split'], 'Base document moved across splits')
                    if d['event'] != original['event']:
                        require(d['id'] in changes and changes[d['id']]['previousEvent'] == original['event'] and changes[d['id']]['proposedEvent'] == d['event'] and changes[d['id']]['reviewStatus'] == 'pending', 'Undeclared assignment correction')
            edges, identifiers = set(), set()
            for pair in report['pairs']:
                left, right = docs[pair['left']], docs[pair['right']]
                edge = tuple(sorted((left['id'], right['id'])))
                require(edge[0] != edge[1] and edge not in edges and pair['id'] not in identifiers, 'Duplicate or self pair')
                edges.add(edge); identifiers.add(pair['id'])
                require(all(events[d['event']]['split'] == pair['split'] for d in (left, right)) and pair['reviewStatus'] == 'pending', 'Pair crosses splits or claims approval')
                require(pair['proposedLabel'] in ('same_document', 'same_event', 'different'), 'Invalid proposal label')
                require((left['event'] == right['event']) == (pair['proposedLabel'] != 'different'), 'Label contradicts occurrence proposal')
                require(pair['proposedLabel'] != 'same_event' or pair['scope'] == 'event', 'Roundups/editions cannot become event positives')
            require(300 <= len(base['pairs']) + len(report['pairs']) <= 500, 'Review batch outside issue pair budget')
            if name == 'publisher-review-supplement-v2':
                original_raw = (root / 'publisher-review-supplement-v1.json').read_bytes()
                expected = json.loads(original_raw)
                expected['supersedesSHA256'] = hashlib.sha256(original_raw).hexdigest()
                expected['assignmentCorrections'] = [{'pair': 'extra-044', 'document': 'doc-1207', 'previousEvent': 'irkutsk-information-removal', 'event': 'irkutsk-lab-death', 'label': 'same_event', 'basis': 'User-accepted supplemental review groups the same suspected plague death and quarantine with subsequent information-removal reporting.'}]
                next(d for d in expected['documents'] if d['id'] == 'doc-1207')['event'] = 'irkutsk-lab-death'
                expected['events'] = [e for e in expected['events'] if e['id'] != 'irkutsk-information-removal']
                next(e for e in expected['events'] if e['id'] == 'irkutsk-lab-death')['reason'] = 'Same suspected plague death of the laboratory worker and quarantine; the reviewed label treats subsequent information-removal reporting as occurrence context.'
                pair = next(p for p in expected['pairs'] if p['id'] == 'extra-044')
                pair['proposedLabel'] = 'same_event'
                pair['reason'] = 'Reviewed reports describe the same suspected plague death and quarantine, with information removal treated as reaction context.'
                require(report == expected, 'Undeclared changes in supplemental correction')
        elif name in ('publisher-diversity-v1', 'publisher-diversity-v2'):
            require(report['baseSHA256'] == hashlib.sha256(base_raw).hexdigest(), 'Wrong diversity base')
            supplement_raw = (root / 'publisher-review-supplement-v1.json').read_bytes()
            require(report['supplementSHA256'] == hashlib.sha256(supplement_raw).hexdigest(), 'Wrong diversity supplement')
            supplement = json.loads(supplement_raw)
            prior_docs = originals | {d['id']: d for d in supplement['documents']}
            prior_events = {e['id']: e for e in base['events'] + supplement['events']}
            docs, events = validate_review(report)
            urls = {d['url']: prior_events[d['event']]['split'] for d in prior_docs.values()}
            edges = {tuple(sorted((p['left'], p['right']))) for p in base['pairs'] + supplement['pairs']}
            for d in docs.values():
                split = events[d['event']]['split']
                require(urls.setdefault(d['url'], split) == split, 'URL crosses prior splits')
                if d['id'] in prior_docs:
                    old = prior_docs[d['id']]
                    require(all(d.get(k) == old.get(k) for k in ('url', 'feed', 'source', 'language', 'published', 'captureIndex', 'event')), 'Prior evidence changed')
                    require(events[d['event']]['family'] == prior_events[d['event']]['family'], 'Prior family changed')
            for pair in report['pairs']:
                require(tuple(sorted((pair['left'], pair['right']))) not in edges, 'Prior review pair duplicated')
            require(300 <= len(base['pairs']) + len(supplement['pairs']) + len(report['pairs']) <= 500, 'Combined pair budget exceeded')
            if name == 'publisher-diversity-v2':
                original_raw = (root / 'publisher-diversity-v1.json').read_bytes()
                expected = json.loads(original_raw)
                expected['supersedesSHA256'] = hashlib.sha256(original_raw).hexdigest()
                expected['assignmentCorrections'] = [{
                    'pair': 'diversity-024',
                    'document': 'doc-0931',
                    'previousEvent': 'trump-diesel-ban-reversal',
                    'event': 'g7-reserve-release',
                    'label': 'same_event',
                    'basis': 'Independent reviewer clarification after submitted pair sheet; broader fuel-policy grouping is a scoped exception to the separate-action rule.',
                }]
                next(d for d in expected['documents'] if d['id'] == 'doc-0931')['event'] = 'g7-reserve-release'
                expected['events'] = [e for e in expected['events'] if e['id'] != 'trump-diesel-ban-reversal']
                next(e for e in expected['events'] if e['id'] == 'g7-reserve-release')['reason'] = 'Reviewer groups the G7 reserve release and Trump export-ban reversal as one fuel-policy event for clustering; possible timeline context. This scoped exception does not redefine other event boundaries.'
                pair = next(p for p in expected['pairs'] if p['id'] == 'diversity-024')
                pair['proposedLabel'] = 'same_event'
                pair['reason'] = 'Independent reviewer groups both decisions as one event for clustering, with possible timeline context.'
                require(report == expected, 'Undeclared changes in reviewer correction')
        elif name == 'publisher-date-resolutions-v1':
            dates_raw = (root / 'publisher-timestamps-v2.json').read_bytes()
            require(report['timestampSHA256'] == hashlib.sha256(dates_raw).hexdigest(), 'Wrong timestamp evidence base')
            require(report['reviewStatus'] == 'pending' and {d['id'] for d in report['documents']} == {'doc-0658', 'doc-0684'} and len(report['documents']) == 2, 'Date proposals are not approvals')
            for d in report['documents']:
                old = next(x for x in json.loads(dates_raw)['documents'] if x['id'] == d['id'])
                require(d['pageSHA256'] == old['pageSHA256'] and d['url'] == old['url'] and d['feedPublished'] == old['feedPublished'], 'Date evidence rewritten')
                cms = {x['field']: x['epoch'] for x in d['publisherCMS']}
                require(cms['cms:publishedAt'] == cms['cms:firstPublishedAt'] == cms['cms:lastPublishedAt'] == instant(d['proposedPublicationTime']), 'Ambiguous CMS publication')
                require(cms['cms:updatedAt'] == d['feedPublished'], 'Feed does not match CMS update')
                require(any(x['kind'] == 'datePublished' and 'CEST' in x['raw'] and instant(x['raw'].replace('CEST', 'T', 1)) == cms['cms:firstPublishedAt'] for x in old['dateEvidence']), 'OpenGraph/CMS publication interpretation unsupported')
                require(any(x['epoch'] == cms['cms:createdAt'] and x['field'].startswith('jsonld:') for x in old['dateEvidence']), 'JSON-LD creation interpretation unsupported')
        else:
            require(report['summary'] == dict(Counter(v['status'] for v in report['variants'])), 'URL inventory mismatch')
            require(report['tuning']['precision'] is None and report['tuning']['releaseGatePassed'] is False, 'Empty candidate pool cannot pass')


def check(condition, message="Assertion failed"):
    if not condition:
        raise AssertionError(message)


def self_check():
    example_a = 'https://example.com/a'
    published_a = '2026-10-02T10:00:00Z'
    html = '<meta property="article:modified_time" content="2026-10-03T12:00:00Z"><script type="application/ld+json">' + json.dumps({TYPE_KEY: 'NewsArticle', 'url': example_a, 'datePublished': '2026-10-02T12:00:00+02:00', 'related': {'datePublished': '2020-01-01T00:00:00Z'}}) + '</script>'
    page = Page(html, example_a + '?utm_source=rss')
    check(len(page.dates) == 2 and page.dates[1]['epoch'] == instant(published_a))
    check(instant('2026-10-02') is None and instant('2026-10-02T12:00:00') is None)
    check(not Page(html, 'https://example.com/b').dates[1:])
    check(document_key(example_a + '?id=1') != document_key(example_a + '?id=2'))
    for malformed in ({'@graph': None}, {TYPE_KEY: None}, {TYPE_KEY: 'NewsArticle', 'url': 'https://[bad', 'datePublished': published_a}):
        bad = '<script type="application/ld+json">' + json.dumps(malformed) + '</script>'
        check(Page(bad, example_a).dates == [])
    cms = {'canonical': 'https://www.africanews.com/article/', 'createdAt': 100, 'publishedAt': 200, 'firstPublishedAt': 200, 'lastPublishedAt': 200, 'updatedAt': 300}
    from html import escape
    def cms_html(data, identifier='jsMainMediaArticle'):
        return '<div id="' + identifier + '" data-content="' + escape(json.dumps(data), quote=True) + '"></div>'
    check(len(Page(cms_html(cms), cms['canonical']).cms) == 5)
    check(not Page(cms_html(cms), 'https://www.africanews.com/other/').cms)
    check(not Page(cms_html(cms), 'https://example.com/article/').cms)
    check(not Page(cms_html(cms, 'related'), cms['canonical']).cms)
    check(not Page('<div id="jsMainMediaArticle" data-content>', cms['canonical']).cms)
    check(not Page('<div id="jsMainMediaArticle" data-content="{bad">', cms['canonical']).cms)
    check(not Page(cms_html(dict(cms, publishedAt=True, createdAt=-1, updatedAt=9_999_999_999, firstPublishedAt=None, lastPublishedAt='200')), cms['canonical']).cms)
    with tempfile.TemporaryDirectory() as path:
        directory = Path(path)
        raw = html.encode()
        (directory / 'page.html').write_bytes(raw)
        record = {'file': 'page.html', 'finalURL': example_a, 'sha256': hashlib.sha256(raw).hexdigest(), 'fetchedAt': 0}
        report = verify({'id': 'a', 'url': example_a, 'published': instant('2026-10-03T12:00:00Z')}, record, directory)
        check(report['status'] == 'feed-matches-modification' and report['publisherPublished'] == published_a)
        (directory / 'page.html').write_text('changed')
        try:
            verify({'id': 'a', 'url': example_a}, record, directory)
        except ValueError:
            pass
        else:
            raise AssertionError('Changed publisher evidence accepted')


if __name__ == '__main__':
    self_check()
    check_frozen_evidence(Path(__file__).resolve().parents[2] / 'Tests/Fixtures/story-corpus')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path)
    parser.add_argument('--pages', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    require(bool(args.manifest) == bool(args.pages) == bool(args.output), 'Supply manifest, pages and output together')
    if args.pages:
        manifest = json.loads(args.manifest.read_text())
        records = {r['url']: r for r in json.loads((args.pages / 'pages.json').read_text())}
        results = [verify(d, records[d['url']], args.pages) for d in manifest['documents']]
        report = dict(version=1, releaseEligible=False, manifestSHA256=hashlib.sha256(args.manifest.read_bytes()).hexdigest(), summary=dict(Counter(r['status'] for r in results)), documents=results)
        write_private(args.output, json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps(report['summary'], sort_keys=True))
    else:
        print('Publisher date evidence self-check passed; no network, labels or predictions.')
