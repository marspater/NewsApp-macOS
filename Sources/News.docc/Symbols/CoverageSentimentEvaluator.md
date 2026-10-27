# ``CoverageSentimentEvaluator``

Evaluator that determines whether automated coverage sentiment meets the reliability threshold to ship in event overviews.

## Overview

`CoverageSentimentEvaluator` benchmarks tone estimation across journalistic corpora. Under the project's sentiment policy:
- Sentiment indicates the stylistic framing of the text, not the factual veracity or hazard level of the real-world event.
- Sections without statistically validated data are omitted rather than filled with speculative ratings.
- Sentiment metadata is included in event overviews only when empirical evaluation justifies its reliability.

### Confounding Adversity Vocabulary

Standard lexical sentiment taggers frequently misclassify objective disaster, accident, and crisis reporting (e.g., casualties, earthquakes, economic downturns) as editorial opinion. This evaluator benchmarks these error rates across a frozen ground-truth corpus to prevent misleading sentiment badges from appearing in synthesized overviews.

## Topics

### Corpus Evaluation
- ``runCorpusEvaluation(corpus:)``
- ``defaultCorpus``
- ``CorpusEvaluationItem``
- ``CoverageSentimentMetrics``

### Overview Gate & Inclusion
- ``shouldIncludeInOverview(passages:)``
- ``synthesizeCoverageSentiment(passages:)``

### Calibrated Tone Assessment
- ``assessTextToneSafely(_:languageCode:)``
- ``ToneAssessment``
- ``JournalisticToneGroundTruth``
- ``EventNature``

### Configuration
- ``shared``
- ``catalogLanguages``
