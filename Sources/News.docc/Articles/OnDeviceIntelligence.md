# On-Device Intelligence

Explore how News leverages Apple platform machine learning frameworks for local article intelligence.

## Overview

News executes all machine learning, natural language processing, and semantic analysis strictly on-device using Apple's `NaturalLanguage` and `FoundationModels` frameworks. No article content or summaries are ever transmitted to remote cloud models or third-party AI APIs.

### Intelligence Pipeline

1. **Deterministic Topic Classification (``ArticleClassifier``)**: Categorizes incoming feed stories across 12 canonical topics (e.g., Technology, Science, Business, World) using high-speed keyword heuristics and keyword weights.
2. **Entity & Sentiment Extraction (``ArticleAnalyzer``)**: Extracts named people, organizations, and places via `NLTagger`.
3. **Journalistic Tone Evaluation (``CoverageSentimentEvaluator``)**: Calibrates tone assessments by filtering confounding adversity vocabulary (e.g., casualties, disaster terms) to avoid false critical labeling on objective crisis reporting.
4. **World Tension Reasoning (``WorldTension``)**: Evaluates a balanced 12-feed global panel to measure international crisis levels with four cited causal dimensions (`Novelty`, `Proximity to worst case`, `Reversibility`, `Scope of impact`).
