# Matcher #307 independent verification — 18 October 2026

## Release disposition — 18 October 2026

After receiving the measured result and the remaining PLAN.md items, Mars directed:
"start working. i accept your and antigravity judgment". The delegated release
decision is to accept this implementation with its documented limitations:
93.33% precision and 36.84% recall on the reused English holdout, one false pair,
and no replay of the unavailable original #409 export. The 97% target remains
unmet; acceptance does not change the target, labels, measurements or evidence
independence. No new annotation or holdout-driven correction cycle is required
for this release-plan closeout.

PR #442 merged as `624ea0848db179063e17b30c2332337831a5af06`. Its hosted arm64
tests and build passed; Swift CodeQL was still running when this addendum was
written. Final hosted-check evidence and issue/board closeout are recorded in
[#439](https://github.com/marspater/NewsApp-macOS/issues/439).
Foreground appearance/keyboard work remains deferred at Mars's request, with no
visual pass claimed. #264/#268/#314 stay parked and #334 stays deferred.

## Result

**The existing English holdout does not meet the 97% point-precision target.**
Frozen candidate `eaa4527cf57b77a84ead0e5aeac002fab24f5978` (matcher v6) produced
14 true positive pairs, 1 false positive and 24 false negatives across 49 articles.
Precision is **93.33%** (Wilson 95%: 70.18–98.81%); recall is **36.84%**
(23.38–52.72%). There are 15 predicted positive pairs, 38 labelled positive pairs
and one impure event. Undefined precision is not involved.

The false pair is `doc-1081` / `doc-1376`: a housing protest and the parliamentary
vote reported as its background. These are related acts under the existing labels.
No labels, thresholds or matcher code were changed after inspecting this result.
This holdout was already reused for #440; it is regression evidence, not a fresh
independent acceptance sample. The initial recommendation was to keep #307 and
#439 open pending the release disposition recorded above.

## Revision and integration

Antigravity handed off `eaa4527` after #441 had already merged the earlier
`2c5414b` as `6bad440`. Consequently, #441's green CI does **not** validate the
later v6 bump and Unicode/upgrade regressions. The follow-up cherry-picks
`eaa4527` onto current main; its production matcher is byte-identical to the
frozen candidate. Additional integration assertions check the exact new event,
the retained event's version and saved/read state for the v5-to-v6 fixture.
These test-only assertions do not change the scored matcher.

Read-only review traced clause ranges through the same unified string used by
NLTagger and traced repartitioning through `insertEvent` → `assignMembers`.
The latter upserts each article's unique membership and advances losing-event
versions inside the existing transaction; an explicit delete before insertion
is unnecessary. Existing rollback, exclusions, archive and bounded-work tests
remain in place.

## Reproduction and provenance

- Swift 6.4 (`swiftlang-6.4.0.34.1`), Xcode 27.0 (`27A266a`), arm64; macOS 15 deployment target.
- Corpus SHA-256: `868c62a0ec973d07aa2ca3d63de8623fbe866359d1e082fadacd7bd456acf2a0`.
- English only; production 2,000-article pass budget; judge disabled and zero judge calls; no embedding promotion.
- Exact source hashes, Wilson intervals, pass counters and preservation counts are in
  [the aggregate report](../benchmarks/2026-10-18-matcher-307-verification.json).
- Private logs, membership export and copied databases stay in
  `/private/tmp/news-441-verification-09ctk4qt`; no publisher passages are committed.

The final candidate was scored once with:

```sh
NEWS_EVENT_CORPUS=/Users/marspater/Documents/NewsHoldout-2026-10-03/accepted-replay-2026-10-04/reviewed-event-corpus.json \
NEWS_EVENT_LANGUAGE=en NEWS_EVENT_JUDGE=0 NEWS_EVENT_OUTPUT="$PRIVATE_OUTPUT" \
./test.sh --event-corpus --corpus-holdout
```

`PRIVATE_OUTPUT` was an existing empty mode-0700 directory. The first sandboxed
attempt failed during Swift macro compilation, before predictions; the same
command then completed outside the sandbox. Its zero exit status means the
evaluation ran successfully, not that the precision gate passed. The retained
test executable then completed the full offline regression suite successfully.
`./build.sh` also completed in the disposable source directory. `lipo -archs`
reported arm64, `codesign --verify --deep --strict` passed, and the ad-hoc bundle
retained App Sandbox. It was neither launched nor installed.

Antigravity's supplied tune result is 32 TP / 0 FP / 61 FN on 105 articles:
100% precision (89.28–100%) and 34.41% recall (25.55–44.51%). This is owner-supplied
tune evidence, not a second independent replay. Its missing dedicated tune
receipt/files are not silently represented as published artifacts.

## Copied-library upgrade

The audit used a fresh SQLite backup of the preserved v5 result, with the original
historical clock `1792270157.230165`; it did not shift the active window to today.
The original source hash remained
`0ec6fe43934b78fe7aaaa9baff66f3da28ca3268c877807db45b398ba147103d`.

The first pass processed 1,898 articles, detached 108, created 2 groups, joined 18
articles and merged 76 fragments. The second pass merged 2 fragments; the third
performed no work. An additional repeat also performed no work. All passes stayed
within the 2,000-article budget and reported zero conflicts/judge calls.

All 4,303 article and article-state rows, 4,054 feed memberships, 3,244 stored
ratings, 780 historical expiry records and 2 event-state rows remained identical.
All 1,813 existing event-member articles retained a membership; 27 original active
events ended in multiple partitions, with every original member accounted for
exactly once. All 248 inactive event rows and their memberships remained identical.
SQLite integrity was `ok`, with zero foreign-key violations. The snapshot contains
zero exclusion rows, so exclusion preservation is additionally covered by the
deterministic suite rather than inferred from this empty denominator.

## Evidence limitations

The precision target is unmet. The original #409 private export remains unavailable;
recovering some headlines from a session log does not complete that replay. The
release disposition above accepts the reduced scope without claiming this replay
was completed. Unit tests and tune-only precision do not establish the 97% target.
Do not tune against this holdout.

All checks stayed headless. No installed library was changed, no app was installed
or launched, and no window or system setting was touched. Native appearance and
keyboard verification remain paused; #264/#268/#314 stay parked and #334 deferred.
