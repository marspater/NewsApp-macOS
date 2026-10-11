# World Tension v2 — on-device headline assessment

v2 replaces the displayed v1 formula with an AI judgment of global stability from current international headlines. The AI chooses a 0–100 reading through reasoning; factor scores are not multiplied or summed. Bands are Zen (0–19), Mild (20–39), Warm (40–59), Hot (60–79) and Boiling (80–100). These labels describe an interpretation of the supplied news, not a measured probability of catastrophe.

## Evidence and factors

The existing opt-in twelve-feed international English panel supplies dated headlines from the preceding 24 hours. Most panel feeds and regions must have reported, using the established coverage gate. One representative per clustered event is selected; the input is bounded to 12 current headlines balanced across publisher regions. Up to 8 headlines from the preceding six days in the same existing event clusters supply comparable novelty context. Unrelated previous events are excluded. Missing or unrelated prior context is explicitly identified, never treated as proof every event is new. Publication date alone does not establish an escalation. Coverage, selection bounds and regional gaps limit the claim to the available panel.

The on-device model evaluates all four factors together:

- **Novelty:** new crises or escalations matter more than ongoing situations already priced in. Compare current and previous headlines; do not confuse repeated coverage with escalation.
- **Proximity to worst case:** evidenced proximity to catastrophic outcomes, especially nuclear/WMD situations, has outsized importance. Threats and hypothetical outcomes are not actual attacks.
- **Reversibility:** irreversible invasions and loss of life matter more than reversible sanctions and rhetoric.
- **Scope of impact:** global systemic risk, economic contagion and alliance triggers matter more than localized incidents. Numerous violent or disaster headlines alone do not justify the highest band.

## Explanation and acceptance

The model reasons about global scope first, then worst-case proximity, novelty and reversibility, and chooses the number last. It returns a labelled report, converted to a structured assessment: score, a short summary, exactly four named rationales, and the complete supplied headline snapshot, disclosed by the app. Native guided generation refused even a peaceful control on the tested model, so this uses the existing plain-text generation seam with a strict parser. Score range, paragraph lengths and all four distinct factors are checked. Previous headlines contextualize novelty and must not be described as current events. Per-factor generated citations are intentionally not shown: the tested model assigned incorrect IDs, so support is checked against the complete supplied snapshot instead.

A fresh on-device model session checks concrete factual claims against the supplied headlines, including event meanings, novelty comparisons, uncertainty and attribution. Risk interpretations remain subjective; an absence-of-evidence limit is not treated as a claim that an event never happened. An unsupported or malformed response is rejected, and the previous accepted assessment is preserved with its own date. This support judgment remains a heuristic; it does not make publisher claims or AI reasoning infallible. Generated reasoning is labelled as assessed on device. The UI supplies numeric reading/band and any comparison from accepted assessments; the model is not asked to invent an average or daily change.

## Policy, caching and history

AI and panel collection must be enabled before any cache is read. Low Power Mode and thermal pressure defer assessment. When the on-device model cannot run, the UI states that no assessment is available; there is no v1 score or formula fallback labelled as AI.

Inputs, UTC day and macOS model generation identify cached assessments. Concurrent identical requests share generation; cancelled callers do not publish or persist their answer. Reassess bypasses the completed cache. All processing uses the existing on-device model seam, fresh sessions and greedy sampling; nothing is sent to cloud AI.

Accepted history is stored atomically beside the SQLite library in `news.sqlite3.world-tension-v2.json`, separately from v1. It retains one assessment per UTC day, at most 30 recorded days. Clearing AI data or all local caches clears this derived history. Gaps remain gaps; different model generations are not connected or compared. Original v1 calibration and corpus data are preserved, not backfilled or relabelled.
