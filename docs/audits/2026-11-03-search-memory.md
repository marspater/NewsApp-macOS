# Memory over repeated searches — 3 November 2026

Refs #708. Base: `aa2d0f8` (#958, latency slice) and `92c5468` (`origin/main`) for comparison. Apple M5 / 24 GiB (Mac17,3), macOS 27.2 (26B123), Xcode 27.0, Swift 6.4; optimized arm64 (`-O`). The Mac carried other load during every run (load average 6–18, mostly a Safari WebContent process at 100% CPU); the orchestrating agent paused its own builds and tests.

## Method

`./test.sh --search-memory` (`runSearchMemory` in `Tests/NewsTests.swift`). One process seeds a temporary 5,000-story library and embeds every story with the shipped sentence model, then runs searches the way a list's search field does (`ArticleListView.performQueryReload`): the text embedded on device, the first page of 201, the muted count and the masthead totals under a topic mute, the next page by cursor, and for every tenth search a spelling suggestion for a misspelled query (which runs one more search). Every search has new text, as typing gives, so each one embeds and binds a new query vector. A search lists 760 stories on average.

After 50 warm-up searches (model load, SQLite page cache, spelling vocabulary), the task's physical footprint (`TASK_VM_INFO.phys_footprint`, the measure Activity Monitor and jetsam use) is read after every block of 50 searches. `NEWS_SEARCH_MEMORY_BLOCKS` sets the number of blocks (default 10, so 500 measured searches); the run fails when the last sample exceeds the first by more than `NEWS_SEARCH_MEMORY_LIMIT_MB` (default 6).

## Results

Footprint in MiB after the warm-up and after each block of 50 searches ([raw reports](../benchmarks/2026-11-03-search-memory.json)):

| Run | Samples | Growth |
| --- | --- | ---: |
| #958, 500 searches | 51.1, 51.4, 51.5, 51.5, 51.5, 52.5, 52.5, 52.5, 52.5, 52.5, 52.5 | 1.4 |
| #958, 1,500 searches | 49.9, 49.5 (×8), 49.6 (×9), 52.5, 52.6 (×12) | 2.7 |
| `origin/main`, 500 searches | 49.0, 49.1 (×6), 49.0, 50.0, 52.8, 52.8 | 3.8 |
| smoke, 100 searches (#958) | 51.8, 51.9, 52.0 | 0.2 |

Footprint does not grow with the number of searches. Each run shows one or two steps (about 1 MiB and about 3 MiB) at a varying point, after which it stays level: over 1,500 searches the footprint was flat for 850 searches, stepped once by 2.9 MiB, and was flat for the next 600. That is a one-time allocation reaching its working size (an allocator region or SQLite's page cache), not a leak; a leak would add the same amount every block. No fix was needed.

A full search round (embed, two pages and two counts) took a median of 67 ms (p95 114 ms) on #958 and 119 ms (p95 247 ms) on `origin/main` in back-to-back runs under similar load; the 1,500-search run took 58 ms (p95 91 ms).

The 6 MiB limit sits above the largest one-time step seen (3.8 MiB) and still detects a leak of 12 KiB a search over 500 searches, far less than one retained model output (128 × 384 floats, 192 KiB) or one page of 201 stories.

## Not measured

- The production app with its views, images and event summaries: this is the storage and model path a search takes, in a test process. Instruments was not run.
- Libraries larger than 5,000 stories.
