# Angelia

Angelia is the name of the app's semantic system: everything that turns publisher reports into events, stories, overviews and editions. This page is the name register. It says which name owns which code, what each name hands to the next, and what is live. Technology and invariants stay in [ARCHITECTURE.md](ARCHITECTURE.md).

Angelia (Greek Ἀγγελία, "message"; say *ang-geh-LEE-ah*, hard g, stress on "lee") personifies reports and proclamations. Pindar names her a daughter of Hermes.

## Rules

1. A name is an ownership alias. Swift types, logs and CLI output keep their descriptive names (`EventMatcher`, not `Themis`).
2. Write a name with its job on first use in a document or diagram: "Themis · pair rules".
3. A name never raises maturity. The Status column is the only statement of what is live.
4. Each type or function has one owner. A file that holds two owners' code is listed under [Shared files](#shared-files).
5. Angelia spans three source layers (`Sources/Services`, `Sources/Intelligence`, `Sources/Storage`). It is wider than the "Intelligence" layer of the ARCHITECTURE.md system map.
6. Every Swift file a name owns says so in a comment after the license header: `// Angelia · Themis (pair rules) owns this file. Register: docs/ANGELIA.md.` A shared file names each owner and its types. `script/format.sh --check` and the pre-commit hook refuse a file under `Sources/Intelligence/` without the comment; owned files elsewhere carry it by this register. A new or moved file gets its comment and its register row in the same change.

## Register

Paths are relative to `Sources/`.

| Name | Job | Owns | Status |
|---|---|---|---|
| **Iris** | Bring reports in | `Services/FeedFetcher`, `FeedXMLParser`, `JSONFeedParser`, `DateParser`, driven by `FeedManager` | Live |
| | | `Intelligence/Editorial/EditorialWireIdentity` (wire-agency origin of a report) | Experimental, no production consumer |
| **Metis** | Turn text into structured clues | `Intelligence/ArticleIntelligence` (`ArticleClassifier`, `NaturalLanguageTopicClassifier`) · `EventFeatures`, `EventPlaces` · `Intelligence/Events/ActClass` · `Intelligence/Extraction/EnrichmentQueue`, `ContentExtractionPipeline` (reader text on open) · `Intelligence/Editorial/EntityIndexer` | Live |
| **Proteus** | Encode semantic evidence | `Intelligence/Events/SentenceEmbedder` (`SentenceEmbedder`, `PairScorer`, `BertWordPieceTokenizer`) · `Resources/CoreML` | Live |
| **Themis** | Rule on a pair of reports | `EventMatcher`, `EventMatchPolicy`, `EventConflict`, `EventPairAssessment`, `PairCalibration` | Live |
| **Harmonia** | Assemble one occurrence | `EventClusterer` admission and `mergeFragments` · `event_inclusions`, `event_exclusions` | Live |
| **Ariadne** | Link the events of a developing story | `EventClusterer.linkStories` · `EventStoryRelation` | Live |
| **Mnemosyne** | Retain evidence and find it again | `Storage/DatabaseEngine*`, `ArticleStore*` · `EventCandidateFinder`, `EventMatchKey` · hybrid search (`DatabaseEngine+Search`) · `Intelligence/Editorial/EntityGraph` | Live |
| **Clio** | Compose sourced overviews | `Intelligence/Overview/OverviewComposer`, `OverviewGenerationCoordinator`, `OverviewPassageSelector`, `OverviewPerspectivesExtractor`, `OverviewTimeline*`, `OverviewIndustryImpactExtractor`, `OverviewThematicAngleExtractor`, `PassageFactExtractor` · `Intelligence/Editorial/DualReaderAlignmentService`, `PerspectiveReports` (Compare Perspectives) | Live |
| **Aletheia** | Check fidelity to the cited text | `OverviewClaimVerifier`, `GeneratedTextFidelity`, `OverviewQualityAuditor`, `CoverageSentimentEvaluator`, `GenerationPromptDefense` | Live. Checks agreement with the source, never external truth. |
| **Athena** | Decide what deserves attention | `Intelligence/Today/*` (the six lanes of the Today edition) · `FiniteBriefing`, `BriefingPriority` · `Intelligence/Briefing/*` · `Intelligence/Events/StoryImportance` (`StoryImportance`, `StoryCurator`, `StoryImage*`) · `Coordinators/NotificationService` triage | Live |
| | | `Intelligence/Events/EventJudge` (`EventJudgeReport`, the importance audit's input) | Evaluation only, no production caller |
| | | `Intelligence/Editorial/EditorialRanking`, `EditorialPersonalization` | Experimental, no production consumer |
| **Eris** | Assess World Tension | `Intelligence/Tension/*` (`WorldTensionService`, `TensionMethodology`, `Hotspot*`, `WorldTensionNearYou`) | Live |
| **Kairos** | Detect what is new and accelerating | `Intelligence/Editorial/EditorialNovelty`, `EditorialMomentum` | Experimental, no production consumer |
| **Angelia Core** | Shared model access and gates | `NewsTextModel`, `AppleIntelligenceAvailability`, `IntelligencePolicy` | Live |

## What each name hands on

| From | To | Artifact |
|---|---|---|
| Iris | Mnemosyne | Article text and metadata, one transaction per feed |
| Mnemosyne | Metis, Proteus, Clio | Stored text and metadata |
| Metis | Themis | Versioned `EventFeatures` (cached in `article_features`); the category goes to `article_enrichment` |
| Proteus | Themis | Cosine of two 384-dimension vectors; `p(same)` for a borderline English pair |
| Proteus | Mnemosyne | Versioned vectors (`article_embeddings`) for matching and search |
| Mnemosyne | Themis | Up to 40 candidates from the past 48 hours (FTS5 shortlist, no verdict) |
| Themis | Harmonia | One `EventPairAssessment` per pair: match, compatible, borderline or conflict |
| Harmonia | Mnemosyne | Event membership (`events`, `event_members`), stored pair verdicts (`pair_assessments`) |
| Harmonia | Ariadne, Clio | Formed events |
| Ariadne | Athena | Stories and "Earlier in This Story" links, read from storage |
| Clio | Aletheia | Draft passages, perspectives, timeline and generated text |
| Aletheia | Mnemosyne | Accepted overviews with citations (`event_overviews`, `event_overview_citations`) |
| Mnemosyne | Athena | Up to 500 candidate stories with importance, coverage and reading history; cited highlights for Briefing |
| Mnemosyne | Eris | The day's panel headlines (`tensionCorpus`) |
| Eris | Athena | The reading and its drivers, shown in Briefing's World Tension module. No input to Today or to Briefing selection. |
| Angelia Core | Metis, Eris, Athena | `NewsTextModel` prose on three surfaces: reader summary, World Tension assessment, Briefing sitrep. Event overviews carry no model prose. |
| Angelia Core | Metis, Proteus, Harmonia, Clio, Eris | The energy check (`IntelligencePolicy.allowsEnergy`) that defers model work |

Two boundaries carry most of the system's errors. Proteus supplies evidence and Themis the verdict, so a high cosine is never a match on its own. Themis rules on a pair and Harmonia on the whole event, so a correct pair can still be refused admission.

## Shared files

These files hold more than one owner's code. Name the owner of the type or function, not of the file.

| File | Holds |
|---|---|
| `Intelligence/Events/EventMatcher.swift` | Metis (`EventFeatures`, `EventPlaces`) and Themis (`EventMatcher`, `EventMatchPolicy`) |
| `Intelligence/Events/EventClustering.swift` | Harmonia (admission, `mergeFragments`) and Ariadne (`linkStories`), both inside `EventClusterer` |
| `Intelligence/Events/EventCandidates.swift` | Mnemosyne (`EventCandidateFinder`, `EventMatchKey`) and Ariadne (`EventStoryRelation`) |
| `Intelligence/ArticleIntelligence.swift` | Metis (classification, entities) and Angelia Core (`NewsTextModel`) |

## No single owner

`Coordinators/FeedManager` drives Angelia without belonging to one domain: it starts the refresh (Iris), background classification (Metis) and the clustering pass (Harmonia and Ariadne), and it also owns sleep, wake and lifecycle. Its comment names the domains it drives.

## Outside Angelia

The protected network gateway (`NetworkBoundaryProxy`, `SecureHTTPClient`, `IPAddressValidator`) is outside Angelia: it is a security boundary, described in [SECURITY.md](../SECURITY.md).
