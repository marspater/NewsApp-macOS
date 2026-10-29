# Board status and projections — 28 October 2026

**Status:** status pass requested by Mars on 28 October 2026. Baseline `origin/main` `69b1057` (matcher v12, schema v26). Repository-side changes are applied. Board-only fields (Status, Start date, Target date) are applied by a one-off `gh` script run on a Mac, because cloud sessions cannot reach the Projects API.

**Applied on GitHub, 28 October:**
- Closed the 12 milestones whose issues are all done: A–J, N and R. L was already closed.
- Added projected due dates to open milestones: Q 30 Oct, M 4 Nov, T 5 Nov, K 9 Nov, P 11 Nov, O 17 Nov, U 25 Nov, V 30 Nov, W 14 Dec. S and X are parked and get no dates.
- Added 24 blocked-by links. Most come from the 28 October roadmap: U2 ← #628, #540; V3 ← #565, #711; W1 ← #564; W2 and W3 ← #581, #673; W4 ← #671, #716; X ← every open v2 epic and U, V, W; X2–X4 ← X1. One is stated in #691's body: K5 ← M (#574).
- Posted status comments on #566, #568, #569, #570, #574, #576, #584, #669, #711 and #719.

## 1. State

There are 264 issues: 195 closed and 69 open. Of the 438 PRs, 21 are open. Main is green on GitHub Actions (CI, Security) and CircleCI.

- **Done:** programs A–J, L, N and R.
- **Waiting on merge:** M and T are fully implemented. 20 of the 21 open PRs form one linear stack, #617 → #701, for epic #574. #705 (Epic T) branches off #693 in the middle of it. #617 is mergeable and clean, and every PR's CI is green. Review and merge throughput is the constraint, not implementation.
- **Code merged, verification pending:** #566 and #568. #634 landed their code. Their acceptance needs a Mac, CI minutes and the first tag.
- **Unblocked since the last pass:** #584, after #687 merged on 27 October. #570, after #549 closed.
- **Drift again:** #569. README says matcher v11 but main is v12. ARCHITECTURE says SQLite v25 but main is v26. CONTRIBUTING points to epics #571–#577.
- **Not started:** O, U, V and W, apart from U1, which is ready now.
- **Parked:** S, X, #264, #268 and the two ideas.

## 2. Issues, relationships and board fields

Status follows CONTRIBUTING: open PR → In review, unblocked and next → Ready, blocked or later → Backlog. The board has no Blocked column. Closed issues → Done, with their created and closed days as start and target, so the roadmap shows history. Dates are month-day, 2026.

**M · Model infrastructure, epic #574** — In review, 10-24 → 11-04, blocked by: —

| Issue | Status | PR | Blocked by (open) | Start → target |
|---|---|---|---|---|
| #582 Fragment merge and pair-model gates: model inside mergeFra… | In review | #618 | #583 | 10-24 → 10-29 |
| #583 Same-publisher duplicate items alias to one story | In review | #617 | — | 10-24 → 10-29 |
| #623 Pretraining pairs from WCEP-10, GDELT and SemEval-2022 (p… | In review | #633 | #581 | 10-24 → 10-29 |
| #552 Reader verdicts as training rows and as the gate | In review | #638 | #624 | 10-24 → 10-30 |
| #624 Two-stage pair-model training with weighted rows; retraine… | In review | #637 | #623 | 10-24 → 10-30 |
| #625 Hard negatives from the model's reviewed mistakes, iterated | In review | #639 | #552 | 10-24 → 10-30 |
| #626 Publisher and time gap as input tokens for the pair model | In review | #640 | #625 | 10-24 → 10-30 |
| #540 Embedding throughput: pointer-based pooling and batched in… | In review | #644 | #555 | 10-25 → 11-02 |
| #555 Reproducible models and tracked training pins | In review | #643 | #626 | 10-25 → 11-02 |
| #581 Story layer: one card per story across related acts and fr… | In review | #698, #693, #631 | #582 | 10-24 → 11-02 |
| #688 Same-publisher series and calendar-date guard (matcher v13) | In review | #689 | #540 | 10-27 → 11-02 |
| #628 News-tuned bi-encoder for the cosine (MiniLM model version… | In review | #697 | — | 10-27 → 11-03 |
| #683 Remove the unused importance judges from the app target (f… | In review | #694 | #581 | 10-27 → 11-03 |
| #554 Model size and Neural Engine placement: int8 palettization… | In review | #700, #696 | #628 | 10-27 → 11-04 |
| #627 Three-way head: same / related act / different, feeding th… | In review | #699, #695 | #626, #683, #628 | 10-27 → 11-04 |
| #629 Bounded in-app calibration of the pair model from reader v… | In review | #701 | #552, #554 | 10-27 → 11-04 |

**T · Story Overview, epic #669** — In review, 10-27 → 11-05, blocked by: #581

| Issue | Status | PR | Blocked by (open) | Start → target |
|---|---|---|---|---|
| #670 Conditional Industry Impact section in Story Overview | In review | #705 | — | 10-27 → 11-05 |
| #671 Connected timeline of events in Story Overview | In review | #705 | — | 10-27 → 11-05 |
| #672 Highlight separation and hierarchy in Story Overview | In review | #705 | — | 10-27 → 11-05 |
| #673 Distinct Perspectives design in Story Overview | In review | #705 | — | 10-27 → 11-05 |

**P · Release and hygiene, epic #577** — In progress, 10-24 → 11-11, blocked by: —

| Issue | Status | PR | Blocked by (open) | Start → target |
|---|---|---|---|---|
| #568 CI consolidation: honest format check, SwiftPM cache, one … | In review | #634 (merged) | — | 10-24 → 10-30 |
| #569 Docs truth: README, ARCHITECTURE, CONTRIBUTING, PRIVACY | Ready | — | — | 11-04 → 11-05 |
| #566 Version from git tags in both build scripts | In review | #634 (merged) | — | 10-24 → 11-06 |
| #567 First GitHub release: 2.0.0 | Ready | — | #566 | 11-05 → 11-06 |
| #570 Test harness records all failures; split the 18,697-line t… | Ready | — | — | 11-05 → 11-10 |
| #661 Update Xcode developer documentation (DocC) | Ready | — | — | 11-09 → 11-11 |

**Q · Interaction polish, epic #607** — In progress, 10-24 → 10-30, blocked by: —

| Issue | Status | PR | Blocked by (open) | Start → target |
|---|---|---|---|---|
| #584 Dock badge counts the Briefing and breaking stories, not e… | Ready | — | — | 10-29 → 10-30 |

**K · Performance, epic #572** — Ready, 10-29 → 11-09, blocked by: —

| Issue | Status | PR | Blocked by (open) | Start → target |
|---|---|---|---|---|
| #692 Active-work cancellation test fails under CPU load (WAL-sp… | Ready | — | — | 10-29 → 10-30 |
| #591 Card images ready before they scroll into view | Ready | — | — | 10-30 → 11-03 |
| #691 Full re-clustering cost on a real library: measure, split … | Backlog | — | #574 | 11-05 → 11-06 |
| #543 Re-baseline performance budgets after the robustness and p… | Backlog | — | #540 | 11-06 → 11-09 |

**O · First run and data, epic #576** — Backlog, 11-10 → 11-17, blocked by: #572

| Issue | Status | PR | Blocked by (open) | Start → target |
|---|---|---|---|---|
| #564 Diagnostics export and OSLog category cleanup | Backlog | — | — | 11-10 → 11-10 |
| #565 Export saved stories and history | Backlog | — | — | 11-11 → 11-11 |
| #562 Onboarding and notification-permission timing | Backlog | — | — | 11-12 → 11-16 |
| #563 Library backup and restore | Backlog | — | — | 11-13 → 11-17 |

**U · Discovery and search, epic #706** — Ready, 11-04 → 11-25, blocked by: —

| Issue | Status | PR | Blocked by (open) | Start → target |
|---|---|---|---|---|
| #707 macOS Quick Look (Spacebar Peek) in Story Lists | Ready | — | — | 11-04 → 11-05 |
| #708 Hybrid Semantic & Natural Language Search (FTS5 + Vector R… | Backlog | — | #628, #540 | 11-18 → 11-20 |
| #709 Dynamic Smart Binders (Compound Topic Rules) | Backlog | — | — | 11-23 → 11-25 |

**V · Active reading, epic #710** — Backlog, 11-18 → 11-30, blocked by: —

| Issue | Status | PR | Blocked by (open) | Start → target |
|---|---|---|---|---|
| #711 Local Private Annotations and User Notes | Backlog | — | — | 11-18 → 11-20 |
| #712 Story Evolution and Live Publisher Diffing | Backlog | — | — | 11-23 → 11-25 |
| #713 Curated Knowledge Export (Obsidian, Apple Notes, Markdown,… | Backlog | — | #565, #711 | 11-26 → 11-30 |

**W · Editorial intelligence, epic #714** — Backlog, 11-11 → 12-14, blocked by: —

| Issue | Status | PR | Blocked by (open) | Start → target |
|---|---|---|---|---|
| #715 Publisher Health and Extraction Quality Inspector | Backlog | — | #564 | 11-11 → 11-12 |
| #716 On-Device Entity Dossiers and Context Cards | Backlog | — | #581, #673 | 12-01 → 12-07 |
| #717 Multi-Perspective Dual-Reader (Side-by-Side Coverage Compa… | Backlog | — | #581, #673 | 12-03 → 12-07 |
| #718 Interactive Global Hotspot Map (World Tension / Internatio… | Backlog | — | #671, #716 | 12-08 → 12-14 |

**S · App Store monetization (parked), epic #651** — Backlog, —, blocked by: #576

| Issue | Status | PR | Blocked by (open) | Start → target |
|---|---|---|---|---|
| #652 Define premium feature matrix and App Store product catalog | Backlog | — | — | — |
| #653 Implement the native StoreKit 2 commerce service | Backlog | — | #652 | — |
| #654 Build entitlement manager and premium feature gates | Backlog | — | #652 | — |
| #655 Build native paywall and purchase settings | Backlog | — | #653, #654 | — |
| #656 Configure App Store products and verify purchase lifecycle | Backlog | — | #652, #655 | — |

**X · Widgets (parked, gated), epic #719** — Backlog, —, blocked by: #572, #574, #576, #577, #607, #669, #706, #710, #714

| Issue | Status | PR | Blocked by (open) | Start → target |
|---|---|---|---|---|
| #720 Shared Database Snapshot & App Group Container for Widgets | Backlog | — | — | — |
| #721 Situation Board Hero Desktop Widget (Medium & Large) | Backlog | — | #720 | — |
| #722 World Tension Gauge Widget (Small & Medium) | Backlog | — | #720 | — |
| #723 Breaking and Top Stories List Widget (Medium & Large) | Backlog | — | #720 | — |

**Outside the epics**

| Issue | Status | Note |
|---|---|---|
| #264 Parked: event matching for languages without a word-class … | Backlog | parked; sub-issue of closed phase D (#94) |
| #268 Parked: live VoiceOver pass | Backlog | parked; sub-issue of closed phase H (#98) |
| #725 Idea: Glanceable Menu Bar Popover (Companion Mode) | Backlog | idea, parked; no milestone, no links |
| #726 Idea: Native On-Device Spoken Edition (AVSpeechSynthesizer) | Backlog | idea, parked; no milestone, no links |

## 3. Production path and the PR stack

| Order | PR | Issue | Kind |
|---|---|---|---|
| 1 | #617 | #583 | production |
| 2 | #618 | #582 | experiment, nothing adopted (34 lines in `Sources`) |
| 3 | #631 | #581 | **production: story layer, schema v27** |
| 4–7 | #633, #637, #638, #639 | #623, #624, #552, #625 | training and evaluation tooling, no app change |
| 8 | #640 | #626 | experiment, not adopted; adds `EventMatchPolicy.pairModelPrefix` to the app |
| 9 | #643 | #555 | tooling, model metadata |
| 10 | #644 | #540 | production: embedding throughput |
| 11 | #689 | #688 | production: matcher v13 |
| 12 | #693 | #581 | **production: closes #581; #705 (T) is based here** |
| 13 | #694 | #683 | production: dead code removed |
| 14 | #695 | #627 | tooling |
| 15 | #696 | #554 | production: MiniLM on the Neural Engine |
| 16 | #697 | #628 | experiment, not adopted (trainer only) |
| 17 | #698 | #581 | tests |
| 18 | #699 | #627 | experiment, shipped weights kept; adds the three-way code path to the app |
| 19 | #700 | #554 | production: pair model on the Neural Engine |
| 20 | #701 | #629 | production, dormant below 50 verdicts |

The critical path is #581 → T (#669) → W2 and W3 (#716, #717). Its closer #693 sits on seven tooling and experiment PRs (#633–#643). Nothing in them is pending: #640 says "Draft until … measured", but its body records the measurement and "Not adopted". Even so, a review change on any of them holds back the story layer, T and two W items. Several issue-level blocked-by links between #623 and #688 record stack order, not logic. For example, #623 ← #581 means "#633 sits on #631", while #581 itself closes later, with #693.

## 4. Experiments and ideas: offloading check

| Item | Where | Blocks production? |
|---|---|---|
| Ideas #725, #726 | `idea` and `parked` labels, no milestone, no parent, no links | No. Offloaded |
| S (#651–#656) | `parked`, own milestone, no dates; blocked by O | No. Production gates it, not the reverse |
| X (#719–#723) | `parked`, own milestone, no dates; now gated by links | No |
| #264, #268 | `parked`, sub-issues of closed phases D and H | No |
| M experiments #582, #626, #628, #627 | inside the production stack | **Yes, by stack position.** #626 and #627 also add non-adopted code paths to the app target |

## 5. Projections

Assumptions:
- About 4 stack merges per working day. Mars merged 24 PRs on 26 October.
- Effort as the plans define it: S ≤ 1 day, M 1–3 days, L > 3 days.
- One change at a time per shared file: `ArticleListView` (K #591 → U1), `NewsTests.swift` (the stack → #570) and the schema.
- Weekends are excluded. Every current blocked-by link is respected, including O ← K.

| Date | Milestone event |
|---|---|
| 30 Oct | Q done (#584); K6 flake (#692) fixed; #568 verified |
| 2 Nov | #581 closes with #693; the stack's tooling half is merged |
| 4 Nov | M done (stack tip #701) |
| 5 Nov | T done (#705 with Mars's captures and the 30-event check); docs truth (#569) |
| 6 Nov | **2.0.0 tagged** (#567, verifies #566 and N1's "works against the release") |
| 9 Nov | K done (K5 and K4 measured at the stack tip) |
| 11 Nov | P done (#570 test split, #661 DocC) |
| 17 Nov | O done → **v2 complete** |
| 25 Nov / 30 Nov | U / V done |
| 14 Dec | W done; earliest gate for X is 15 Dec (parked, no dates) |

## 6. Recommendations

1. **Restack the production path.** Rebase #693 and #705 directly onto #631. The path becomes #617 → #618 → #631 → #693 → #705, and the tooling and experiment PRs follow. #581 and T could then land around 30 October instead of 2–5 November. Mars's branches; not done here.
2. **Decide O ← K (#576).** The link has no recorded reason. K now waits on the M stack tip (#543, #691), so O cannot start before 10 November. O's files do not overlap K's. Dropping the link lets O run now, which pulls W1 and V3 forward about 10 days and v2 to about 10 November.
3. **Keep non-adopted experiments out of the app target.** #640 (`pairModelPrefix`) and #699 (three-way path) ship code for models that were measured and not adopted. That is the dead-flexibility pattern L6 (#549) removed. Land their tooling and keep the app path out, or behind the test build, until a model passes the gate.
4. **Separate merge order from dependency.** Record stack order in PR bodies (they already say "Stacked on …"), and keep blocked-by links for logical dependencies only. The board then shows real blockers.
5. **Cap stack depth.** A 20-PR stack turns one review comment into 19 rebases. Five or fewer, with a merge before the next slice, keeps the board honest.
6. **Release timing.** The 24 October plan said "release first", but 2.0.0 is still uncut and the update check (N1) cannot be verified without it. The projection cuts it after M and T (6 November), so the first release carries schema v27 and the story layer instead of needing a 2.0.1 a day later. If you would rather release now, main is green and #566 is the only gate.
7. **Schema reservation.** #631 takes v27, so V1's `user_notes` takes the next free version (v28 today). Corrected in the 28 October roadmap.

## 7. Board script

`sync_project_board.sh` is shared with Mars outside the repository; it is a one-off. Run it on a Mac:

1. `gh auth refresh -s project`
2. `bash sync_project_board.sh` prints every change without writing anything.
3. `bash sync_project_board.sh --apply` applies them. It:
   - sets Status per section 2,
   - creates the Start date and Target date fields if they are missing and fills them,
   - adds any open issue that is missing from the board,
   - reports open issues that are not in the plan.

Views cannot be edited through the API. Afterwards, set Roadmap → Date fields → Start date / Target date, and Markers → Milestone.
