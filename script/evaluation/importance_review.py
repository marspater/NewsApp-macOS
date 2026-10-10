#!/usr/bin/env python3
"""Prepare the #309 importance review from a private `--curation-live` run and report aggregates only.

`sheet RUN` writes RUN/importance-review-private.csv: every minor-rated story of the run's 72-hour window, newest
first, with headline, summary and publisher. The waiting flag and the re-rate stay out of the sheet, so the
reviewer labels each story `important` or `minor` blind. `report RUN` writes RUN/importance-evaluation.json: how many
stories the reviewer judged important while the app hides them, with Wilson 95% bounds, and how often one sampled
re-rate agrees. It contains no story text. With no arguments, the script checks itself on a synthetic run.
"""
import json
import math
import pathlib
import tempfile

from overview_review import (expect_rejected, label_sheet, main, private_run, rate, read_sheet_labels, require,
                             wilson, write_new_sheet)

LABELS = ('important', 'minor')
LEVELS = ('minor', 'notable', 'major')
SOURCE = 'minor-review-private.json'
SHEET = 'importance-review-private.csv'
REPORT = 'importance-evaluation.json'
COLUMNS = ['story', 'publisher', 'title', 'summary', 'label', 'note']


def stories(directory):
    path = directory / SOURCE
    require(path.exists(), f'No {SOURCE} in the run directory; run ./test.sh --curation-live first')
    rows = json.loads(path.read_text())
    require(all(row.get('waiting') in ('yes', 'no') for row in rows), 'Every story needs a waiting flag')
    require(len({row['id'] for row in rows}) == len(rows), 'Duplicate story in review inputs')
    return [(row['id'], row) for row in rows]


def review_rows(rows):
    return [{'story': key, 'publisher': row.get('source', ''), 'title': row['title'], 'summary': row.get('summary', ''),
             'label': '', 'note': ''} for key, row in rows]


def sheet(directory):
    directory = private_run(directory)
    return write_new_sheet(directory / SHEET, COLUMNS, review_rows(stories(directory)))


def upper_bound(successes, trials):
    interval = wilson(successes, trials)
    return interval[1] if interval else None


def review_groups(rows, labels):
    """Labelled stories, the waiting ones among them, the important ones and the important ones the app hides."""
    counts = {'labelled': 0, 'waiting': 0, 'important': 0, 'hidden': 0}
    for key, row in rows:
        label, waits = labels.get(key), row['waiting'] == 'yes'
        if label:
            counts['labelled'] += 1
            counts['waiting'] += waits
            counts['important'] += label == 'important'
            counts['hidden'] += label == 'important' and waits
    return counts['labelled'], counts['waiting'], counts['important'], counts['hidden']


def hidden_important(rows, labels):
    labelled, waiting, important, hidden = review_groups(rows, labels)
    return {'labelled': labelled, 'unlabelled': len(rows) - labelled,
            'important': rate(important, labelled),
            'hiddenImportant': rate(hidden, labelled),
            'hiddenImportantUpperBound95': upper_bound(hidden, labelled),
            'hiddenAmongWaiting': rate(hidden, waiting),
            'hiddenAmongWaitingUpperBound95': upper_bound(hidden, waiting)}


def stability(rows):
    """One sampled re-rate of each minor rating; `none` means the model gave no answer."""
    answers = [row.get('rerate', 'none') for _, row in rows]
    rerated = [answer for answer in answers if answer in LEVELS]
    return {'rerated': len(rerated), 'noAnswer': len(answers) - len(rerated),
            'sameLevel': rate(sum(answer == 'minor' for answer in rerated), len(rerated)),
            'changedTo': {level: sum(answer == level for answer in rerated) for level in LEVELS[1:]}}


def report(directory):
    directory = private_run(directory)
    rows = stories(directory)
    sheet_path = directory / SHEET
    labels = read_sheet_labels(sheet_path, 'story', LABELS, review_rows(rows)) if sheet_path.exists() else {}
    review = hidden_important(rows, labels)
    result = {
        'minorRated': len(rows), 'waiting': sum(row['waiting'] == 'yes' for _, row in rows),
        'review': review, 'stability': stability(rows),
        'decisionInputs': {'labellingComplete': bool(rows) and review['unlabelled'] == 0,
                           'hiddenImportantObserved': review['hiddenImportant']['count'] > 0,
                           'modelUpdateDecision': 'Ratings are kept across macOS model updates (#297); Mars decides '
                                                  'whether to re-rate still-waiting stories after an update.'},
        'limitations': 'Labels judge the headline and summary the model saw. A label reflects one reviewer. '
                       'Unread waiting stories are deleted 24 hours after their event\'s first report, so the run '
                       'sees only younger waiting stories (and read, saved or cited ones), while shown minor stories '
                       'span the whole window: hiddenAmongWaiting is the comparable rate, and hiddenImportant mixes '
                       'both and misses stories already expired. Production rates greedily, so the same text always '
                       'gets the same level; the re-rate samples from the top 90% of the same model to show how close '
                       'ratings sit to a boundary. It does not measure a model update.',
    }
    (directory / REPORT).write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    return result


def fixture(directory):
    """Five minor-rated stories: three waiting, two shown; four answered re-rates, one changed to notable."""
    rows = [{'id': f'a{index}', 'title': f'Headline {index}', 'summary': f'Private summary {index}', 'source': 'Publisher A',
             'waiting': waiting, 'rerate': rerate}
            for index, (waiting, rerate) in enumerate([('yes', 'minor'), ('yes', 'notable'), ('yes', 'minor'),
                                                       ('no', 'minor'), ('no', 'none')], 1)]
    (directory / SOURCE).write_text(json.dumps(rows))


def check_sheet(directory):
    fixture(directory)
    require(sheet(directory) == 5, 'Sheet lists every minor-rated story')
    expect_rejected(lambda: sheet(directory), FileExistsError, 'A labelled sheet was replaced')
    text = (directory / SHEET).read_text()
    require('waiting' not in text and 'notable' not in text, 'Sheet hides the waiting flag and the re-rate')
    require(not report(directory)['decisionInputs']['labellingComplete'], 'Unlabelled stories leave labelling incomplete')
    rows = label_sheet(directory / SHEET, COLUMNS, ['important', 'minor', 'minor', 'important', 'minor'])
    require([row['story'] for row in rows] == ['a1', 'a2', 'a3', 'a4', 'a5'], 'Stories keep their run order and article IDs')


def check_report(directory):
    result = report(directory)
    review, steady = result['review'], result['stability']
    require((result['minorRated'], result['waiting'], review['labelled']) == (5, 3, 5), 'Population counts')
    require((review['important']['count'], review['hiddenImportant']['count']) == (2, 1), 'Important and hidden counts')
    require(math.isclose(review['hiddenImportantUpperBound95'], wilson(1, 5)[1]), 'Hidden-important Wilson upper bound')
    require(review['hiddenAmongWaiting']['of'] == 3, 'Waiting denominator')
    require((steady['rerated'], steady['noAnswer'], steady['sameLevel']['count']) == (4, 1, 3), 'Re-rate stability')
    require(steady['changedTo'] == {'notable': 1, 'major': 0}, 'Re-rate changes by level')
    require(result['decisionInputs']['labellingComplete'] and result['decisionInputs']['hiddenImportantObserved'], 'Decision inputs')
    public = (directory / REPORT).read_text()
    require('Headline' not in public and 'Private summary' not in public, 'Report must not carry story text')
    source = directory / SOURCE
    original = source.read_text()
    for column in ('title', 'summary', 'source'):
        changed = json.loads(original)
        changed[0][column] += ' changed'
        source.write_text(json.dumps(changed))
        expect_rejected(lambda: report(directory), ValueError, f'Changed {column} inherited an old label')
        require((directory / REPORT).read_text() == public, 'Rejected inputs replaced the last report')
    changed.append(changed[0])
    source.write_text(json.dumps(changed))
    expect_rejected(lambda: report(directory), ValueError, 'Duplicate story inputs accepted')
    source.write_text(original)
    (directory / SHEET).write_text('story,label\na1,important\nb9,minor\n')
    expect_rejected(lambda: report(directory), ValueError, 'A sheet from another run was accepted')
    (directory / SHEET).write_text('story,label\na1,maybe\n')
    expect_rejected(lambda: report(directory), ValueError, 'Unknown label accepted')


def self_check():
    with tempfile.TemporaryDirectory() as temporary:
        directory = pathlib.Path(temporary)
        check_sheet(directory)
        check_report(directory)
    print('Importance review self-check passed')


if __name__ == '__main__':
    main(__doc__, {'sheet': sheet, 'report': report}, self_check, 'stories')
