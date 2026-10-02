# Optional finite briefing — 2 October 2026

Fixes #162.

The native Inbox sidebar includes Briefing. It selects at most ten unread, unmuted publications from the last 24 hours, excluding unknown and future dates. SQLite applies the exact publication window and unread/muting predicates before the 500-candidate limit. Selection first minimizes the combined source/category counts, then source count, then recency and stable ID. Source count is a diversity heuristic, not evidence of independent reporting.

Each window retains the selected publisher snapshots and order until New Briefing. Refresh, classification, event regrouping and read-state changes cannot replace them. Publications remain individually accessible in the existing cards and reader; event grouping is disabled for this mode. The footer shows read progress and completion, with a return to Today. Empty windows are shown separately from completion. Search and the rest of the archive keep their existing behavior, as does scheduled/manual refresh.

The session does not persist across closing the window; no durable state or migration is needed. New muting rules apply to the next selection. No cloud generation, new dependencies or rendering framework.

Regression `testFiniteBriefing` covers the cap, deterministic source/category mix, duplicate candidates, read/unknown/future dates, exact time boundaries, frozen membership, completion and unchanged archive access. Validation against `455a2d4`: full `./test.sh` passed and `./build.sh` passed (arm64, ad-hoc signed, worktree staging). A separate in-memory fixture bundle built and launched with isolated defaults; the desktop automation tool timed out while selecting it, so native interaction and accessibility-tree behavior remain unverified. No installation or real user data changes.
