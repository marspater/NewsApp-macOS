#!/usr/bin/env python3
"""Prepare the #314 related-story review from a private `--related-live` run and report aggregates only.

`sheet RUN` writes RUN/relations-review-private.csv: every pair the run proposes as "earlier in this story", mixed blind
with one hard control per linked event (an earlier event sharing a person, organization or place that the rule
rejected). A reviewer labels each pair `related` (the earlier event is part of the same developing story),
`unrelated` or `unsure`.
`report RUN` writes RUN/relation-evaluation.json: the wrong-link rate of proposed links with Wilson 95% bounds, how
many controls the reviewer judged related, and coverage. It contains no publisher text. With no arguments, the script
checks itself on a synthetic run.
"""
import json
import pathlib
import tempfile

from overview_review import (expect_rejected, label_sheet, main, private_run, rate, read_sheet_labels, require,
                             write_new_sheet)

LABELS = ('related', 'unrelated', 'unsure')
RUN = 'relations-private.json'
SHEET = 'relations-review-private.csv'
REPORT = 'relation-evaluation.json'
COLUMNS = ['pair', 'earlier', 'earlier_summary', 'later', 'later_summary', 'gap_hours', 'label', 'note']
INPUTS = COLUMNS[1:6]


def pairs(directory):
    records = json.loads((directory / RUN).read_text())
    require(all(record['kind'] in ('link', 'control') for record in records), 'Unknown pair kind in the run')
    return records


def review_rows(records):
    """Blind rows: the kind and event IDs stay in the run file."""
    return [{'pair': f'R{index}', **{column: record[column] for column in INPUTS}, 'label': '', 'note': ''}
            for index, record in enumerate(records, 1)]


def sheet(directory):
    directory = private_run(directory)
    return write_new_sheet(directory / SHEET, COLUMNS, review_rows(pairs(directory)))


def report(directory):
    directory = private_run(directory)
    records = pairs(directory)
    labels = read_sheet_labels(directory / SHEET, 'pair', LABELS, review_rows(records))
    by_kind = {'link': [], 'control': []}
    for row, record in zip(review_rows(records), records):
        by_kind[record['kind']].append(labels[row['pair']])
    links, controls = by_kind['link'], by_kind['control']
    decided = [label for label in links if label in ('related', 'unrelated')]
    decided_controls = [label for label in controls if label in ('related', 'unrelated')]
    result = {
        'links': {'proposed': len(links), 'labelled': sum(label is not None for label in links),
                  'unsure': links.count('unsure'),
                  'wrong': rate(decided.count('unrelated'), len(decided))},
        'controls': {'pairs': len(controls), 'labelled': sum(label is not None for label in controls),
                     'unsure': controls.count('unsure'),
                     'relatedMissed': rate(decided_controls.count('related'), len(decided_controls))},
        'labellingComplete': all(label is not None for label in links + controls),
        'limitations': 'Controls are the hardest rejected candidates, so their related rate shows missed links among '
                       'near misses, not overall recall. Labels are one reviewer\'s judgement.',
    }
    (directory / REPORT).write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    return result


def synthetic_run(directory):
    records = [{'kind': kind, 'earlier': f'Earlier {index}', 'earlier_summary': 'Summary', 'later': f'Later {index}',
                'later_summary': 'Summary', 'gap_hours': '12.0', 'earlierEvent': f'e{index}',
                'laterEvent': f'l{index}', 'hash': str(index)}
               for index, kind in enumerate(['link', 'control', 'link', 'link', 'control'])]
    (directory / RUN).write_text(json.dumps(records))
    return records


def self_check():
    with tempfile.TemporaryDirectory() as temporary:
        directory = pathlib.Path(temporary)
        synthetic_run(directory)
        require(sheet(directory) == 5, 'Every pair gets a row')
        require('link' not in (directory / SHEET).read_text(), 'The sheet does not reveal which rows are links')
        expect_rejected(lambda: sheet(directory), FileExistsError, 'An existing sheet was replaced')
        partial = report(directory)
        require(not partial['labellingComplete'] and partial['links']['wrong']['of'] == 0, 'Unlabelled run reports nothing')
        rows = label_sheet(directory / SHEET, COLUMNS, ['related', 'related', 'unrelated', 'unsure', 'unrelated'])
        result = report(directory)
        require(result['labellingComplete'], 'All rows labelled')
        require(result['links']['wrong']['count'] == 1 and result['links']['wrong']['of'] == 2,
                'Wrong-link rate counts unrelated links among decided links')
        require(result['links']['unsure'] == 1, 'Unsure links are counted, not decided')
        require(result['controls']['relatedMissed']['count'] == 1 and result['controls']['relatedMissed']['of'] == 2,
                'A related control is a missed link')
        rows[0]['later'] += ' changed'
        (directory / SHEET).unlink()
        write_new_sheet(directory / SHEET, COLUMNS, rows)
        expect_rejected(lambda: report(directory), ValueError, 'A changed reviewed input was accepted')
    print('Relation review self-check passed')


if __name__ == '__main__':
    main(__doc__, {'sheet': sheet, 'report': report}, self_check, 'pairs')
