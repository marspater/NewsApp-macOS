# Curated knowledge export — 6 November 2026

Issue #713 is the remaining implementation in Epic V (#710); annotations #711 and revision diffing #712 are already merged. The export adds no model, network request, schema migration or shipping dependency.

## Contract

The reader and File menu offer Markdown, EPUB and native Notes sharing. The Briefing offers the same actions for its frozen selection, in edition order, with compact stored excerpts. A database actor turn captures current stored text, source-specific citations and private notes. Missing stories fail explicitly. Exports include all selected notes rather than silently dropping them; oversized inputs fail. Per-story body is bounded to 2 MiB, selections to ten stories, and aggregate EPUB input/output to 32 MiB.

Encoding and atomic file writes run on a serial background actor; a newer export cancels presentation of the preceding operation. Save panels disclose private-note inclusion. Notes opens the native sharing service and follows the user's account/sync configuration. Nothing fetches remote resources or changes saved/read state.

Markdown uses quoted YAML scalars, source links, tags, cited quotes and separately labelled private notes. EPUB contains only fixed ZIP paths, an uncompressed first mimetype member, CRC-protected entries, OPF/nav/XHTML and escaped publisher text; no executable HTML, remote images or scripts. Private notes and citations have distinct headings, and body paragraph boundaries are retained. Unknown citation metadata never falls back to an unrelated representative publisher.

## Evidence

- Integrated export controls cover YAML/Unicode injection, Markdown escaping, independent citation provenance, rich-text/RTF round-trip, database notes, unknown publication dates, cached text vs digest excerpts and missing-story failure.
- EPUB structural controls cover ZIP member order, CRCs, central directory, XML parsing/escaping, size limits and paragraph/note boundaries.
- EPUBCheck 5.4.0 accepted the initial fictional generated fixture with zero fatals, errors, warnings or infos. Validation tools and their checksum-verified Java runtime were extracted only under `/private/tmp/news-knowledge-export/tools`, with no system installation or shipping dependency.
- The native Notes sharing service accepts the attributed-string payload. No note was saved. This capability/RTF check is separate from an actual compose-sheet acceptance check.
- Ten isolated native menu captures cover 900/1400-point widths, light/dark, high-contrast light/dark and a reduced-motion override. Visual inspection found readable labels and no clipping. Accessibility inspection exposed Export, its private-note help and all three action labels. This is not a full reader end-to-end keyboard or VoiceOver pass; Reduce Transparency remains the host setting rather than a simulated override.
- A separate production app built for arm64 with ad-hoc signing under `com.marspater.news.knowledgeappcheck`; strict deep signature verification passed. The production verification bundle was not launched or installed. The isolated fictional menu harness was launched and closed; no real News library/preferences were opened.

An initial full regression run caught an exact timestamp comparison in a new fixture: `Date()` does not retain sub-microsecond precision through SQLite's Unix Double round-trip. Fixed epoch timestamps preserve an exact, deterministic note-content assertion. Final rerun results and current source evidence are recorded after completion on the linked PR.

## Remaining native acceptance

Actual Books import/open/removal is pending approval because importing changes the Books library; no import occurred. Actual Notes compose/save and complete keyboard/VoiceOver verification are not claimed. These acceptance gaps must remain visible rather than closing the epic solely from format validation.
