# Changelog fragments

Each pull request records its user-visible change here, in its own file, instead of editing `CHANGELOG.md`:
`CHANGELOG.d/<issue>.md` (the issue number the PR closes; `<issue>-<slug>.md` when one issue ships in several PRs),
holding one or more `- ` bullet lines in the voice of the changelog. Separate files never conflict, so stacked and
parallel PRs merge without touching each other.

Before a tag, `python3 script/changelog_fold.py` moves every fragment under the `## Unreleased` heading of
`CHANGELOG.md`, newest issue first, and deletes the files. Nobody edits `CHANGELOG.md` in a feature PR.
