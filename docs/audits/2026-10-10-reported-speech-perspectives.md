# Reported-speech perspectives — 10 October 2026

Refs #313. Source: `origin/main` at `cc0f41a` plus this change. Sample: the private step-2 copy from #308, the 7–8 October window, with publisher text stored by #414 for 58 multi-source events. Only aggregates are recorded here; passages and the review list stay in the private run directory.

## Cause

With publisher text, 232 of 348 selected passages contained speech the extractor did not match. A local review of the missed passages showed mostly reported speech from a named speaker, with no "that" right after the verb:
- "Foreign Secretary Ed Miliband said his country does not accept…"
- "…Gideon Saar said Thursday's move…"
- "…told TF1 television on Thursday night that…"

The existing patterns required a quotation or an adjacent "said that". Speaker cleanup also kept leading time phrases and did not treat pronouns as vague.

## Change

- A reported-speech pattern: a capitalized speaker of up to 60 characters with no full stop, followed by "said" or "says" (with an optional time or channel such as "on Thursday night" or "in a statement:" and an optional "that"), or by "told OUTLET … that" (including outlet names preceded by "the", "a", or "an", such as "the BBC"). It rejects statements that begin with a preposition, an auxiliary verb or an -ing word, which signal a mis-cut speaker.
- Speaker cleanup applies to every pattern:
  - keeps only the last sentence;
  - drops leading adverbials (including weekdays and months) and participle clauses;
  - drops leading articles and conjunctions, and trailing "also", "has" or "had";
  - rejects speakers that end in a relative word or pronoun, or contain no capitalized word.
- Pronouns and a bare "officials" are vague participants.
- Overview analysis version 6 regenerates cached overviews on request.

## Results (58 events)

| Measure | Before | After |
| --- | ---: | ---: |
| Events with two or more perspectives | 2 | 27 |
| Events with one | 24 | 20 |
| Events with none | 32 | 11 |
| Extracted voices | 30 | 98 |
| Passages with unmatched speech | 232 | 153 |
| First gap: speech not matched | 30 | 9 |

Precision: I reviewed all 98 extracted perspectives as a copilot review, pending Mars's acceptance. The criterion: the participant identifies the actual speaker (extra descriptive words tolerated), and the position is something that speaker said. 87 were correct (88.8 %, Wilson 95 % 81.0–93.6 %). The 11 errors:

| Error | Count |
| --- | ---: |
| Speaker taken from a nearby place or outlet ("Florida", "United States") | 4 |
| Speaker fragment with a clause attached | 4 |
| Statement that is only a time phrase | 2 |
| A poll result presented as a voice | 1 |

## Limits

- One window; one reviewer, who is not independent of the implementation.
- The deterministic validator checks that statements are verbatim, not who said them, so speaker errors reach the reader.
- No installation or app launch.
