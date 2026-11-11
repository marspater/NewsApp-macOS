# Angelia

Angelia is the name of the app's semantic system: everything that turns publisher reports into events, stories, overviews and editions. This page is the name register. It says which name owns which code, what each name hands to the next, and what is live. Technology and invariants stay in [ARCHITECTURE.md](ARCHITECTURE.md).

Angelia (Greek Ἀγγελία, "message"; say *ang-geh-LEE-ah*, hard g, stress on "lee") personifies reports and proclamations. Pindar names her a daughter of Hermes.

## Rules

1. A name is an ownership alias. Swift types, logs and CLI output keep their descriptive names (`EventMatcher`, not `Themis`).
2. Write a name with its job on first use in a document or diagram: "Themis · pair rules".
3. A name never raises maturity. The Status column is the only statement of what is live.
4. Each type or function has one owner. A file that holds two owners' code is listed under [Shared files](#shared-files).
5. Angelia spans three source layers (`Sources/Services`, `Sources/Intelligence`, `Sources/Storage`). It is wider than the "Intelligence" layer of the ARCHITECTURE.md system map.

## Register

Paths are relative to `Sources/`.

| Name | Job | Owns | Status |
|---|---|---|---|
| **Iris** | Bring reports in | `Services/FeedFetcher`, `FeedXMLParser`, `JSONFeedParser`, `DateParser` · `Intelligence/Extraction/ContentExtractionPipeline` | Live |
| **Metis** | Turn text into structured clues | `Intelligence/ArticleIntelligence` (`ArticleClassifier`, `NaturalLanguageTopicClassifier`) · `EventFeatures`, `EventPlaces` · `Intelligence/Events/ActClass` | Live |
| **Proteus** | Encode semantic evidence | `Intelligence/Events/SentenceEmbedder` (`SentenceEmbedder`, `PairScorer`, `BertWordPieceTokenizer`) · `Resources/CoreML` | Live |
| **Themis** | Rule on a pair of reports | `EventMatcher`, `EventMatchPolicy`, `EventConflict`, `EventPairAssessment`, `PairCalibration` | Live |
| **Harmonia** | Assemble one occurrence | `EventClusterer` admission and `mergeFragments` · `event_inclusions`, `event_exclusions` | Live |
| **Ariadne** | Link the events of a developing story | `EventClusterer.linkStories` · `EventStoryRelation` | Live |
| **Mnemosyne** | Retain evidence and find it again | `Storage/DatabaseEngine*`, `ArticleStore*` · `EventCandidateFinder`, `EventMatchKey` · hybrid search (`DatabaseEngine+Search`) | Live |
| **Clio** | Compose sourced overviews | `Intelligence/Overview/OverviewComposer`, `OverviewGenerationCoordinator`, `OverviewPassageSelector`, `OverviewPerspectivesExtractor`, `OverviewTimeline*`, `OverviewIndustryImpactExtractor`, `OverviewThematicAngleExtractor`, `PassageFactExtractor` | Live |
| **Aletheia** | Check fidelity to the cited text | `OverviewClaimVerifier`, `GeneratedTextFidelity`, `OverviewQualityAuditor`, `CoverageSentimentEvaluator` | Live. Checks agreement with the source, never external truth. |
| **Kairos** | Detect what is new and accelerating | `Intelligence/Editorial/EditorialNovelty`, `EditorialMomentum` | Experimental, no production consumer |
| **Athena** | Decide what deserves attention | `Intelligence/Today/*` · `FiniteBriefing`, `BriefingPriority` · `Intelligence/Briefing/*` | Live |
| | | `Intelligence/Editorial/EditorialRanking`, `EditorialPersonalization` | Experimental, no production consumer |

## What each name hands on

| From | To | Artifact |
|---|---|---|
| Iris | Mnemosyne | Article text and metadata, one transaction per feed |
| Mnemosyne | Metis | Stored articles |
| Metis | Mnemosyne | Category (`article_enrichment`), versioned `EventFeatures` (`article_features`) |
| Mnemosyne | Themis | Up to 40 candidates from the past 48 hours (FTS5 shortlist, no verdict) |
| Proteus | Themis | Cosine of two 384-dimension vectors; `p(same)` for a borderline English pair |
| Proteus | Mnemosyne | Versioned vectors (`article_embeddings`) for matching and search |
| Themis | Harmonia | One `EventPairAssessment` per pair: match, compatible, borderline or conflict |
| Harmonia | Mnemosyne | Event membership (`events`, `event_members`), stored pair verdicts (`pair_assessments`) |
| Harmonia | Ariadne | Formed events |
| Ariadne | Mnemosyne | Story membership and "Earlier in This Story" links |
| Mnemosyne | Clio | An event's reports and passages |
| Clio | Aletheia | Draft passages, perspectives, timeline and generated text |
| Aletheia | Mnemosyne | Accepted overviews with citations (`event_overviews`, `event_overview_citations`) |
| Mnemosyne | Athena | Formed stories with source, importance and reading signals |

Two boundaries carry most of the system's errors. Proteus supplies evidence and Themis the verdict, so a high cosine is never a match on its own. Themis rules on a pair and Harmonia on the whole event, so a correct pair can still be refused admission.

## Shared files

These files hold more than one owner's code. Name the owner of the type or function, not of the file.

| File | Holds |
|---|---|
| `Intelligence/Events/EventMatcher.swift` | Metis (`EventFeatures`, `EventPlaces`) and Themis (`EventMatcher`, `EventMatchPolicy`) |
| `Intelligence/Events/EventClustering.swift` | Harmonia (admission, `mergeFragments`) and Ariadne (`linkStories`), both inside `EventClusterer` |
| `Intelligence/Events/EventCandidates.swift` | Mnemosyne (`EventCandidateFinder`, `EventMatchKey`) and Ariadne (`EventStoryRelation`) |

## Not yet assigned

Semantic code with no name. Each needs an owner or a new name before the register is complete.

| Code | What it does |
|---|---|
| `Intelligence/Tension/*` (`WorldTensionService`, `TensionMethodology`, `Hotspot*`, `WorldTensionNearYou`) | World Tension assessment, smoothing, hotspots and the Near-you lens |
| `Intelligence/Editorial/EntityIndexer`, `EntityGraph` | Entity index and co-reporting graph |
| `Intelligence/Editorial/DualReaderAlignmentService`, `PerspectiveReports` | Compare Perspectives: the passages two reports share |
| `Intelligence/Editorial/EditorialWireIdentity` | Wire-agency origin of a report (experimental) |
| `Intelligence/Events/StoryImportance` (`StoryImportance`, `StoryCurator`, `StoryImage*`) | Importance rating and lead-image lookup |
| `Intelligence/Extraction/EnrichmentQueue` | Bounded background classification |
| `NewsTextModel`, `IntelligencePolicy`, `AppleIntelligenceAvailability`, `GenerationPromptDefense` | The Foundation Models path and its gates |
| `Coordinators/NotificationService` triage | Which stories earn a banner |

The protected network gateway (`NetworkBoundaryProxy`, `SecureHTTPClient`, `IPAddressValidator`) is outside Angelia: it is a security boundary, described in [SECURITY.md](../SECURITY.md).
