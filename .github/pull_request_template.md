## Summary

## Changes

## Angelia sub-systems

<!-- Each domain of docs/ANGELIA.md whose code this PR changes, with its job on first use ("Clio · sourced overviews"), then the domains it affects without changing their code. For a change to a view in Sources/Views/ that shows a domain's output, name that domain and say that the change is in a view. Shared view code that shows no domain's output (design tokens, settings, window chrome) names none. Write "None" when the PR touches neither Angelia code nor a view that shows a domain's output. -->

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
