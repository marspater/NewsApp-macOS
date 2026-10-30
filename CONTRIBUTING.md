# Contributing to NewsApp

Start with [README.md](README.md), [architecture and technology constraints](docs/ARCHITECTURE.md), [PRIVACY.md](PRIVACY.md) and [SECURITY.md](SECURITY.md); for UI work, also the [design language](docs/DESIGN.md). These documents apply to every contributor. `AGENTS.md` and `JULES.md` contain instructions for coding agents only.

## Development

Use the existing native Swift/SwiftUI stack, keep changes focused, preserve user data and migrations, and treat feed/article input as untrusted. Maintain Swift 6 isolation and cancellation, deterministic taxonomy, accessibility, and the design language in [docs/DESIGN.md](docs/DESIGN.md): its tokens, components and Liquid Glass rules. Do not add cloud AI, telemetry or third-party models; the only models that ship are Apple's and CoreML models this project builds, measures and ships itself (#520).

Build on Apple silicon with Xcode 27 selected. The deployment target remains macOS 15; newer APIs require availability checks.

## Validation

The current release simplification uses existing #102 labeled tune/English holdout regression inputs; the #409 comparison requires its original private replay export. Importance and overview review commands below remain opt-in historical audit tools, not new release requirements. Developing-story links (#314) ship in event overviews; their collector stays disabled, and the review commands below re-measure wrong links on a private library copy. See [the accepted plan](docs/plans/2026-10-17-release-simplification.md).

```sh
./test.sh                         # Full regressions, including parser-to-embedding/clustering integration; also run by the commit hook
NEWS_TEST_FORCE=1 ./test.sh       # A plain ./test.sh skips the Swift runner when the same inputs already passed on this machine; this reruns it
./test.sh --parsing-regressions   # Focused offline HTML/feed compatibility and safety checks
script/format.sh                  # swift-format; automatically formats staged Swift files in pre-commit hook
script/format.sh --check          # Strict repository-wide Swift formatting lint
script/design_lint.sh              # DESIGN.md ratchet (first step of ./test.sh); --update only after lowering counts
./test.sh --story-regressions     # Focused offline identity, reader and persistence checks
./test.sh --matcher-regressions   # Authored matcher corpus (#506) and story regressions (#581): pairwise lines and failing pair ids, nothing else
NEWS_VERDICTS=verdicts.json ./test.sh --verdict-replay # Bounded calibration (#629): verdicts decided as the reader did at the bare and the calibrated pair-model cutoff; JSON array of {"pairModel", "cosine", "sharedSpecific", "gapHours", "sameAct", "same"}, synthetic verdicts without the variable
./test.sh --curation-live /private/tmp/library-backup.sqlite3 /private/tmp/curation-report # Opt-in on-device rating audit of a SQLite backup; private titles stay local
python3 script/evaluation/importance_review.py sheet /private/tmp/curation-report  # #309: blind private sheet of minor-rated stories (never overwrites a sheet)
python3 script/evaluation/importance_review.py report /private/tmp/curation-report # #309: aggregate-only hidden-important rate with Wilson bounds and re-rate stability
./test.sh --overviews-live /private/tmp/library-backup.sqlite3 /private/tmp/overview-report # Opt-in on-device labeled controls and live overview audit; private passages stay local. NEWS_OVERVIEWS_EXTRACT=1 first stores publisher text through the production coordinator (#308)
python3 script/evaluation/overview_review.py sheet /private/tmp/overview-report  # #308: private claim sheet for an independent reviewer (never overwrites a sheet)
python3 script/evaluation/overview_review.py report /private/tmp/overview-report # #308/#313: aggregate-only rates, Wilson bounds, latency, fallback causes, perspective coverage
./test.sh --images-live /private/tmp/library-backup.sqlite3 /private/tmp/curation-report # Opt-in protected page-prefix lookups and card-image coverage on the backup; NEWS_IMAGES_NOW=<epoch> repeats an earlier 72-hour denominator
NEWS_RELATED_RECLUSTER=1 ./test.sh --related-live /private/tmp/library-backup.sqlite3 /private/tmp/relation-report # #314: related-story links plus hard controls, rejection stages and a per-stage near-miss sample on the backup; optional current-matcher re-clustering first
python3 script/evaluation/relation_review.py sheet /private/tmp/relation-report  # #314: blind private sheet of links and controls (never overwrites a sheet)
python3 script/evaluation/relation_review.py report /private/tmp/relation-report # #314: aggregate-only wrong-link rate and related controls with Wilson bounds
./test.sh --performance-baseline --active-work-cancellation # Active clustering, ingestion and feed parsing cancellation; temporary stress fixtures
NEWS_NATIVE_SEARCH_QA=1 ./script/native_performance_baseline.sh # Native compact/expanded search at narrow and wide window sizes
./script/native_performance_baseline.sh # Isolated MainView window, rendered-card samples and process memory
NEWS_NATIVE_HARNESS=Tests/NativeWorldTensionQA.swift ./script/native_performance_baseline.sh # Live on-device synthetic-headline assessment, Settings tab bounds and display callback cadence
NEWS_NATIVE_HARNESS=Tests/NativeReadingMemory.swift ./script/native_performance_baseline.sh # Live: read 20 stories twice in the production reader, isolated; waits until each image is decoded
NEWS_READING_FULL_APP=1 ./script/native_performance_baseline.sh # Live: sandboxed bundle, production cache, same reading plus ten overviews and five publisher Web views
./script/test_voiceover_live_qa.sh --self-test # Parked (#268): bounded command-protocol regressions, no AX permission required
./script/test_voiceover_live_qa.sh --smoke     # Parked (#268): isolated production views and offline image/render evidence
./script/test_voiceover_live_qa.sh --live      # Parked (#268): rendered AX tree, actions/persistence and production update notifications
./script/test_voiceover_live_qa.sh --manual    # Parked (#268): interactive isolated fixture for spoken VoiceOver/rotor traversal
./script/test_notification_live.sh DIR # Opt-in real OS notifications with synthetic reports, temporary settings and in-memory SQLite; existing News authorization required
./script/test_native_ui_qa.sh        # Automated Native UI QA checks with system settings overrides (#155, #123)
./script/appearance_matrix.sh [DIR]  # Window captures of list, grid, reader and overview in light, dark and Increase Contrast; needs Screen Recording
./script/run_isolated.sh [OPTIONS]   # Launch isolated app with simulated Increase Contrast, Reduce Motion, VoiceOver
./script/launch_baseline.sh       # Production bundle under a separate identifier: launch to first card and memory, seeded library
./test.sh --performance-baseline  # Opt-in optimized synthetic core-service timings
./test.sh --transport-cancellation # Optimized refresh shutdown over controlled HTTP/SOCKS sockets
./test.sh --publisher-cancellation # Opt-in, live: refresh and stop the twelve panel feeds over real HTTPS
NEWS_EVENT_CORPUS=corpus.json ./test.sh --event-corpus # Event clustering precision/recall on a local labeled corpus (#102)
NEWS_EMBEDDING_THRESHOLD=0.4 NEWS_EVENT_CORPUS=corpus.json ./test.sh --event-corpus --corpus-holdout # Holdout, embeddings at the cutoff chosen on tune (#127)
NEWS_EVENT_DIAGNOSE=1 NEWS_EVENT_CORPUS=corpus.json ./test.sh --event-corpus # Adds one line per labeled or linked pair (ids only): conflict, gates, what, score, cosine (#509)
NEWS_SNAPSHOT_DB=copy.sqlite3 NEWS_EVENT_OUTPUT=DIR ./test.sh --review-pairs # Local: every stored pair decision of a library copy with headlines, events and corrections, as pairs-review.csv (#551)
NEWS_SNAPSHOT_DB=copy.sqlite3 NEWS_EVENT_OUTPUT=DIR ./test.sh --review-pairs --holdout-candidates # Local: candidate pairs for the library holdout (borderline ≥ 0.6, singletons beside an event, fragment pairs), as holdout-candidates.csv (#579)
NEWS_SNAPSHOT_DB=copy.sqlite3 NEWS_LIBRARY_HOLDOUT=holdout.json ./test.sh --library-holdout # Local: re-clusters a temporary copy from scratch and scores the labelled pairs at strict event and story level; the gate for matcher changes (#579, #627). NEWS_PAIR_THRESHOLD and NEWS_PAIR_MODEL=0 apply; NEWS_EVENT_DIAGNOSE=1 names each miss; NEWS_EVENT_OUTPUT=DIR also writes story-groups.csv, the stories that join two or more events, for the group review (#581)
NEWS_HOLDOUT_NOW=1792854000 NEWS_SNAPSHOT_DB=copy.sqlite3 NEWS_LIBRARY_HOLDOUT=holdout.json ./test.sh --library-holdout # NEWS_HOLDOUT_NOW=<epoch> pins the re-clustering clock for a copy taken after the holdout was drawn (#688); 1792854000 is 24 October 2026 15:00 UTC, when the 24 October holdout was drawn
NEWS_SNAPSHOT_DB=copy.sqlite3 ./test.sh --duplicate-replay # Local: re-ingests each same-publisher, same-headline pair of a library copy and reports how many become one story (#583)
NEWS_SNAPSHOT_DB=copy.sqlite3 ./test.sh --fragment-merge-timing # Local: one fragment-merge pass over a temporary copy of a library, timed, with the merge count (#541, #582)
NEWS_PAIR_PREFIX=1 NEWS_SNAPSHOT_DB=copy.sqlite3 NEWS_LIBRARY_HOLDOUT=holdout.json NEWS_PAIR_MODEL_PATH=OUT/pairscorer.mlmodelc ./test.sh --library-holdout # Evaluate a pair model trained with the gap-and-publisher prefix (#626); off by default, and the exporters follow it (set it on each command, as here)
NEWS_PAIR_MODEL_PATH=OUT/pairscorer.mlmodelc ./test.sh --matcher-regressions # A candidate pair model instead of the shipped one (#624); use the same per-command assignment for --library-holdout and --event-corpus with their inputs; compile the .mlpackage first with `xcrun coremlcompiler compile OUT/pairscorer.mlpackage OUT`
NEWS_SNAPSHOT_DB=copy.sqlite3 NEWS_LIBRARY_HOLDOUT=holdout.json NEWS_PAIR_MODEL_PATH=OUT/pairscorer.mlmodelc NEWS_PAIR_RULE=story NEWS_STORY_MODEL=0.9 NEWS_STORY_MODEL_PATH=OUT/pairscorer.mlmodelc ./test.sh --library-holdout # Evaluation of a three-way pair model (#627): NEWS_PAIR_MODEL_PATH names the admission candidate, which NEWS_PAIR_RULE=story admits on p_same + p_related; NEWS_STORY_MODEL sets the story pass's model signal at s (off by default), read from NEWS_STORY_MODEL_PATH; the holdout's story level and the story regressions measure stories, while --event-corpus and --matcher-regressions stay scored by event (their labels are events)
NEWS_SNAPSHOT_DB=copy.sqlite3 NEWS_LIBRARY_HOLDOUT=holdout.json NEWS_PAIR_THRESHOLD=0.8 ./test.sh --library-holdout # Sweep override (#582): one knob per run, measured against the holdout; the knobs are NEWS_PAIR_THRESHOLD=0.8, NEWS_RESCUE_TWO_ANCHORS=0.65, NEWS_MODEL_ANCHORLESS=0.85, NEWS_COMPATIBLE_REQUIRES_MATCH=1, NEWS_COMPATIBLE_SHARE=1 (a finite share in 0...1) and NEWS_SAME_PUBLISHER=1, each also read by --event-corpus and --matcher-regressions
NEWS_ENERGY=0 ./test.sh --matcher-regressions # The rules-only pass of Low Power Mode (#534): no embedding, no pair model; deferred rows counted, not re-read. A fresh replay has no stored vectors, so every rule match waits for a pass with energy: the true-positive floor and the story links are not checked in this mode, only that nothing is linked wrongly
./test.sh --corpus-capture DIR    # Opt-in, live: capture catalog feed items into a private directory (#102)
./test.sh --corpus-review DIR     # Fingerprint match review sheet and precision against private labels (#102)
./test.sh --corpus-readiness DIR --corpus-holdout # Eligible held-out document counts only; no scores, labels or review-file writes
./test.sh --corpus-pages DIR --corpus-urls requests.json # Opt-in protected publisher-page evidence; [{"id":"doc-1","url":"https://…"}]
./test.sh --corpus-page-texts DIR # Offline private readability evidence; no matching predictions
./build.sh                        # arm64 app with ad-hoc verification signing
NEWS_LIVE_READER_CHECK=1 ./test.sh # Optional controlled-network and publisher checks
./test.sh --model-outcome-check   # Opt-in, local: the real on-device model over authored violent reports; outcome labels in the NewsTextModel log category (#508)
NEWS_SNAPSHOT_DB=copy.sqlite3 NEWS_EVENT_OUTPUT=DIR ./test.sh --export-categories # Local: 200-story sample with publisher and assigned categories for the topic-classifier audit (#546); NEWS_CATEGORY_IDS=file re-exports a labelled sample
NEWS_SNAPSHOT_DB=copy.sqlite3 NEWS_EVENT_OUTPUT=DIR NEWS_EVENT_CORPUS=corpus.json NEWS_LIBRARY_HOLDOUT=holdout.json ./test.sh --export-pairs # Local: re-cluster each library copy from scratch at this build and mine three-way pair-model training pairs from it, corpus and library-holdout articles left out (#525, #627; contract in train_pair_model.py); the reader's Same / Not the Same verdicts come first at weight 5 (#552); add --verdicts-only for just those rows as verdicts.csv
~/news-eval/venv/bin/python script/training/train_pair_model.py DIR/pairs.csv OUT --exclude-headlines FILE [--pretrain A.csv ...] [--init OUT1/pretrain-state.pt] # Local only (FILE: folded headlines of the library holdout and the tune corpus, one a line; required with --pretrain, and it also drops copies of those headlines that reached DIR/pairs.csv under another id): retrain the three-way pair model (#627: different, related, same; partial labels, label smoothing 0.05, stage 2 at 1.5e-5 with the lower layers frozen; script/training/requirements.txt); a new model bumps EventMatcher.version
~/news-eval/venv/bin/python script/training/train_embedding.py OUT --pairs DIR/pairs.csv DIR/gdelt-negatives.csv --exclude-headlines FILE --holdout holdout.json --tune-corpus corpus.json # Local only (#628): contrastive fine-tuning of the sentence encoder on same / different pairs, exported like convert_minilm.py; NEWS_SEMANTIC_VETO and NEWS_SEMANTIC_RESCUE override the 0.55 veto and 0.70 rescue for --library-holdout, --event-corpus and --matcher-regressions
~/news-eval/venv/bin/python script/training/pretrain_pairs.py wcep DIR # Local only (#623): WCEP-10 event clusters as pretraining pairs (pairs inside a cluster are one story, same or related; name-sharing pairs across clusters are different, #627), DIR/wcep-pairs.csv; `--prefix` before the source adds the #626 words, off by default
~/news-eval/venv/bin/python script/training/pretrain_pairs.py gdelt DIR --from 20260924 --to 20261023 # Local only (#623): GDELT 2.1 hard negatives with real headlines (same actors and country, different event, 1–7 days apart: different or related, #627), DIR/gdelt-negatives.csv; files cached under DIR/gdelt
~/news-eval/venv/bin/python script/training/pretrain_pairs.py semeval DIR [--cached-only] # Local only (#623): SemEval-2022 Task 8 English pairs by human similarity (1 → one story, 3–4 → different), pages from the Internet Archive cached under DIR/semeval, DIR/semeval-pairs.csv; --cached-only writes what a stopped fetch cached and fetches nothing
python3 script/training/pretrain_pairs.py --self-check # Synthetic clusters and events through the builders, no downloads; runs in ./test.sh
~/news-eval/venv/bin/python script/training/convert_minilm.py OUT [--source hub|shipped] # Local only (#555): rebuild minilm.mlpackage from the pinned Hub revision or the shipped weights and report its parity with the shipped model; a new model bumps SentenceEmbedder.modelVersion
~/news-eval/venv/bin/python script/training/convert_minilm.py --self-check # A tiny random encoder through the fixed-length multifunction export (#554), no downloads
~/news-eval/venv/bin/python script/training/compress_models.py OUT --pair-state STATE.pt --mode fp16|int8|pal8 # Local only (#554): both models as fixed-length functions, weights compressed with coremltools.optimize.coreml, with their parity against the shipped models; --self-check needs no downloads
NEWS_EVENT_OUTPUT=DIR ./test.sh --embedding-vectors # Writes the sentence embedding of every authored-corpus article to DIR/embedding-vectors.json (#540); compare two dumps vector by vector before a SentenceEmbedder change ships (one directory per revision; an existing dump is never overwritten)
./test.sh --compute-plan # Core ML placement of both shipped models (#554): MLComputePlan cost share on Neural Engine, GPU and CPU per function under .all and .cpuAndNeuralEngine, the operations that cannot run on the Neural Engine, and load, per-text, per-pair and batch latency under each compute unit; NEWS_EMBEDDING_MODEL_PATH and NEWS_PAIR_MODEL_PATH measure candidates
python3 script/evaluation/sample_pairs.py EXPORT match 0 0 --labels labels-match.txt --snapshot copy.sqlite3 --out reviewed-pairs.csv --holdout holdout.json # Local (#625, #627): a reviewed sample's labels as weight-5 three-way training rows (different 0, related 1, same 2); rows naming a library-holdout article are left out; `--prefix` adds the #626 words, off by default
NEWS_LIVE_CATALOG_CHECK=1 ./test.sh # Optional: fetch every catalog feed through the app's own networking and parsers
./test.sh --catalog-reader-access # Opt-in, live: open each catalog feed's newest stories in the app's reader extraction (NEWS_CATALOG_FEEDS=id,… NEWS_CATALOG_SAMPLE=N)
./build_release.sh                # Optimized arm64 verification bundle
```

Further opt-in variables: `NEWS_SNAPSHOT_DB=path` makes the default run open a copied library after the suite and check that it lists stories; `NEWS_OVERVIEWS_MAX_EVENTS=N` (default 120) and `NEWS_OVERVIEWS_RUN_NAME=name` bound and label an `--overviews-live` run; `NEWS_WORLD_TENSION_INTERACTIVE=1` keeps the World Tension harness window open for ten minutes; `NEWS_SETTLE_SECONDS=N` (default 5) is the wait before `launch_baseline.sh` samples settled memory.

SwiftSoup and FeedKit are resolved by `Package.swift` and the committed `Package.resolved`. Native app and QA scripts source `script/swiftpm_dependencies.sh`, which builds one static dependency archive with SwiftPM and supplies its module and link paths to the existing compiler commands. No separate dependency installation or system library search path is needed. Bundles include `Sources/ThirdPartyNotices.txt`.

Releases: pushing a `vX.Y.Z` tag runs `.github/workflows/release.yml`, which builds with `build_release.sh`, checks the bundle version equals the tag and publishes the arm64 zip with its sha256 as a GitHub release (ad-hoc signed, no notarization). Tag only after the version stamping (#566) is on `main`.

`make build` and `make release` compile SwiftPM executables; `make app` and `make run` use the app-bundle workflow. Packaging helpers live under `script/distribution/` and are inactive in development CI. Do not run notarization or build Intel slices in the current scope.

Add deterministic regressions for changed parsing, classification, persistence, migrations, security boundaries and state transitions. Synchronize async tests on observable state rather than short sleeps; model-dependent tests must use deterministic fallbacks. Preserve tests rather than removing failing coverage. Keep tests isolated from real user settings, databases and logs. Create temporary defaults with `testDefaultsSuite` and remove them with `removeTestDefaults` from `Tests/TestDefaults.swift`: a plain suite name leaves a plist in `~/Library/Preferences` that cfprefsd rewrites after deletion.

The overview and importance reviewer sheets bind labels to the exact displayed inputs. Only `label`, `note` and row order may change. If a source capture or an input column changes, the report command rejects the sheet before writing aggregates. Keep the old capture and labels; prepare and review the changed capture in a new private directory. Sheets are never overwritten by the preparation command.

HTTP mock fixtures use the test client's controlled DNS results as well as `URLProtocol` responses; they must not depend on public DNS availability. Production clients keep the native resolver, and real socket/proxy tests retain their connection and pinning checks.

For app changes, build in an isolated staging directory: `build.sh` replaces `News.app` in its working directory. A successful build is not evidence of installation, launch or live network behavior; report those checks separately. Validate `build_release.sh` and affected packaging scripts for distribution changes, without invoking notarization in development. Documentation-only edits require link/path and consistency checks, not an unrelated app rebuild.

The native performance script requires an active Mac desktop. It compiles the production views with a separate test entry point, uses temporary SQLite/defaults and mocked feeds, and writes JSON plus a first-card PNG to the printed directory (or the directory supplied as its first argument). Its sampled bitmap timing is an upper bound on rendering readiness, not cold app launch; process memory includes fixture setup and the on-device Vision probe. It neither installs a bundle nor runs the production app delegate. The opt-in `NEWS_READING_FULL_APP=1` mode reuses `build.sh` and the production entitlements under `com.marspater.news.workloadcheck`; its cache and WebKit storage are isolated from the installed app. It invokes the same `CacheManager` setup as the app delegate, reads 20 live stories twice, generates/persists/captures ten deterministic overviews with three controlled source inputs, and loads five selected publisher pages through `ArticleWebView`. Timings are workload observations, not CI thresholds; app footprint excludes WebKit auxiliary processes and memory pressure. Failed documents, images or Web loads fail the run. Its report and overview capture are exported from the sandbox through stdout into the results directory.

`script/launch_baseline.sh` also needs an active desktop. It builds the production bundle under the identifier `com.marspater.news.launchcheck`, so its sandbox container is separate from the installed app, seeds that container with 10,000 stories and opens the app several times. Its feed points at a reserved `.invalid` host. The first-card time comes from a one-time `FirstCard` signpost and log line in the app.

Before publication, fetch `origin/main`, review the diff and run checks affected by the change. Never report a check as passing unless it completed successfully. Record noteworthy behavior changes as a changelog fragment, `CHANGELOG.d/<issue>.md` with `- ` bullet lines (see [CHANGELOG.d/README.md](CHANGELOG.d/README.md)); never edit `CHANGELOG.md` in a feature PR, so parallel and stacked PRs do not conflict there. `python3 script/changelog_fold.py` folds the fragments into [CHANGELOG.md](CHANGELOG.md) before a tag. Dated evidence belongs in `docs/audits/`.

The VoiceOver harness is parked (#268) and is not part of release verification; the notes below apply when it is resumed. It builds a separate `com.marspater.news.voiceoverqa` bundle and uses temporary SQLite and preferences. Its view environment supplies an in-memory image; the installed app and its protected image loader remain unchanged. Output goes to the printed temporary directory or `NEWS_VOICEOVER_OUTPUT`. Compilation has a 300-second deadline and automated runs a 120-second process-group deadline; commands and AX inspection have shorter internal deadlines. Missing Accessibility access or unsupported announcement observation is a reported prerequisite failure, not a crash or passing check.

`--live` checks rendered AX nodes while scrolling, invokes card actions and verifies SQLite state, opens/dismisses a real citation and observes the production feed-buffer notification after inserting three fixture stories. Missing numeric heading metadata is reported as unverified and requires the manual rotor pass. AX tree order and observed notifications do not establish VoiceOver cursor order, rotor traversal, pronunciation or speech. Use `--manual`, enable VoiceOver yourself, and record that separate pass in #268. The Fixtures menu switches between Feed, Source Reader and Event Overview. On Feed, Queue New Stories holds the list through its production navigation command and inserts three stories. Close the fixture window to clean up. The harness does not change system accessibility settings.

## Pair review protocol (#551)

Pair decisions are reviewed on a copy of a library, never the live file. `--review-pairs` exports every stored decision with both headlines; the reviewer labels a sample and the numbers go into a dated file under `docs/audits/`. Mars delegates bulk review to Claude and spot-checks; the audit says who labelled.

- **Labels.** `same` (one occurrence reported twice: paraphrases, updates, a toll that changed, a verbal reaction or direct consequence folded into its event), `related` (another act of the same story: the arrest after the fire, the condemnation after the attack, the protest after the vote), `different` (another story, or the same kind of occurrence elsewhere or at another time).
- **Tie rules.** A headline that names two acts follows the act it leads with. A live blog or explainer joins the event it covers. When the two headlines could be one occurrence or two and the leads do not settle it, the label is `different`: a missed link costs less than a wrong card.
- **Samples.** 200 `match` rows with reason `match`, 100 with reason `pairModel`, every `related-act` row, and 100 `vetoed` rows, drawn in a fixed pseudo-random order (sort by the SHA-256 of the two ids) so a rerun draws the same rows. A match or pair-model row labelled `different` is a false merge; the ceiling is 2% per sample.
- **Disagreements.** A spot-check that overturns a label is recorded in the audit with both labels and the reason; the overturned label is replaced and the sample is re-counted. Three overturned labels in twenty mean the whole sample is relabelled.
- **Receipts.** The CSV and the labelled copy stay outside the repository (`0700` directory, `0600` files); the audit records the copy's date, article count, matcher version and the SHA-256 of the labelled file.
- **Reviewed mistakes (#625).** Every labelled review sample (`sample_pairs.py --labels`) joins the training set at weight 5, and `--export-pairs` adds same-day negatives at weight 2 (two reports sharing a specific anchor within 36 h in different events of two or more members and different stories, with a hard conflict or a cosine below 0.58, #627); mined positives leave out links the pair model alone made; after each retrain a fresh sample of the new model's confirmations is labelled and joins the next round. The library holdout never enters training.
- **Reader verdicts (#552).** `--library-holdout` reads the copy's `event_inclusions` and `event_exclusions` before it clears the corrections and re-clusters: every "Same Event" pair must end up linked and every "Not the Same Event" pair apart, or the run prints the violated pairs and fails. No matcher or model change ships while a recorded verdict is violated; `--export-pairs` also turns the verdicts into weight-5 training rows.
- **Library holdout (#579).** `--review-pairs --holdout-candidates` draws the hard pairs of a library copy (borderline decisions scored ≥ 0.6, singletons sharing a specific anchor and a keyword with an event member within 36 h, pairs of active events sharing two terms); they are labelled the same way and saved as a JSON array of `{"a", "b", "label"}` beside the copy. `--library-holdout` re-clusters a temporary copy from scratch and reports two views (#627): strict event (pairs in one event: `same` is right, `related` and `different` are wrong, `different` also counted alone; recall on `same`) and story level (pairs whose events share a `story_id`: `same` and `related` are right, only `different` is a false merge; recall on `same` and `related`), and the share of recent stories in a multi-publisher event. A matcher or pair-model change ships when, against the shipped model, strict `same` does not fall and strict `different` does not rise, story-level `different` falls and story recall rises, and the tune replay and the authored corpus are unchanged (Mars, #574); the result and the file's SHA-256 go into the slice's PR. The old 49-article holdout stays sealed.

## Remove legacy test preferences (#311)

Older test runs left migration-test preferences behind. The following one-time cleanup previews only files named `com.marspater.news.test.<UUID>.plist` in the user and app-container preferences directories. It never selects `com.marspater.news.plist` or other settings. Run it with the tests stopped; set `delete = True` only after reviewing the preview to remove those test files.

```sh
python3 - <<'PY'
from pathlib import Path
import re

delete = False
pattern = re.compile(r"com\.marspater\.news\.test\.[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\.plist")
directories = [
    Path.home() / "Library/Preferences",
    Path.home() / "Library/Containers/com.marspater.news/Data/Library/Preferences",
]
for directory in directories:
    if not directory.is_dir():
        continue
    for path in sorted(directory.iterdir()):
        if pattern.fullmatch(path.name) and path.is_file() and not path.is_symlink():
            print(path)
            if delete:
                path.unlink()
PY
```

## Story experience tracking

Use the [News · Story experience project](https://github.com/users/marspater/projects/2) and epics #571–#577 (the [24 October 2026 plan](docs/plans/2026-10-24-future-development.md); program issue #90 is closed) for this work. Board status runs Backlog, Ready, In progress, In review, Done, with Priority P0–P2. Before starting a slice, read its task acceptance criteria and dependencies. Update the relevant issue checklists and log implementation scope, completed checks, remaining gaps, and commit/PR state after each coherent slice.

Private fingerprint capture and review use `FeedCatalog.supportedLanguages`, including optional extra feed lists and historical captures. Keep existing capture files intact; parked-language observations do not enter the current release denominator. Tuning is the default; `--corpus-review --corpus-holdout` explicitly unseals the fingerprint acceptance split. Use `--corpus-readiness DIR --corpus-holdout` to count support while leaving outcomes sealed. Its zero-false-merge sufficiency flag is conditional, not observed acceptance.

Keep uncommitted implementation In progress, linked PR work In review, and reserve Done for merged implementation or completed non-code deliverables with recorded evidence. Use `Refs #N` for partial coverage and `Fixes #N` only when the PR completes that issue. Keep the image HTTP-cache task (#161) separate from identity and reader/media work. Do not mark a phase complete from a partial implementation or a focused test pass.

## Security checks

[The Security workflow](.github/workflows/security.yml) is the canonical advanced CodeQL configuration for Swift and GitHub Actions. Default CodeQL setup must remain disabled because GitHub rejects advanced uploads while it is enabled. Swift analysis builds the complete SwiftPM app target without optimization on the macOS 26 Apple Silicon runner with Xcode 26.3. Compiler subprocess sandboxing is disabled only for extraction; app sandbox entitlements are unchanged. Normal CI verifies arm64 bundles and Swift formatting on Xcode 27, and runs the test suite on the macOS 26 runner with Xcode 26.6 (CircleCI and Codemagic test on macOS 27 with Xcode 27). Secret scanning and deterministic security regressions remain separate jobs.

## Codemagic macOS runner

[`codemagic.yaml`](codemagic.yaml) defines `news-arm64-verification`: Apple Silicon M2, pinned Xcode 27.0 and macOS 15 deployment target. It runs the existing full offline regressions, verifies the SwiftPM `News` target, builds with `build_release.sh`, checks arm64, signature, Hardened Runtime and App Sandbox, then retains the app ZIP, SHA-256 checksum and diagnostic logs. No signing credentials are required for this ad-hoc verification artifact.

Connect `marspater/NewsApp-macOS` using the Codemagic GitHub App, select YAML configuration and enable the repository webhook. Start `news-arm64-verification` manually on the configuration branch for the first run. Thereafter, pushes to `main` and pull requests targeting `main` trigger the workflow (documentation-only changes are skipped); superseded builds are cancelled. GitHub Checks reporting depends on the GitHub App integration. Enable a required Codemagic check only after its first successful hosted run.

All three providers stay (Mars, 26 Oct 2026): GitHub Actions is the pipeline of record, CircleCI adds test-impact analysis, and Codemagic runs the full suite, the format check and the release build. Codemagic is an additional build runner; the existing GitHub Security workflow remains responsible for CodeQL, dependency review and secret scanning. The artifact is ad-hoc signed, not notarized or automatically published to testers or GitHub Releases. Live publisher/corpus collection and parked VoiceOver checks are not run. Configuration validation and local script execution do not establish a successful Codemagic-hosted run.

References: [Codemagic YAML](https://docs.codemagic.io/yaml-basic-configuration/yaml-getting-started/), [Xcode 27.0 runner](https://docs.codemagic.io/specs-macos/xcode-27-0/), [GitHub Checks integration](https://docs.codemagic.io/yaml-notification/github-checks/).
