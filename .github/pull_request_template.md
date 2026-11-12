## Summary

## Changes

## Angelia sub-systems

<!-- Each domain of docs/ANGELIA.md whose code this PR changes, with its job on first use ("Clio · sourced overviews"), then the domains it affects without changing their code. For a change in Sources/Views/, name the domain whose output the view shows and say that the change is in a view. Write "None" only when the PR touches neither Angelia code nor such a view. -->

## Testing

<!-- Report each check separately and only as run. A build is not evidence of installation, launch or live network behaviour. -->

## Publication checklist

- [ ] Based on a fresh `origin/main`
- [ ] Checks required by [CONTRIBUTING.md](../CONTRIBUTING.md) for this change
- [ ] UI changes: [DESIGN.md](../docs/design/DESIGN.md) review checklist completed in the description
- [ ] App changes: arm64 ad-hoc staged build in an isolated directory, and launch
- [ ] Migration review on a copied database (rollback, saved and read state) and diff review
- [ ] Focused Conventional Commits
- [ ] CHANGELOG for behaviour changes; dated evidence in `docs/audits/`
- [ ] Not installed over the real app without a separate request

## Risks

## Related

Refs #
