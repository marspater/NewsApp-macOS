# Event clustering, event cards and a stable feed — 2 October 2026

## Scope

This completes the implementation side of Phase D (#94) on top of the event data model (#124) and bounded candidates (#125). It covers:

- conservative matching (#126)
- incremental clustering (#128)
- event cards and the source list (#129)
- a stable feed (#130)
- event read and update semantics (#131)
- local "different events" exclusions (#132)

The embedding evaluation (#127) is not attempted. It is optional and can only be judged against the #102 holdout.

## Implementation

**Features.** `EventFeatures` reads the title and the first 600 description characters:

- **Who and where:** NLTagger people, organizations and places, plus capitalized words inside a sentence (skipped for German and Luxembourgish, where nouns are capitalized).
- **What:** lemmatized nouns, verbs and adjectives, minus news boilerplate.
- **When:** quarters and halves, years, weekdays, and figures in the headline, including spelled numbers up to twelve.

**Pairs.** `EventMatcher.assess` scores 0.4 for shared action terms (cosine), 0.4 for shared anchors (overlap) and 0.2 for time. A match requires all of the following:

- one shared anchor
- two shared action terms, and at least three shared terms in total
- a score of 0.55 or more
- for pairs more than 12 hours apart, stronger term agreement

Any contradiction rules a pair out: a different language, a gap over 36 hours, or disjoint periods, years, weekdays, headline figures or place sets.

**Whole events.** `eventScore` admits a newcomer only if it matches one member, is compatible with every member and reaches the mean score. Events stop growing at 100 members.

**Clustering.** `EventClusterer` takes pending articles oldest first. Pending means dated within the 72-hour active lifetime and not yet processed by the current matcher version.

- A changed member that no longer fits leaves its event.
- The article joins the best active event it fits as a whole. Otherwise it starts an event with unclustered candidates that match it strongly and stay pairwise compatible, unless a pair is excluded.
- `DatabaseEngine.applyEventMatch` re-checks the event version, partner availability and exclusions inside the transaction. On a conflict nothing is written, and the article is retried at most twice.
- Passes are bounded at 2,000 articles and are cancellable.

**Refresh wiring.** `FeedManager` starts one detached utility pass after a refresh has published, and once at launch. It is single-flight, with at most one follow-up pass. It bumps `ArticleStore.eventRevision` when events change and is cancelled by `stopBackgroundWork`.

**Schema v14.** All three tables are created in one transaction with a cancellation check:

- `event_match_state`, with `trg_articles_event_rematch` on title or description changes.
- `event_exclusions`: ordered pairs that cascade with articles.
- `event_state`: the seen version, which only grows.

**Feed.**

- `EventFeedGrouping` groups the already filtered page. Each confirmed event (two or more members) becomes one card at its first listed member, so a source filter keeps its own article visible.
- `FeedUpdateBuffer` holds the displayed list while the reader is scrolled, hovering, has a focused card or has an article open. Content refreshes in place. Additions, removals and regrouping wait behind "N new stories" (the U key, or Navigate → Show Queued Updates). Applying the update uses no animation under Reduce Motion, and the waiting update is announced to VoiceOver.
- `EventCardView` shows the representative card, "N sources · updated …", an "Updated" badge for new unread headlines since the seen version, and the member list. Each member has read, save and "Not the Same Event" through the context menu and accessibility actions.
- The G key, or the header toggle, switches to individual publications. Saved Stories and History stay ungrouped.

## Verification

The authoring environment was a Linux container with no Swift toolchain, and download.swift.org was blocked by its network policy. Nothing was compiled or run locally. The changed Swift files pass a tree-sitter syntax check, apart from pre-existing `try await` parser false positives. Compile and test results come from macOS CI on #196.

New tests in the full suite and `--story-regressions`:

- `testEventMatcherRules`:
  - match rules and every conflict kind
  - the 12-hour strictness
  - whole-event compatibility stopping an A≈B≈C chain
  - exclusions and the size cap
  - real NaturalLanguage extraction of periods, weekdays, years, spelled figures, markup, reporting verbs and mid-sentence names
- `testEventClustering`:
  - a synthetic control set: one earthquake reported three ways, Kharkiv strikes on different days, Apple Q3 and Q4 reports, identical "Live updates" headlines
  - articles outside the lifetime are never matched; a second pass recomputes nothing
  - a changed member leaves its event with a single version bump; a new report joins
  - an exclusion survives a refresh and a complete re-clustering; saved state survives regrouping
  - bounded and cancelled passes leave work pending; `foreign_key_check` passes
- `testEventReadingState`:
  - unseen events are new, not updated; reprints are not updates; overview version 2 does not cover later reporting
  - reading the new article settles the update; seen versions never go back
  - merged reporting counts as an update; article state is independent of event state
  - a copied v13 library migrates to v14 with cancellation rollback, preserved events and saved state, and passes `quick_check`
- `testEventFeedGroupingAndStability`:
  - representatives and visible members; publication mode; source filters; duplicates
  - the buffer's waiting, in-place, removal, regrouping and paging behaviour
- `testRefreshClustersEvents`: two feeds refreshed through `FeedManager` are grouped afterwards, and the feed is told to regroup.
- `testEventCorpusHarness`: the corpus harness on the control set shows no false merges.

## Remaining

- **Holdout precision.** Precision on the #102 holdout (≥97% target), with recall and false merges reported separately, is unmeasured. Run `NEWS_EVENT_CORPUS=… ./test.sh --event-corpus` once the corpus exists. Thresholds are starting values.
- **Native QA.** No native UI, keyboard traversal or VoiceOver interaction was exercised (#155).
- **Performance.** There is no timing of clustering passes on a large library (#153).
- **Recall trade-offs.** Languages without NaturalLanguage name or lemma models match less, and cross-language coverage is never grouped. Differing headline figures keep toll updates of one incident apart.
- **Behaviour not built.** Reports that fit two events join the better one; events are not merged automatically. New-story notifications are unchanged.
