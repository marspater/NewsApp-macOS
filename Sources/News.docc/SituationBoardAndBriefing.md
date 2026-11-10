# Situation Board and Briefing

Understand how a daily edition is selected, then how the board presents it.

## Overview

The Briefing is a finite daily edition, and the Situation Board is the view that presents it. Selection and presentation are separate: ``FiniteBriefing`` picks the stories, and ``BriefingView`` lays out the board around them.

### Selecting an edition

``FiniteBriefing`` holds at most ``FiniteBriefing/maximumStories`` unread, unmuted reports, chosen from up to ``FiniteBriefing/candidateLimit`` candidates over ``FiniteBriefing/duration``. An edition takes at most two reports per publisher and one per event.

Each pick ranks the remaining candidates on ``BriefingPriority`` (stored ``StoryImportance`` and publisher coverage), the reader's interests by category from local read and saved history, and diversity and recency. Selection never calls a model, and importance never hides a story.

An edition is frozen until the next edition hour (``FiniteBriefing/defaultEditionHour`` unless changed) or until the reader asks for a new one, and an ordinary refresh does not touch it. ``FiniteBriefing/isCurrent(selectedAt:now:hour:calendar:)`` decides whether a stored edition still stands.

### The board

``BriefingView`` arranges modules under five ``BriefingPillar`` groups, each module a ``BriefingModuleKind``. ``BriefingLayout`` records the reader's arrangement, and ``BriefingBoardData`` carries what the modules show. A module with no data does not appear. ``BriefingBoardFilter`` narrows the board, for example to one region.

| Pillar | Modules |
|---|---|
| Situational awareness | Hero carousel, World Tension, since your last briefing, executive sitrep |
| Intelligence assessment | Priority developments, source footprint, tension drivers |
| Strategic impact | Industry impact, regions, region tiles |
| Weak signals | Weak signals |
| Forward watch | Forward watch, escalation timeline |

``BriefingHeroCarouselView`` advances every 10 seconds with a slow cross-fade and pauses while the reader is engaged with it. ``BriefingActions`` carries every interaction back to the list.

### Executive sitrep

``BriefingSitrepComposer`` restates a thread's top cited highlights in one on-device sentence. A sentence that is too long, carries a link, names anything outside its inputs or drops a qualifier gives way to the first highlight. Lines are cached under a stamp of their inputs, so a stale save is refused, and Clear AI Analysis removes them.

### Since your last briefing

Each opened edition saves its events as ``BriefingEditionSnapshotRow`` values, which the next edition compares against to show what changed.

### World Tension

``BriefingTensionStripView`` shows the same ``WorldTensionState`` as the sidebar and the tension sheet. ``MainView`` alone runs the assessment, so every surface reports one reading in one wording.

## Topics

### Selection

- ``FiniteBriefing``
- ``BriefingPriority``

### Presentation

- ``BriefingView``
- ``BriefingLayout``
- ``BriefingModuleKind``
- ``BriefingPillar``
- ``BriefingSitrepComposer``
