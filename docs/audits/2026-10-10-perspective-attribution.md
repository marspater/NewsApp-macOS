# Perspective attribution parsing — 10 October 2026

Related: #313.

## Root cause and change

The deterministic extractor recognized only straight double quotes followed by a speech verb and speaker. The existing typographic-quote diagnostic fixture produced no candidate for a named speaker preceding `said` after the quote.

Quoted attribution now accepts paired straight or curly double quotes with either post-quote speaker order. The captured statement remains a verbatim substring of the source passage. Existing statement limits, citation validation, anonymous-speaker rejection and syndicated voice collapsing remain in force. Mismatched delimiters are rejected. Overview analysis version 5 makes earlier cached documents stale; they regenerate through the existing coordinator on request, with no database migration.

## Verification scope

Native story regressions cover both speaker orders, both quote styles, verbatim statements/citation IDs, mismatched delimiters, unattributed quotes, vague speakers, and a curly-quote Reuters reprint collapsing with a straight-quote original. Full tests and an isolated arm64 build are recorded in the PR when complete. Verification uses synthetic evidence only, without installing the app or changing the real library.

This fixes a demonstrated coverage gap; it does not measure coverage on a live panel or establish generation acceptance. #313 remains open for coverage measurement and any subsequent model proposal, which still needs the independently labelled #308 set.
