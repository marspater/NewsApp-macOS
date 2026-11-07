# Splitting Tests/NewsTests.swift (#570)

Date: 7 November 2026. Base: main at 07de3cf, Apple Silicon laptop; timings are from one machine, with other sessions possibly running.

## Result

`Tests/NewsTests.swift` no longer has a test list. It holds the CLI modes and the corpus check (3,620 lines, down from 31,039); each domain has its own atom, and shared helpers live in `Tests/NewsTestSupport.swift`, which is not an atom. Test bodies moved unchanged.

## Counts

212 registered names before and after, no duplicates, and the name set is identical.

| Atom | Tests |
|---|---|
| IntelligenceTests | 37 |
| LifecycleTests | 31 |
| ClusteringTests | 29 |
| FeedParsingTests | 23 |
| ReaderTests | 19 |
| UserInterfaceTests | 19 |
| StorageTests | 16 |
| DiagnosticsTests | 14 |
| NetworkingTests | 11 |
| MigrationTests | 8 |
| SocketTests | 4 |
| ActiveWorkCancellationTests | 1 |
| Total | 212 |

`EpicNE2ETests` was a 213th entry in the old list; it is now its own atom and keeps its own 71 checks. Atoms: 23 before, 36 after. Update (#1070): the `MigrationTests` and `FeedParsingTests` atoms moved to the native `NewsTests` bundle (`Tests/Native/MigrationSuite.swift`, `FeedParsingSuite.swift`) and their runner copies are gone, so the runner has 34 atoms. The 12 tests the CLI modes still call (`--story-regressions`, `--fts-refresh-regression`) stay in `Tests/CLIModeRegressionTests.swift`, which is not an atom.

## Line check

Every line of the original file (at 98eee71) is present in `NewsTests.swift` or a file added by the stack, except 36 lines, all accounted for:

- the shard code: `slowTests`, `socketTests`, `shardIncludes`, `validateShard`, `runSharded` (replaced by `runSuite`, which keeps the timing);
- the empty list's `print`, entries and call in `runTests`;
- `private` on `extractDialogText`, which two atoms now use;
- one registry line whose trailing comma the formatter removed.

Added code: `defaultFixtureHost`, `defaultFixtureRoot`, the atom entry points and each atom's list. Each atom's list is the old entries, in the old order.

## Lanes

| Before | After |
|---|---|
| `NEWS_TEST_SHARD=sockets` | `SocketTests`: one process, the four tests in order under `rerunningLoopbackFlake` |
| `NEWS_TEST_SHARD=slow` | `ActiveWorkCancellationTests` |
| `NEWS_TEST_SHARD=i/n`, 4 processes | ten domain atoms, plus `EpicNE2ETests` |

`NEWS_TEST_SHARD` and `NEWS_TEST_SHARDS` are gone. `NEWS_TEST_JOBS` stays, default 6 capped at the core count. The pool starts the slow and socket atoms first and then the other atoms by measured time, as listed in `test.sh`.

Domain atoms skip targeted modes (arguments and no `NEWS_TEST_ATOM`); `script/check_test_registry.sh` fails if one loses that guard. `./test.sh --parsing-regressions` prints the same output before and after: "SwiftSoup / FeedKit parsing regressions passed".

## Timing

Plain `NEWS_TEST_FORCE=1 NEWS_TEST_TIMING=1 ./test.sh`, no rebuild, two runs each; wall time includes the Python self-checks.

| Tree | Wall | Job-seconds | Longest jobs |
|---|---|---|---|
| main 07de3cf | 1:05, 1:04 | 267 | 54, 46, 46 |
| this split alone | 1:10, 1:11 | 316, 322 | 48-50 Clustering, 46-48 ActiveWorkCancellation |
| this split merged with main aef6850 (#1088, #1090, #1101) | 0:26, 0:27 | 63, 65 | 13 ActiveWorkCancellation, 11 UserInterface, 8-9 Storage or Clustering |

The split alone is about 6 s slower: more processes each load the Core ML model on first use. #1088's `--warm-models` step removes that cost, so #570's "wall time not worse" holds only once #1088 is merged. #1088 alone on main was not measured here, so the saving in the third row is not attributed between the two changes. A trial merge of #1088 alone measured 0:46 and 117 job-seconds earlier the same day; the third row is the final merged tree, and machine load between the two was not controlled.

The corpus validation (`StoryCorpus.run(evaluate:)`) used to run in each of the six `NewsTests` processes and now runs once, in the `NewsTests` atom (11-12 s for the atom alone without #1088). Do not count that saving twice with #1088.

## Commit-hook selection

`script/changed_atoms.sh` maps a changed `Sources/X.swift` to atoms whose file names `X`. Bodies moved verbatim, so each moved test's file names the types it exercises; a helper's types are named in `NewsTestSupport.swift`, which is not an atom. A change to that file selects every atom (36 of 36 at the split, checked; 34 atoms after #1070). Of 133 `Sources/` files, 45 name no atom and fall back to every atom, the same 45 count as before the split.
