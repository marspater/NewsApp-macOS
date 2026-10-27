# Situation Board Guide

Understand the architecture, motion rules, and components of the Briefing Situation Board.

## Overview

The Briefing Situation Board (Epic R) redesigns the finite daily edition into an editorial, mission-control layout optimized for macOS displays between 900pt and 1600pt+.

### Key Components

- **Hero Carousel (``BriefingHeroCarouselView``)**: Surfaces the top 3 to 5 ranked daily stories in a prominent lead card. Features an automatic 45-second advance timer powered by an injectable ``CarouselClock`` abstraction.
- **Tension Strip (``BriefingTensionStripView``)**: Presents the current World Tension score, trend indicator, and a 7-day sparkline accompanied by the three primary driving international headlines.
- **Dense Story Tiles (``BriefingTileView``)**: A responsive grid layout presenting categorized stories with cited highlight facts extracted via ``BriefingFactExtractor``, source attribution badges, and unread indicators.

### Motion & Accessibility Invariants

Under Apple Human Interface Guidelines and project invariants:
- **Reduce Motion**: When the system accessibility setting `Reduce Motion` is active, the carousel timer is completely halted (`shouldTimerRun = false`), auto-advance transitions are disabled, and the carousel locks to a static presentation of story index `0`.
- **User Focus & Hover**: Placing the pointer over the carousel or focusing it via keyboard navigation immediately pauses the advance countdown. Opening a story in reader mode halts the countdown until the reader is dismissed.
- **Full Keyboard Navigation**: Users can navigate the carousel using left/right arrows and jump between story tiles using standard vim-style `j`/`k` equivalents, opening selections with `Return`.
