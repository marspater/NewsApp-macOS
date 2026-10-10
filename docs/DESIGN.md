# Design language

The single design language for News on macOS. It applies to every change that adds or modifies UI, by any contributor or agent. Where it is silent, follow Apple's [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines) (HIG); where it conflicts with the HIG, this document wins until it is changed. Technology constraints stay in [ARCHITECTURE.md](ARCHITECTURE.md); the evidence behind these rules is in the [Apple News and Liquid Glass study](audits/2026-10-09-apple-news-liquid-glass-study.md), and the migration of existing code is in the [adoption plan](plans/2026-10-09-design-language-adoption.md).

**Must** and **never** are requirements. **Should** allows a documented exception in the PR description. Code that predates this document is migrated by the adoption plan; a change that touches a view must not add a new deviation and should fix the deviations in the lines it edits.

## 1. Principles

1. **Content first.** Stories, headlines and publisher text are the interface. Chrome recedes; nothing decorative competes with a headline.
2. **Native before custom.** Use the system component whenever one exists: `NavigationSplitView`, toolbars, sidebar lists, `searchable`, menus, `Form`, `ContentUnavailableView`, standard button styles. A custom component needs a reason the system one cannot meet, stated in the PR.
3. **Glass is for controls, not content.** Liquid Glass belongs to the floating control layer. Cards, rows, reader text, summaries and tags never use it.
4. **Hierarchy through type, space and grouping.** Express importance with typographic scale, spacing and grouping, not borders, gradients, shadows or color.
5. **One way to do each thing.** Every color, font, spacing, radius and motion value comes from `Sources/Views/DesignSystem.swift`; every glass surface goes through `Sources/Views/GlassSystem.swift`; every repeated pattern has one component (section 18).
6. **Calm and honest.** Motion confirms an action and never decorates. Generated content is always labeled; publisher text is never restyled into something it is not.
7. **Accessible and adaptive by default.** Every view works in light and dark, with Increase Contrast, Reduce Transparency, Reduce Motion, keyboard-only use and narrow windows, and on macOS 15 without Liquid Glass.

## 2. Platform baseline

- Deployment target macOS 15; build with Xcode 27 and the macOS 27 SDK ([ARCHITECTURE.md](ARCHITECTURE.md)).
- **macOS 26 and later:** Liquid Glass through system components first, then the glass APIs in section 3. Gate with `if #available(macOS 26, *)`, never with `#if canImport(...)` or other SDK proxies.
- **macOS 27:** refinements are automatic and must not be fought: the Liquid Glass transparency slider (clear to tinted), sidebars extending to the window edges with semibold selection, glass on bordered toolbar items over the sidebar, hard scroll edges when free-floating title text is in the title bar, interactive glass tuned for the pointer and dimming of inactive windows. Never assume a particular transparency level; check legibility at both ends of the slider.
- **macOS 15:** the same layout and components with system materials and standard controls. Never imitate glass with gradients, specular strokes or stacked materials on any version.
- An API newer than macOS 15 is used only behind `if #available`, with a macOS 15 path that keeps the feature usable. `visibilityPriority(_:)` needs macOS 26.1.

## 3. Layers and Liquid Glass

### 3.1 Layer model

| Layer | Contains | Surface |
| --- | --- | --- |
| Content | Masthead, story lists and grids, cards, event coverage, reader, overview, empty states, settings forms | Window background, `AppColor.surface`, system materials only where the HIG asks for them |
| Controls | Toolbar, sidebar, search field, floating controls over scrolling content | Liquid Glass (system or section 3.2) |
| Presentation | Menus, popovers, sheets, alerts, dialogs | System presentation styles, unmodified |

### 3.2 Where glass is allowed

1. **System glass (preferred).** Toolbar items, the sidebar, the search field, segmented controls and buttons in the toolbar, menus, popovers, sheets and alerts adopt glass by themselves. Never restyle, re-tint or put a background behind them.
2. **Custom glass, macOS 26 and later only.** A control that floats over scrolling content and is not in the toolbar: the queued-updates pill, floating Web-view or media controls, a future floating "back to overview" control. At most one tinted (prominent) glass control per view, and only for the primary action.
3. **Never glass.** Cards, list and sidebar rows, event coverage, tags and badges in content, the reader column, AI summary and overview panels, section headers, banners inside content, settings content, scroll backgrounds, anything nested in another glass surface.

### 3.3 Implementation rules

- Use the helpers in `GlassSystem.swift` (`nativeLiquidGlass(in:interactive:)`, `inGlassContainer()`, `nativeGlassButtonStyle(prominent:)`). Do not call `glassEffect` or create a `GlassEffectContainer` directly in a feature view.
- Buttons on glass use `.buttonStyle(.glass)` or `.buttonStyle(.glassProminent)` through the helper. Custom glass controls that respond to clicks are `interactive`.
- Apply glass as the last modifier, after padding and frame, so the padding is part of the glass shape. Glass helpers never add padding of their own. Never nest glass.
- Group adjacent glass elements in one `GlassEffectContainer` so they sample once and can morph. Morph only with `glassEffectID(_:in:)` inside a container and an animation gated by Reduce Motion.
- Use the `regular` variant. `clear` is allowed only over images or video, with a dimming layer when the media is bright. `tint` only conveys meaning (a primary action or state), never decoration.
- Custom glass and custom controls in the control layer dim in inactive windows using `@Environment(\.appearsActive)`, as system controls do.
- Do not add Reduce Transparency or Increase Contrast branches for system glass; the system adapts it. The macOS 15 fallback (`.regularMaterial`, or `AppColor.surface` with a separator stroke under Reduce Transparency) is the only manual branch.
- No glass in high-frequency or scrolling content: it costs GPU time and competes with content.
- Never use `toolbarBackground`, `toolbarBackgroundVisibility(.visible, ...)`, opaque views behind the toolbar, or materials behind the sidebar. They block the glass and the scroll edge effect.

### 3.4 Scroll edges and pinned content

- Leave the scroll edge effect on `automatic`. Do not force `.soft` or `.hard` globally; macOS chooses hard where title text or controls without backgrounds sit over content.
- Content that must stay pinned above a scroll view uses `safeAreaBar(edge:)` on macOS 26 and later (`safeAreaInset` on macOS 15), so the edge effect extends beneath it. One edge effect style per scroll view; never stack soft and hard.
- Editorial content (the masthead) scrolls with the content; it is not pinned.
- Hero imagery that sits next to the sidebar may extend beneath it with `backgroundExtensionEffect()` (macOS 26+), applied to the image only, with text and controls layered above it. The image must touch the leading and trailing edges of the column.

## 4. Window structure and navigation

- Main window: `NavigationSplitView` with the sidebar column and a detail `NavigationStack` (list, then reader). Do not add a third column or nested split view without updating this document.
- The system sidebar toggle is the only sidebar toggle. Never draw a second one in content.
- Each window sets `navigationTitle` to the current location ("Today", "Saved Stories", the story's publisher in the reader), never the app name. Where the content already shows that title (the list masthead, the reader eyebrow), hide the duplicate toolbar title with `toolbar(removing: .title)`; the window title still names the window in Mission Control and the Window menu.
- Secondary windows (News Tension) and sheets (Feed Catalog) follow the same rules. Sheets use system sizing and background; no custom `presentationBackground`.
- In full screen the reader shows the toolbar on hover: `windowToolbarFullScreenVisibility(.onHover)`.
- Do not put critical controls or information at the bottom of a window or sidebar.
- Minimum main window size: 900 × 600. Layouts must work from that size to a full-screen 6K display; wide windows widen margins, never the reading measure.
- An inspector (`inspector(isPresented:)`) is the place for secondary detail about the selection, if one is added. It is not added without a plan entry.

## 5. Toolbar

- All window chrome actions live in the toolbar, not in content. Content may hold actions that act on that content (Retry, Show Muted Stories, Read Original).
- Placement:

| Area | List | Reader |
| --- | --- | --- |
| Leading (`.navigation`) | System sidebar toggle | Back, Previous Story, Next Story |
| Center (`.principal`) | Nothing | Mode picker (Overview, Story, Web) |
| Trailing (`.primaryAction`) | View options group (group by event, list or grid), Refresh, New Briefing when in Briefing | Save and Share group, Reading options, Web back and forward while in Web mode |

- Search sits at the far trailing end in both states (section 7).
- At most three visual groups per toolbar. Group by function with `ToolbarItemGroup` and `ToolbarSpacer(.fixed)` (macOS 26+). Non-interactive items (status text, progress) use `sharedBackgroundVisibility(.hidden)`.
- Icon-only items use an SF Symbol without a border, a `Label` with a text title (for VoiceOver and the overflow menu) and a `.help` tooltip naming the action and its shortcut. Keep text-labeled items in their own group.
- The prominent style is reserved for the single most likely action, when a view has one; the list and reader have none.
- When the window narrows, items move into the system overflow menu. Mark items that must stay visible with `visibilityPriority(.high)` (macOS 26.1+); never build a custom overflow menu.
- Every toolbar action also exists in the menu bar (section 15).
- Prefer customizable toolbars (`toolbar(id:)`) for windows people keep open for long periods; system defaults stay sensible without customization.

## 6. Sidebar

- `List(selection:)` with `.listStyle(.sidebar)`. Rows are `Label(title, systemImage:)` with `.tag(_:)`; never wrap a row in a `Button`. Counts use `.badge(_:)`.
- Sections: Inbox (Today, Unread, Briefing), Library (Saved Stories, History), Sections (the reader's own) and Suggested. Two levels of hierarchy at most.
- Symbols are SF Symbols in the system accent color, which follows the person's accent setting. A fixed symbol color is allowed only when it carries meaning.
- No backgrounds, materials or custom selection drawing. Row height, text and symbol size follow the person's sidebar size setting, so never set fonts or frames on sidebar rows.
- Progress in a row uses `ProgressView().controlSize(.mini)`; never scale a control with `scaleEffect`.
- Transient confirmations (OPML imported, feed added) never insert rows into the list; use an alert, a toolbar status item or the masthead status line.

## 7. Search

- One primary search across the archive, declared once on the `NavigationSplitView` with `searchable`. Placement is the trailing end of the toolbar, where results appear in the detail column (HIG search fields, WWDC26 "Design intuitive search experiences").
- Filter operators (`is:unread`, `is:read`, `is:saved`, `source:`, `category:`) are offered as suggestions while typing and should become search tokens (`searchable(text:tokens:...)`), paired with the suggestions that teach them.
- Predictive suggestions are few and visibly complete what was typed.
- No results: `ContentUnavailableView.search(text:)` showing the query. Never a blank list and never a feed-refresh suggestion.

## 8. Content layer: lists, cards and states

### 8.1 Masthead

The list starts with a masthead in the scroll content: the location title (`AppTypography.masthead`), then one status line in `AppTypography.caption` and the secondary color: story count, grouped events, last update and inline content actions (waiting stories, muted stories). The masthead scrolls away under the toolbar. Controls are not part of it (section 5).

### 8.2 Story card

One card component for list, grid, Briefing, search, Saved Stories and History.

| Part | Rule |
| --- | --- |
| Lead image | Publisher image or the editorial placeholder; fixed aspect per layout; decorative for accessibility |
| Eyebrow | Publisher name, `AppTypography.eyebrow`, uppercase by `.textCase(.uppercase)`, secondary color |
| Headline | `AppTypography.cardHeadline` for the layout; at most two lines; keeps priority over the dek |
| Dek | Feed summary, two lines, secondary color |
| Footer | Relative or short date in `caption`; state glyphs (saved, AI summary available) |
| Unread | Accent dot plus primary-color headline; read stories use the secondary color, never opacity alone |
| Hover | Accent border at 40 % and the hover shadow token |
| Keyboard focus | Accent ring (1.5 pt) and focus shadow token |

Cards use `AppColor.surface`, the card radius, a separator-color hairline and the resting shadow token. No gradients, glass or extra tinting. Every action on a card is also in its context menu and in its accessibility actions.

### 8.3 Event coverage

An event card is a story card followed by a coverage disclosure row (`AppTypography.label`, `square.stack.3d.up` symbol, coverage text, last update, "Updated" tag) and, when expanded, the member list in one content surface. Members are rows with an unread dot, eyebrow, title and date. Coverage never claims more than the stored sources show.

### 8.4 States

- Empty, error and no-results states use `ContentUnavailableView` with a symbol, title, description and at most two actions. Diagnostic detail goes in a `DisclosureGroup` under it.
- Loading a list or a story body shows `ProgressView` with a visible label; small inline indicators (event sources, a sidebar row) carry an accessibility label instead.
- Queued updates appear as the floating glass updates pill (custom glass, section 3.2) at the top of the list, announced to VoiceOver; the list never moves under the reader.
- Inline notices (citation highlight, extraction fallback) are content callouts: `AppColor.surface` or a 10–12 % semantic tint, the card radius, symbol plus text. Not glass.

## 9. Reader

- One reading column of `AppLayout.readingMeasure` points, scaled by `min(textScale, 1.3)`, centered, with `AppLayout.pageInset` margins. The article reader and the event overview share it.
- Order: cited-passage notice, eyebrow (publisher · date · reading time), headline, publisher updates, lead figure, on-device summary disclosure, divider, body, terminal affordance.
- Typography comes from the reading style (Casper serif, Edition sans, Alto mono) through `AppTypography` functions; headings, quotes, lists, captions and code all have reader tokens. Body text is selectable.
- Text size is one persisted preference applied to every story, adjustable from the View menu (Make Text Bigger ⌘+, Make Text Smaller ⌘−, Actual Size ⌘0) and the Reading options control.
- Figures fill the measure, never crop, and carry caption and credit in `readerCaption`.
- Generated content (summary, overview introduction, key facts) is labeled with the intelligence label, collapsible where it precedes publisher text, and never styled as publisher text.
- The terminal affordance uses standard bordered buttons: Open Web View, and Open in Browser.
- Web mode keeps the protected-preview status line in content and the navigation controls in the toolbar.

## 10. Typography

macOS has no Dynamic Type. Chrome uses system text styles so it matches system controls; editorial text uses the reader tokens and the reader text scale. Never write `.font(.system(size:))` outside `DesignSystem.swift`.

| Token | Use | Definition |
| --- | --- | --- |
| `masthead` | List title | `.largeTitle.bold()` (26 pt) |
| `title` | Sheet and window headings, overview title fallback | `.title.bold()` (22 pt) |
| `sectionTitle` | Headings inside content (overview sections, groups) | `.title3.weight(.semibold)` (15 pt) |
| `headline` | Row titles and emphasized labels | `.headline` (13 pt bold) |
| `body` | Chrome body text | `.body` (13 pt) |
| `callout` | Secondary descriptions | `.callout` (12 pt) |
| `label` | Disclosure rows, tags, inline controls | `.callout.weight(.medium)` |
| `caption` | Dates, counts, status lines | `.subheadline` (11 pt) |
| `eyebrow` | Publisher and kicker | `.caption2.weight(.semibold)`, tracking `AppTypography.eyebrowTracking`, uppercase via `textCase` |
| `cardHeadline(_:)` | Card headlines | List: serif 20 pt semibold; grid: 15 pt semibold |
| Reader tokens | Reader and overview | `titleFont`, `leadFont`, `bodyFont`, heading, quote, caption and code functions of style and text scale |

- The system serif (`design: .serif`) is for editorial headlines and the Casper style only.
- Never uppercase strings in code; use `.textCase(.uppercase)` so VoiceOver reads words, not letters.
- Counts and times that update in place use `.monospacedDigit()`.
- Line spacing comes from the reading style; on macOS 26 and later the reader may use `lineHeight(_:)` through a token.

## 11. Color

- System semantic colors only, through `AppColor`. No literal colors (`Color.blue`, hex, RGB) outside `DesignSystem.swift`.
- Text: the system label colors (primary, secondary, tertiary, quaternary) through `AppColor`. Hierarchy never comes from lowering the opacity of primary text; the reader's softened body color is a reader token that returns to full contrast with Increase Contrast.
- Accent: the person's system accent. It marks selection, focus, unread state, links, the active mode and at most one prominent action per view. Never decoration, never toolbar icons except a meaningful state, never large fills. The app defines no brand accent; if one is introduced, it goes in an asset catalog `AccentColor` with light, dark and increased-contrast values.
- Intelligence (warm gold): only for labels and glyphs of generated content. Never body text or glass tint.
- Status: success, warning and danger system colors for icons and small fills; text stays in the label colors. Yellow never carries text.
- Fills: tags and neutral badges use the badge fill token; accent fills are 12 % (22 % with Increase Contrast).
- Separators: `AppColor.borderSubtle` maps to the system separator color; with Increase Contrast, borders use the contrast tokens already defined for the reader.
- Light and dark are designed together; every new color token has both values and an increased-contrast value. The in-app appearance override stays optional and defaults to System.

## 12. Shape, spacing and elevation

- Spacing uses `AppSpacing` (4 pt grid: 4, 8, 12, 16, 24, 32, 48). Two micro steps exist for text clusters only: 2 pt between stacked text lines and 6 pt between an eyebrow's parts. No other literal padding or spacing.
- Radii: `AppRadius.control` (6) for small rectangles, `card` (12), `container` (16), and `Capsule()` for tags and pills. Use continuous corners. On macOS 26 and later, a shape inside another rounded container or near the window corner is concentric: `ConcentricRectangle(corners: .concentric(minimum: .fixed(AppRadius.card)), isUniform: true)`.
- Never hard-code control heights or toolbar heights; the system owns them and changed them in macOS 26.
- Elevation: content cards use the resting, hover and focus shadow tokens only. Glass brings its own depth; never add shadows to glass or system controls.
- Layout tokens: `pageInset` 24, `sectionGap` 24, `cardGap` 16, list maximum width 1000, grid columns adaptive 300–420, `readingMeasure` 720.

## 13. Motion

- Use `AppMotion` (hover, state, navigation, modal) or the system's own animation. Every explicit animation is `nil` when `effectiveReduceMotion` is true; symbol effects stop too.
- Animate state the person caused (expand, save, mode switch, applying queued updates). Never animate content arriving from a refresh while the person is reading.
- Glass morphs only between related controls in one container. No parallax, auto-playing motion, confetti or attention-seeking pulses.

## 14. Symbols and menus

- SF Symbols only, monochrome by default; `.fill` variants mark the selected or active state (filled bookmark when saved, filled stack when grouping is on).
- One symbol per concept everywhere: bookmark (save), `square.and.arrow.up` (share), `safari` (open in browser), `globe` (Web view), `doc.richtext` (reader), `sparkles` (generated content), `square.stack.3d.up` (event coverage), `speaker.slash` (mute), `arrow.clockwise` (refresh). Don't reuse a symbol for a different meaning.
- Context menus order: read state, save, mute, divider, copy link, open in browser, share, then corrective actions ("Not the Same Event") in their own section. Within a section, give every item a symbol or none. On macOS 27 the menu bar shows icons only for key actions by default; use `labelStyle(.titleAndIcon)` only to surface a key feature.

## 15. Commands, keyboard and pointer

- Every toolbar action has a menu bar command; every frequent command has a keyboard shortcut shown in its menu item. Never reuse a standard window or app shortcut (close, minimize, hide, quit, settings, full screen) for anything else; a standard document shortcut whose action does not exist here (⌘O, ⌘J) may carry a close meaning, such as Open in Browser or the next story (HIG keyboards).
- Menus: View holds layout (as List, as Grid), Group Stories by Event, text size and the sidebar; Navigate holds sections, story movement and queued updates; a Story menu holds actions on the focused or open story (read state, save, open in browser, share, Reader or Web), as Mail's Message menu does; Help lists keyboard shortcuts.
- Single-key shortcuts (J, K, M, S, O and the others in the shortcuts list) work only while the list or reader has focus and never with ⌘, ⌃ or ⌥ held.
- Every icon-only control has `.help`. Hover and focus states come from the system or the card tokens; never remove the focus ring without providing the card focus state.
- Drag and drop: OPML files and feed URLs onto the window or sidebar; feedback through the drop-target highlight and the result notice rules in section 6.

## 16. Accessibility

- Read `effectiveReduceMotion` and `effectiveContrast` (not the raw environment values), so isolated QA overrides apply.
- Every control has a label; icon-only controls have `Label` titles or `accessibilityLabel`. Labels never include shortcut suffixes.
- Cards combine into one element with a full description and named actions. Headlines and reader headings carry heading traits and levels.
- Reader paragraphs of one story may be linked with `accessibilityLinkedGroup(id:in:)` for continuous reading.
- State never relies on color alone: unread has a dot and a label, saved has a glyph, modes have text.
- Increase Contrast uses the contrast tokens (stronger dividers, borders, fills); Reduce Transparency applies only to the macOS 15 material fallback.
- Live spoken VoiceOver verification is parked (#268); code-level accessibility above is not.

## 17. Copy

- Title Case for buttons, menu items, toolbar labels and window titles; sentence case for descriptions, help tooltips and status lines.
- "Story" is the user-facing word for an item; "publisher" for its source; "event" and "coverage" for grouped reports. Avoid "article" in new UI text.
- Never claim more than the data shows: feed health is operational, not a quality rating; publisher updates are not verified corrections; overviews are generated and cite sources.
- No exclamation marks, no marketing adjectives, no "AI magic".

## 18. Components

Each pattern has one implementation; new code reuses it and extends it rather than copying.

| Component | Owner (current or planned) | Covers |
| --- | --- | --- |
| Tokens | `DesignSystem.swift` | Color, typography, spacing, radius, layout, shadow, motion |
| Glass helpers | `GlassSystem.swift` | Custom glass, glass containers, glass button style, macOS 15 fallback |
| Story card | `ArticleCardView.swift` | All story cards and their context menus |
| Event coverage | `EventCardView.swift` | Coverage disclosure and member rows |
| Tag | Planned in `DesignSystem.swift` | Category, entity, Updated, Plan, AI, Verified Excerpts and citation pills |
| Eyebrow | Planned in `DesignSystem.swift` | Publisher and kicker lines in cards, reader and overview |
| Intelligence label | Planned in `DesignSystem.swift` | Every generated-content heading and badge |
| Masthead | `ArticleListView.swift` | List title and status line |
| Updates pill | `ArticleListView.swift` | Queued-update control (custom glass) |
| Notice | Planned in `DesignSystem.swift` | Inline callouts in content |
| Reading column | Planned in `DesignSystem.swift` | Measure and insets for reader and overview |
| Empty states | `ContentUnavailableView` | All empty, error and no-result states |

## 19. Review checklist

Copy into the PR description for UI changes and tick only what was checked.

- [ ] No new literal font size, color, spacing, radius or control height outside `DesignSystem.swift`.
- [ ] Glass only where section 3.2 allows it, through `GlassSystem.swift`, not nested, macOS 15 path present.
- [ ] No toolbar or sidebar background, no forced scroll edge style.
- [ ] Toolbar placement, grouping, tooltips and labels follow section 5; every toolbar action has a menu command.
- [ ] Sidebar, search and empty states use the system components in sections 6–8.
- [ ] Light, dark, Increase Contrast, Reduce Motion and Reduce Transparency checked, plus macOS 15 when the change gates an API; macOS 27 glass checked at clear and tinted when glass is involved.
- [ ] Narrow (900 pt) and wide windows checked; keyboard path works.
- [ ] Copy follows section 17.

## 20. Changing this document

Change the rules here first, in a focused PR with the reason and the evidence, and update the tokens in `DesignSystem.swift` or the helpers in `GlassSystem.swift` in the same PR when they change. Mars approves changes to this document. A one-off exception is recorded in the PR that needs it; a recurring exception becomes a rule.
