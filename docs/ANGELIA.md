# Angelia

Angelia is the name of the app's semantic system: everything that turns publisher reports into events, stories, overviews and editions. This page is the name register. It says which name owns which code, what each name hands to the next, and what is live. Technology and invariants stay in [ARCHITECTURE.md](ARCHITECTURE.md).

Angelia (Greek Ἀγγελία, "message"; say *ang-geh-LEE-ah*, hard g, stress on "lee") personifies reports and proclamations. Pindar names her a daughter of Hermes.

## Rules

1. A name is an ownership alias. Swift types, logs and CLI output keep their descriptive names (`EventMatcher`, not `Themis`).
2. Write a name with its job on first use in a document or diagram: "Themis · pair rules".
3. A name never raises maturity. The Status column is the only statement of what is live.
4. Each type or function has one owner. A file that holds two owners' code is listed under [Shared files](#shared-files).
5. Angelia spans three source layers (`Sources/Services`, `Sources/Intelligence`, `Sources/Storage`). It is wider than the "Intelligence" layer of the ARCHITECTURE.md system map.
6. Every Swift file a name owns says so in a comment after the license header: `// Angelia · Themis (pair rules) owns this file. Register: docs/ANGELIA.md.` A shared file names each owner and its types. The comment sits one blank line after the header. `script/format.sh --check` and the pre-commit hook refuse a file under `Sources/Intelligence/` without it; owned files elsewhere carry it by this register. A new or moved file gets its comment and its register row in the same change. Scope: files in Services, Intelligence, Storage, Models and Coordinators that one domain owns or two share. Views, tests, app lifecycle and models that no single domain produces (`FeedArticle`, `ArticleIdentity`) carry none.

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
| **Mnemosyne** | Retain evidence and find it again | `Storage/DatabaseEngine*`, `ArticleStore*` · `EventCandidateFinder`, `EventMatchKey` · hybrid search (`DatabaseEngine+Search`) · `Storage/MigrationCoordinator` · `Intelligence/Editorial/EntityGraph` · `Models/EntityModels` | Live |
| **Clio** | Compose sourced overviews | `Intelligence/Overview/OverviewComposer`, `OverviewGenerationCoordinator`, `OverviewPassageSelector`, `OverviewPerspectivesExtractor`, `OverviewTimeline*`, `OverviewIndustryImpactExtractor`, `OverviewThematicAngleExtractor`, `PassageFactExtractor` · `Intelligence/Editorial/DualReaderAlignmentService`, `PerspectiveReports` (Compare Perspectives) · `Models/EventOverview`, `Models/DualReaderModels` | Live |
| **Aletheia** | Check fidelity to the cited text | `OverviewClaimVerifier`, `GeneratedTextFidelity`, `OverviewQualityAuditor`, `CoverageSentimentEvaluator`, `GenerationPromptDefense` | Live. Checks agreement with the source, never external truth. |
| **Athena** | Decide what deserves attention | `Intelligence/Today/*` (the six lanes of the Today edition) · `FiniteBriefing`, `BriefingPriority` · `Intelligence/Briefing/*` · `Intelligence/Events/StoryImportance` (`StoryImportance`, `StoryCurator`, `StoryImage*`) · `Coordinators/NotificationService` triage | Live |
| | | `Intelligence/Events/EventJudge` (`EventJudgeReport`, the importance audit's input) | Evaluation only, no production caller |
| | | `Intelligence/Editorial/EditorialRanking`, `EditorialPersonalization` | Experimental, no production consumer |
| **Eris** | Assess World Tension | `Intelligence/Tension/*` (`WorldTensionService`, `TensionMethodology`, `Hotspot*`, `WorldTensionNearYou`) · `Models/HotspotModels` | Live |
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
| Mnemosyne | Athena | For Today: the assignment context of the listed stories, read by the bounded `TodayEditionLoader` queries |
| Athena | Today page | The lane plan (`TodayEditionAssigner.assign`), which `TodayEdition` turns into the page off the main actor |
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

## Tests and tools by domain

Tests and scripts carry no owner comment. This table says where each domain's checks live; suites that span domains (`IntelligenceTests`, `NewsTests`, `LifecycleTests`) are left out.

| Domain | Tests | Scripts and fixtures |
|---|---|---|
| Iris | `FeedKitSwiftSoupTests`, `Native/FeedParsingSuite`, `EditorialWireIdentityTests` | `script/test_editorial_wire_identity.sh`, `script/evaluation/wire_identity_inputs.py` |
| Metis, Themis, Harmonia, Ariadne | `ClusteringTests` | `Tests/Fixtures/story-corpus/matcher-regressions-v1.json`, `story-regressions-v1.json` |
| Proteus | `EventEmbeddingTests` | `script/training/*` (convert, train and compress the two Core ML models) |
| Mnemosyne | `StorageTests`, `Native/StorageSuite`, `Native/MigrationSuite`, `Native/EntityDossierSuite` | |
| Clio | `EventOverviewAccessibilityTests`, `Native/PublisherExcerptSuite`, `Native/DualReaderSuite`, `Native/PerspectiveReportsSuite` | `script/evaluation/overview_review.py` |
| Aletheia | `OverviewQualityAudit` (with Clio) | `Tests/Fixtures/generated-text/fidelity-corpus-v1.json` |
| Athena | `TodayLaneAssignmentTests`, `TodayShadowEvaluation`, `TodayShadowComparisons`, `BriefingE2ETests`, `BriefingIntelligenceTests`, `EditorialRankingTests`, `EditorialPersonalizationTests`, `ImportanceAudit` | `script/test_editorial_ranking.sh`, `script/test_editorial_personalization.sh`, `script/evaluation/importance_review.py` |
| Eris | `TensionCalibrationTests`, `Native/HotspotGazetteerSuite`, `Native/HotspotMapSuite` | `script/test_tension_calibration.sh`, `script/evaluation/calibrate_tension.py` |
| Kairos | `EditorialNoveltyTests`, `EditorialMomentumTests` | `script/test_editorial_novelty.sh`, `script/test_editorial_momentum.sh`, `script/evaluation/momentum_inputs.py` |

## No single owner

`Coordinators/FeedManager` drives Angelia without belonging to one domain: it starts the refresh (Iris), background classification (Metis) and the clustering pass (Harmonia and Ariadne), and it also owns sleep, wake and lifecycle. Its comment names the domains it drives.

## Outside Angelia

Views (`Sources/Views/`) show what the domains produce and belong to none: the story list and the Today edition, the reader and the event overview, the Briefing board and the World Tension sheet.

The protected network gateway (`NetworkBoundaryProxy`, `SecureHTTPClient`, `IPAddressValidator`) is outside Angelia: it is a security boundary, described in [SECURITY.md](../SECURITY.md).
