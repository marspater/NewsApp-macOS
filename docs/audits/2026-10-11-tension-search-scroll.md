# Tension motion, archive search and event-card scrolling

Follow-up to #433. Zen uses a tapered open ensō brush stroke: eased four-second draw, hold, then fade and redraw. Reduced Motion/inactive rendering retains the completed stroke. Boiling has 18 faster sparks and faster flame deformation; motion remains confined to the tension sheet.

The shared SwiftUI archive search retains native tokens, focus, menu behavior and system Liquid Glass. A narrow AppKit bridge bounds the resting NSSearchToolbarItem field to 36 pt; native focus expands it, dismissal with an empty query collapses it. The same search owner covers list and reader. The selected macOS SDK has no SwiftUI always-collapsed search behavior; SearchToolbarBehavior.minimize is unavailable on macOS.

Collapsed event cards previously queried all event members whenever they appeared, then replaced visible image candidates with the asynchronously loaded full membership. Full membership is now fetched only for an expanded source list; the card's image candidates remain those already loaded in the visible feed page, so opening coverage cannot replace its image. This removes avoidable cold-scroll database/model hydration and card image churn; it does not establish absence of every compositor hitch.

Coverage consistently shows story and distinct-publisher counts. Event-summary reads resolve known publisher names from canonical URLs through the existing catalog, instead of counting generic feed titles such as “News” as one publisher. Unknown publishers retain their feed-provided names. No migration or library repair is needed.

## Evidence

- Native render: 180 frames/six-second looping preview generated directly from TensionGlyph.
- Native search probe: resting 36 pt → focused 325 pt → dismissed 36 pt. The system includes its own field insets around the preferred width.
- A 10,000-story native scrolling bitmap probe could not find the detail NSScrollView on this macOS version and failed with `scrollCaptureUnavailable`. Do not interpret that run as a scrolling-performance pass or FPS measurement.
- Reproduce compact search QA with `NEWS_NATIVE_SEARCH_QA=1 ./script/native_performance_baseline.sh /private/tmp/native-search-qa`.
