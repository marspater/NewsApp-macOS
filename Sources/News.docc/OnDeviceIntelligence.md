# On-device intelligence

See which analysis is rules, which uses Apple frameworks, and which models ship in the bundle.

## Overview

All analysis runs on the Mac and no story text reaches a remote AI service. Most of it is deterministic. A language model writes prose on only three surfaces, and each has a fallback that needs no model.

### Topic classification

``ArticleClassifier`` assigns one of the twelve ``NewsCategory`` values in three stages: a publisher's own category when it names one, then keyword scoring by ``NaturalLanguageTopicClassifier`` over ``NaturalLanguageTopicClassifier/taxonomy``, with headline matches weighted above description and body, then ``NewsCategory/world`` as the default. ``EnrichmentQueue`` runs it in the background under the bounded enrichment rules.

### Sentiment

``NaturalLanguageSentimentAnalyzer`` reads the `NLTagger` sentiment score and returns a ``SentimentResult``. ``ArticleAnalyzer`` computes it when a story is analysed, and the score is stored with the analysis but never shown in the reader; background classification writes none.

``NotificationService`` runs its own tagger, using the size of the score as one signal of a story's importance. ``CoverageSentimentEvaluator`` decides from a labeled corpus whether an event overview may carry coverage sentiment at all, because lexical taggers read disaster reporting as negative opinion.

### Bundled Core ML models

Two models ship in `Sources/Resources/CoreML`, each with a sibling metadata file recording its origin. Both derive from `all-MiniLM-L6-v2`.

| Model | Type | Use |
|---|---|---|
| `minilm.mlmodelc` | ``SentenceEmbedder`` | Sentence vectors for matching and for the semantic arm of search |
| `pairscorer.mlmodelc` | ``PairScorer`` | A cross-encoder scoring borderline pairs of reports |

Both run on the CPU and Neural Engine, in fixed-length functions chosen per input. ``SentenceEmbedder/modelVersion`` stamps stored embeddings, so vectors from different models are never compared.

### Event grouping

``EventCandidateFinder`` narrows the candidates, and ``EventMatcher`` decides each pair: first by rules on dates, anchors and conflicts, then by embedding similarity and the pair model where rules leave it open. Hard conflicts and a reader's exclusions always refuse a pair. Neither model is asked about reports recognized as another language than English. Grouping never calls a language model.

### Foundation Models

``NewsTextModel`` wraps the system language model where it is available. It writes only the reader summary, the World Tension assessment and the Briefing sitrep line. A ``NewsTextModel/Rejected`` answer is final, so the fallback stands. ``NewsTextModel/TemporarilyUnavailable`` keeps a provisional result that is redone on next request. ``GeneratedTextFidelity`` compares generated text with its source deterministically; no model checks a model.

### Energy

``IntelligencePolicy/allowsEnergy(_:)`` pauses background classification, overview warm-up, story images and World Tension in Low Power Mode and from the serious thermal state on. Clustering continues with the rules alone and leaves what its models would have decided for a later pass.

## Topics

### Classification and sentiment

- ``ArticleClassifier``
- ``NewsCategory``
- ``NaturalLanguageSentimentAnalyzer``
- ``CoverageSentimentEvaluator``

### Models

- ``SentenceEmbedder``
- ``PairScorer``
- ``NewsTextModel``
- ``EventMatcher``
