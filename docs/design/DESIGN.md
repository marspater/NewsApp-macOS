# Design language

The design language for News on macOS: principles, native UI, tokens, glass, accessibility, interaction and the review rules. It applies to every change that adds or modifies UI, by any contributor or agent. Where it is silent, follow Apple's [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines) (HIG); where it conflicts with the HIG, this document wins until it is changed. Technology constraints stay in [ARCHITECTURE.md](../ARCHITECTURE.md); the evidence behind these rules is in the [Apple News and Liquid Glass study](../audits/2026-10-09-apple-news-liquid-glass-study.md), and the migration of existing code is in the [adoption plan](../plans/2026-10-09-design-language-adoption.md).

Feature rules live beside this file. This file owns whatever applies to more than one surface; a feature document owns what applies only to its surface.

| Document | Owns |
| --- | --- |
| [today.md](today.md) | Lane presentation, the six card variants, The Lead, scrolling, keyboard focus, updates and empty states |
| [briefing.md](briefing.md) | The five pillars, module composition, editorial structure, the carousel's content and generated-content labels |
| [notifications.md](notifications.md) | Notification presentation, interruption policy, content and foreground behaviour |
| [implementation-notes.md](implementation-notes.md) | Platform workarounds, AppKit bridges, known bugs and OS-version restrictions |

**Precedence.** Written rules decide. Approved visual references are kept in the repository under `docs/mocks/` and illustrate the rules. When a reference and a rule disagree, the rule wins and the same PR corrects whichever is wrong. An external design canvas is a working tool, never the specification.

**Must** and **never** are requirements. **Should** allows a documented exception in the PR description. **Target** marks a rule or token that a named issue delivers; until it lands, the current code and tokens stand. Code that predates this document is migrated by the adoption plan; a change that touches a view must not add a new deviation and should fix the deviations in the lines it edits.

## 1. Principles

1. **Content first.** Stories, headlines and publisher text are the interface. Chrome recedes; nothing decorative competes with a headline.
2. **Native before custom.** Use the system component whenever one exists: `NavigationSplitView`, toolbars, sidebar lists, `searchable`, menus, `Form`, `ContentUnavailableView`, standard button styles. A custom component needs a reason the system one cannot meet, stated in the PR.
3. **Glass is for controls, not content.** Liquid Glass belongs to the floating control layer. Cards, rows, reader text, summaries and tags never use it.
4. **Hierarchy through type, space and grouping first.** Express importance with typographic scale, spacing and grouping. Borders, shadows, gradients and color are legitimate depth tools when they stay subordinate to typography and content: they separate planes and show state, and they never rank stories or compete with a headline.
5. **One way to do each thing.** Every color, font, spacing, radius and motion value comes from `Sources/Views/DesignSystem.swift`; every repeated pattern has one component (section 18).
6. **Calm and honest.** Motion confirms an action and never decorates. Generated content is labeled once per page, in plain words that say how it was made; publisher text is never restyled into something it is not.
7. **Accessible and adaptive by default.** Every view works in light and dark, with Increase Contrast, Reduce Transparency, Reduce Motion, keyboard-only use and narrow windows, and on macOS 15 without Liquid Glass.

## 2. Platform baseline

- Deployment target macOS 15; build with Xcode 27 and the macOS 27 SDK ([ARCHITECTURE.md](../ARCHITECTURE.md)).
- **macOS 26 and later:** Liquid Glass through system components first, then the glass APIs in section 3. Gate with `if #available(macOS 26, *)`, never with `#if canImport(...)` or other SDK proxies.
- **macOS 27:** refinements are automatic and must not be fought: the Liquid Glass transparency slider (clear to tinted), sidebars extending to the window edges with semibold selection, glass on bordered toolbar items over the sidebar, hard scroll edges when free-floating title text is in the title bar, interactive glass tuned for the pointer and dimming of inactive windows. Never assume a particular transparency level; check legibility at both ends of the slider.
- **New in macOS 27 to design for:** a dedicated Show Borders setting (section 16) and direct touch on a touch display or Sidecar (section 15). Where a feature needs them, and behind `if #available(macOS 27, *)`: `swipeActionsContainer()` for swipe actions outside `List`, and `.reorderable()` for drag-to-reorder in any container (the Customize Briefing sheet). The scroll behaviours of `toolbarMinimizeBehavior`, `ToolbarOverflowMenu` and `.topBarPinnedTrailing` are not for macOS; keep the system overflow of section 5.
- **macOS 15:** the same layout and components with system materials and standard controls. Never imitate glass with gradients, specular strokes or stacked materials on any version. A content card's edge highlight (section 12) is depth on an opaque surface, not glass.
- An API newer than macOS 15 is used only behind `if #available`, with a macOS 15 path that keeps the feature usable. `visibilityPriority(_:)` needs macOS 26.1.

## 3. Layers and Liquid Glass

### 3.1 Layer model

| Layer | Contains | Surface |
| --- | --- | --- |
| Content | Masthead, story lists and grids, cards, event coverage, Briefing board, reader, overview, grouped sheet content, empty states, settings forms | Window background, `AppColor.surface`, system materials only where the HIG asks for them |
| Controls | Toolbar, sidebar, search field, floating controls over scrolling content | Liquid Glass (system or section 3.2) |
| Presentation | Menus, popovers, sheets, alerts, dialogs | System presentation styles, unmodified |

### 3.2 Where glass is allowed

1. **System glass (preferred).** Toolbar items, the sidebar, the search field, segmented controls and buttons in the toolbar, menus, popovers, sheets and alerts adopt glass by themselves. Never restyle, re-tint or put a background behind them.
2. **Custom glass, macOS 26 and later only.** A control that floats over content and is not in the toolbar: the story banner ([notifications.md](notifications.md)), the arrows and page dots of a hero carousel (section 13.1), floating Web-view or media controls. A new floating control qualifies by this definition, without a change to this list. At most one tinted (prominent) glass control per view, and only for the primary action.
3. **Never glass.** Cards, list and sidebar rows, event coverage, tags and badges in content, the reader column, AI summary and overview panels, section headers, banners inside content, settings content, scroll backgrounds, anything nested in another glass surface.

### 3.3 Implementation rules

- Custom glass goes through one reusable helper in `DesignSystem.swift`, with its macOS 15 fallback. `BannerSurface` is that helper today; the hero carousel's floating controls extend it (Z3, #935). Do not call `glassEffect` or create a `GlassEffectContainer` directly in a feature view; `script/design_lint.sh` counts direct calls.
- Buttons on glass use `.buttonStyle(.glass)` or `.buttonStyle(.glassProminent)` through the helper. Custom glass controls that respond to clicks are `interactive`.
- Apply glass as the last modifier, after padding and frame, so the padding is part of the glass shape. Glass helpers never add padding of their own. Never nest glass.
- Group adjacent glass elements in one `GlassEffectContainer` so they sample once and can morph. Morph only with `glassEffectID(_:in:)` inside a container and an animation gated by Reduce Motion.
- Use the `regular` variant. `clear` is allowed only over images or video, with a dimming layer when the media is bright. `tint` only conveys meaning (a primary action or state), never decoration.
- Custom glass and custom controls in the control layer dim in inactive windows using `@Environment(\.appearsActive)`, as system controls do.
- Do not add Reduce Transparency or Increase Contrast branches for system glass; the system adapts it. The macOS 15 fallback (`.regularMaterial`, or `AppColor.surface` with a separator stroke under Reduce Transparency) is the only manual branch.
- No glass in high-frequency or scrolling content: it costs GPU time and competes with content.
- Glass has no external drop shadow and no drawn 3D border; refraction and the system's vibrancy define its edge.
- Never use `toolbarBackground`, `toolbarBackgroundVisibility(.visible, ...)`, opaque views behind the toolbar, or materials behind the sidebar. They block the glass and the scroll edge effect.

### 3.4 Scroll edges and pinned content

- Leave the scroll edge effect on `automatic`. Do not force `.soft` or `.hard` globally; macOS chooses hard where title text or controls without backgrounds sit over content.
- Content that must stay pinned above a scroll view uses `safeAreaBar(edge:)` on macOS 26 and later (`safeAreaInset` on macOS 15), so the edge effect extends beneath it. One edge effect style per scroll view; never stack soft and hard.
- Editorial content (the masthead) scrolls with the content; it is not pinned.
- Hero imagery that sits next to the sidebar may extend beneath it with `backgroundExtensionEffect()` (macOS 26+), applied to the image only, with text and controls layered above it. The image must touch the leading and trailing edges of the column. The Lead of the Today edition (section 8.8) is such a hero: its image spans the column edge to edge and continues under the sidebar, with its text and controls layered above it; macOS 15 shows the same full-width image without the extension. Inset cards inside a scroll view never use it: the effect bleeds the image into the toolbar while the inset leaves the toolbar edges uncovered. Today's inset lead story card is replaced by The Lead when Z3 (#935) lands.

## 4. Window structure and navigation

- Main window: `NavigationSplitView` with the sidebar column and a detail `NavigationStack` (list, then reader). Do not add a third column or nested split view without updating this document.
- The system sidebar toggle is the only sidebar toggle. Never draw a second one in content.
- Each window sets `navigationTitle` to the current location ("Today", "Saved Stories", the story's publisher in the reader), never the app name. Where the content already shows that title (the list masthead, the reader eyebrow), hide the duplicate toolbar title with `toolbar(removing: .title)`; the window title still names the window in Mission Control and the Window menu.
- Secondary windows (Keyboard Shortcuts) and sheets (Feed Catalog, World Tension) follow the same rules. Sheets use system sizing and background; no custom `presentationBackground`. A sheet is modal to its window and closes with a close button and Esc. A sheet keeps one width while it is open: content that recomputes (suggested topics after subscribing) never resizes it. A filter with more than five options inside a sheet is a scrolling `TagView` row or a menu `Picker`, never a segmented control that has to fit the width.
- In full screen the reader shows the toolbar on hover: `windowToolbarFullScreenVisibility(.onHover)`.
- Do not put critical controls or information at the bottom of a window or sidebar.
- Minimum main window size: 900 × 600. Layouts must work from that size to a full-screen 6K display; wide windows widen margins, never the reading measure.
- An inspector (`inspector(isPresented:)`) is the place for secondary detail about the selection, if one is added. It is not added without a plan entry.

## 5. Toolbar

- All window chrome actions live in the toolbar, not in content. Content may hold actions that act on that content (Retry, Show Muted Stories, Read Original).
- Placement:

| Area | List | Reader |
| --- | --- | --- |
| Leading (`.navigation`) | System sidebar toggle, queued-stories button; in Briefing, Back first | Back, Previous Story, Next Story |
| Center (`.principal`) | Nothing | Mode picker (Overview, Story, Web) |
| Trailing (`.primaryAction`) | View options group (group by event, list or grid), Refresh, New Briefing when in Briefing | Save and Share group (with Check for Updates while the overview shows), Reading options, Web back and forward while in Web mode |

- Search sits at the far trailing end in both states (section 7).
- At most three visual groups per toolbar. Group by function with `ToolbarItemGroup` and `ToolbarSpacer(.fixed)` (macOS 26+). Non-interactive items (status text, progress) use `sharedBackgroundVisibility(.hidden)`.
- Icon-only items use an SF Symbol without a border, a `Label` with a text title (for VoiceOver and the overflow menu) and a `.help` tooltip naming the action and its shortcut. Keep text-labeled items in their own group.
- The prominent style is reserved for the single most likely action, when a view has one; the list and reader have none.
- When the window narrows, items move into the system overflow menu. Mark items that must stay visible with `visibilityPriority(.high)` (macOS 26.1+); never build a custom overflow menu.
- Every toolbar action also exists in the menu bar (section 15).
- Prefer customizable toolbars (`toolbar(id:)`) for windows people keep open for long periods; system defaults stay sensible without customization.

## 6. Sidebar

- `List(selection:)` with `.listStyle(.sidebar)`. Rows are `Label(title, systemImage:)` with `.tag(_:)`; never wrap a row in a `Button`. Counts use `.badge(_:)`. The Unread badge counts the cards the Unread list shows (a story several reports cover is one) and reads "99+" past 99, where the exact number is not one anyone acts on; VoiceOver still hears it. A section header's button ends where the row badges end (`AppLayout.sidebarHeaderActionInset`, measured by `Tests/Harness/SidebarCaptures.swift`).
- Sections: Inbox (Today, Unread, Briefing), Library (Saved Stories, History), Sections (the reader's own). Two levels of hierarchy at most.
- Symbols are SF Symbols in the system accent color, which follows the person's accent setting. A fixed symbol color is allowed only when it carries meaning.
- No backgrounds, materials or custom selection drawing. Row height, text and symbol size follow the person's sidebar size setting, so never set fonts or frames on sidebar rows.
- Progress in a row uses `ProgressView().controlSize(.mini)`; never scale a control with `scaleEffect`.
- Transient confirmations (OPML imported, feed added) never insert rows into the list; use an alert, a toolbar status item or the masthead status line.
- With panel collection on, the sidebar foot shows the World Tension assessment (degrees, band and status dot) in a `safeAreaInset`, not as a list row; it opens the World Tension sheet. Its status dot is static and uses the assessment band color. Animated illustrations belong only inside the World Tension sheet; each band has distinct motion, paused when inactive or Reduce Motion is on. The label denotes an AI assessment, not an objective probability of catastrophe.

Predefined categories are selected in Settings → General; Suggested rows are not shown in navigation. Settings tabs share stable 720 × 560 content bounds. A tab's own settings are a native scrollable form; comparing many items opens a sheet from that tab with a native sortable `Table` (Publisher Health, #715).

## 7. Search

- One primary search across the archive, declared once on the `NavigationSplitView` with `searchable`. Placement is the trailing end of the toolbar, where results appear in the detail column (HIG search fields, WWDC26 "Design intuitive search experiences").
- Search rests as a compact native toolbar button in both list and reader, expanding on focus and collapsing when dismissed with an empty query. A narrow AppKit bridge bounds the native search item; SwiftUI retains search focus, tokens and system glass.
- Free text ranks stories by meaning as well as by their words when the on-device embedder is available (#708), so a story can match without the exact words; without it, and for a quoted phrase, search ranks by words alone. A search of filter operators only stays newest first.
- Filter operators (`is:unread`, `is:read`, `is:saved`, `source:`, `category:`) are offered as suggestions while typing and should become search tokens (`searchable(text:tokens:...)`), paired with the suggestions that teach them.
- Predictive suggestions are few and visibly complete what was typed.
- No results: `ContentUnavailableView.search(text:)` showing the query. Never a blank list and never a feed-refresh suggestion.

## 8. Content layer: lists, cards and states

### 8.1 Masthead

The list starts with a masthead in the scroll content: the location title (`AppTypography.masthead`), then one status line in `AppTypography.caption` and the secondary color: story count, grouped events, last update and any transient notice. The masthead displays status only and scrolls away under the toolbar. Controls are not part of it (section 5), and queued stories belong to the toolbar (section 8.5). The one exception is the muted-stories menu ("12 hidden by muting"), which appears only while muting hides stories and acts on the list below it.

### 8.2 Story card

One card component, `ArticleCardView`, for list, grid, Briefing, search, Saved Stories, History and the Today edition. Every presentation shares this anatomy; the table after it sets what differs, and [today.md](today.md) gives the Today variants in full.

| Part | Rule |
| --- | --- |
| Lead image | The story's publisher image or, on an event card, the image of any report in the event (hidden panel-feed reports included); otherwise the editorial placeholder. Fixed aspect per layout, clipped to its frame and never a click target outside it; fetched before the card scrolls into view where possible, and the placeholder fades into the image with `AppMotion.state` (`nil` under Reduce Motion); decorative for accessibility |
| Eyebrow | Publisher name, `AppTypography.eyebrow`, uppercase by `.textCase(.uppercase)`, secondary color |
| Headline | `AppTypography.cardHeadline` for the layout, within the presentation's line limit; keeps priority over the dek |
| Dek | Feed summary, within the presentation's line limit, secondary color. In search results with a word match in the feed summary or the body, the publisher's words around it instead (`SearchExcerptText`): matched words in `AppTypography.bodyMatch` (semibold) and the primary color, so weight carries the match without color; a match in the headline only, or a story found by meaning, keeps the summary. The card's accessibility label adds "Matching text:" and the excerpt |
| Footer | Relative or short date in `caption`; state glyphs (saved; the small intelligence tag when a summary exists, the only `sparkles` a list shows) |
| Unread | Lists, grids and search: accent dot plus primary-color headline. Today edition cards: no dot; an unread headline is semibold in the primary color and a read headline is medium weight in the secondary color. Read stories use the secondary color, never opacity alone, and "Unread" is always in the accessibility description |
| Hover | Accent border at 40 % and the hover elevation (section 12). The card lifts 3 pt and its image scales 1.02 inside its frame; Reduce Motion keeps the static highlight and drops the movement |
| Keyboard focus | Solid accent ring (1.5 pt) with a 2 pt offset and the focus elevation (section 12) |
| Click | The whole card is one `Button`: a single click opens the story and selects it, also as the first click on an inactive window. The coverage disclosure (section 8.3) and the context menu are the only other targets |

| Presentation | Used by | Headline lines | Dek lines |
| --- | --- | --- | --- |
| List | Lists | 2 | 2 |
| Grid | Grids | 2 | 2 |
| Lead | The Lead | 3 | 2 |
| Developing | In Motion | 2 | 2 |
| Standard | Your Beat, Outside Your Usual | 2 | 2 |
| Feature | The Deep Read | 3 | 2 |
| Coverage | Any lane, when the grouping is confident | 2 | 2 |
| Compact | The Latest | 3 | None |

In the grid a card is as tall as its own content and never stretches to the height of its row: the headline and the dek keep room for two lines each below the text, the footer keeps the intelligence tag's height, the coverage row keeps one line (its last update abbreviated, "updated 3 hr ago"), and a card without coverage keeps the coverage row's space, so the collapsed cards of a row end level. Expanding an event card's coverage grows that card alone and moves only the rows below it (#779).

Cards use `AppColor.surface`, the card radius, a separator-color hairline and the resting elevation (section 12). Cards never use glass. A gradient or tint on a card is allowed only as part of the elevation or the presentation's image treatment. Every action on a card is also in its context menu and in its accessibility actions. Cards never overlap in hit testing ([implementation-notes.md](implementation-notes.md)).

### 8.3 Event coverage

An event card is a story card followed by a coverage disclosure row (`AppTypography.label`, `square.stack.3d.up` symbol, coverage text, last update, "Updated" tag) and, when expanded, the member list in one content surface. Members are rows with an unread dot, eyebrow, title and date. Coverage never claims more than the stored sources show.

A single click on the card opens the event overview, with the lead report one more click away (its source row or the Story mode), never two. The disclosure chevron is the only control that expands the member list, and every event card can be expanded. A click on a member row opens that report.

### 8.4 Briefing

The war room: five pillars, modules, editorial structure and generated-content labels. See [briefing.md](briefing.md). Its carousel follows section 13.1.

### 8.5 States

- Empty, error and no-results states use `ContentUnavailableView` with a symbol, title, description and at most two actions. Diagnostic detail goes in a `DisclosureGroup` under it.
- Loading a list or a story body shows `ProgressView` with a visible label; small inline indicators (event sources, a sidebar row) carry an accessibility label instead.
- Queued updates have one control: the "Show N New Stories" button in the leading toolbar, system-styled and announced to VoiceOver. The masthead never repeats it, and the list never moves under the reader.
- Inline notices (citation highlight, extraction fallback) are content callouts: `AppColor.surface` or a 10–12 % semantic tint, the card radius, symbol plus text. Not glass.

### 8.6 Grouped content in sheets

A sheet that presents several kinds of information (World Tension: the reading, what is near the reader, the map, what drives it, the past 30 days) groups them into titled cards, never a flat stack of headings. Each group has a title in `AppTypography.sectionTitle` with the header trait, `AppSpacing.md` inside and `AppSpacing.lg` between groups, on the story card surface (`AppColor.surface`, card radius, separator hairline) or in a native `GroupBox`; no literal strokes or opacities. Rows that repeat (drivers, panel headlines) align their columns in a `Grid`: badge (`TagView`), publisher, headline. The sheet title carries the page's one intelligence glyph (section 9); "Assessed on this Mac" is a plain caption under it.

### 8.7 Notification banners

Presentation, interruption policy, content and foreground behaviour. See [notifications.md](notifications.md); which stories become banners is in the [delivery rules](../notifications.md).

### 8.8 Today edition

Lanes, the six card variants, The Lead, scrolling, keyboard focus, updates and states. See [today.md](today.md). Unread, Saved Stories, History, Smart Binders and search keep the list and grid of section 8.2.

## 9. Reader

- One reading column of `AppLayout.readingMeasure` points, scaled by `min(textScale, 1.3)`, centered, with `AppLayout.pageInset` margins. The article reader and the event overview share it.
- Order: cited-passage notice, eyebrow (publisher · date · reading time), headline, publisher updates, lead figure, summary panel (a closed disclosure), divider, body, terminal affordance.
- Typography comes from the reading style (Casper serif, Edition sans, Alto mono) through `AppTypography` functions; headings, quotes, lists, captions and code all have reader tokens. Body text is selectable.
- Text size is one persisted preference applied to every story, adjustable from the View menu (Make Text Bigger ⌘+, Make Text Smaller ⌘−, Actual Size ⌘0) and the Reading options control. macOS has no user-adjustable Dynamic Type, so this control is the reader's enlargement path: test it at its maximum for reflow and clipping. It should reach 200 % where possible (HIG Accessibility). *Target:* `ReaderTextSize.maximum` is 150 % today; raising it needs a reflow pass first.
- Figures fill the measure, never crop, and carry caption and credit in `readerCaption`.
- Generated content (the summary panel, the event overview, the World Tension reading) follows four rules:
  - **One glyph per page.** The `sparkles` glyph appears once, in the intelligence label that heads the generated content: the summary panel's label in the reader, the "Event overview" eyebrow in the overview, the sheet title in World Tension. Every other line about that content (how it was assembled, what it cites) is a plain `caption` in the secondary color, or the label's tooltip where space is short. No second label, no gold text.
  - **Say how it was made.** The label reads "Generated summary" when the on-device model wrote it and "Extractive summary" when sentences were selected from the story; the heading inside is "Key points". Never "AI-generated", "automated estimate" or a tone or sentiment line: sentiment stays in the data for Briefing interests and is not shown.
  - **Collapsed where it precedes publisher text.** The summary panel is a closed disclosure; the overview's sources list is collapsed by default and keeps the person's choice for the session. Expanding is the person's action, never a default.
  - **Never styled as publisher text**, and never in the intelligence color as body text (section 11).
- Text in the reader and overview never drops below `caption` (11 pt) or below the secondary color: attribution, dates and "Reported" lines use `secondaryText`; `tertiaryText` is for placeholders and disabled controls only. Quoted publisher positions (perspectives) use `primaryText`. Every text reaches 4.5:1 against its surface in light and dark.
- **Event overview evidence sections** (Epic T):
  - **Highlights** (#672): Each takeaway occupies its own row with bullet dot marker, separated by `AppSpacing.md` (16 pt) inter-gap. The cited publishers follow the takeaway inside the same text, as linked runs in the citation pill's colours that wrap with the sentence (#993); a context line below (`AppSpacing.xxs` intra-gap, inter-gap ≥ 2× intra-gap) carries the publisher attribution only when the takeaway has no citation. VoiceOver exposes 1 combined element per highlight (takeaway and source) with rotor actions to open cited sources.
  - **Timeline** (#671): A continuous connecting rail (`AppLayout.timelineRailStroke` 1.5 pt, `timelineRailWidth` 12 pt) connects events from the first marker to the last with no overshoot. Distinct marker shapes distinguish temporal status under color and grayscale: solid circle for past events with known dates, stroked outline circle for publication-only reported dates, and filled diamond (`DiamondShape`) for planned events. Chronological sort orders by event or publication date, with planned items sorted strictly last. Missing dates omit the date line; items with empty summaries are pruned. VoiceOver exposes 1 combined element per timeline row with citation actions.
  - **Perspectives** (#673): Distinct visual identity (not cards or `overviewCardSurface`). A stakeholder icon (`person.crop.circle`), participant in emphasis (`overviewFont(.emphasis)`), position below in `bodyFont` with its cited publishers as linked runs at the end of the statement (#993), the secondary attribution ("via ...") on its own line only for a wire syndicate or when there is no citation, separated by subtle dividers. Items missing either participant or position are pruned. Single-perspective stories display their single viewpoint without manufacturing false balance. VoiceOver reads participant, position, source in sequence as 1 element.
  - **Industry Impact** (#670): Conditional section appearing only when extractor detects stated practical implications (costs, supply, demand, regulation, jobs, operations) on a named industry from the 12 standard sectors. Validated via `OverviewClaimVerifier`, deduped against intro and highlights, with forecasts and investment advice rejected. Styled with industry `TagView`, implication text, and citation pills. VoiceOver reads industry, implication, and source as 1 element.
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
| `bodyMatch` | Words a search matched in a card's excerpt | `.body.weight(.semibold)` |
| `callout` | Secondary descriptions | `.callout` (12 pt) |
| `label` | Disclosure rows, tags, inline controls | `.callout.weight(.medium)` |
| `caption` | Dates, counts, status lines | `.subheadline` (11 pt) |
| `eyebrow` | Publisher and kicker above a title | `.caption2.weight(.semibold)`, tracking `AppTypography.eyebrowTracking` (0.5 pt; *target* 0.06 em, Z6 #938), uppercase via `textCase` |
| `cardHeadline(_:)` | Card headlines | List: serif 20 pt semibold; grid: 15 pt semibold |
| Reader tokens | Reader and overview | `titleFont`, `leadFont`, `bodyFont`, heading, quote, caption and code functions of style and text scale |

- The system serif (`design: .serif`) is for editorial headlines and the Casper style only. The app bundles no editorial typeface for its own interface; web fonts in design mocks (Newsreader) map to the system serif tokens. Reader styles keep their own fonts (section 9).
- Never uppercase strings in code; use `.textCase(.uppercase)` so VoiceOver reads words, not letters.
- Dynamic values, counters and relative dates use `.monospacedDigit()`, so live updates do not shift the line.
- Line spacing comes from the reading style; on macOS 26 and later the reader may use `lineHeight(_:)` through a token.

## 11. Color

- System semantic colors only, through `AppColor`. No literal colors (`Color.blue`, hex, RGB) outside `DesignSystem.swift`.
- Text: the system label colors (primary, secondary, tertiary, quaternary) through `AppColor`. Hierarchy never comes from lowering the opacity of primary text; the reader's softened body color is a reader token that returns to full contrast with Increase Contrast.
- Accent: the person's system accent. It marks selection, focus, unread state, links, the active mode and at most one prominent action per view. Never decoration, never toolbar icons except a meaningful state, never large fills. The app defines no brand accent; if one is introduced, it goes in an asset catalog `AccentColor` with light, dark and increased-contrast values.
- Intelligence (warm gold): only for labels and glyphs of generated content. Never body text or glass tint.
- Original reports (teal): only the original-reports count on The Lead and Coverage cards. Light `#006F69`, dark `#65D4C5`, increased contrast `#005A55` and `#8FE8DB`, through one `AppColor` token (*target*, Z7 #1174). The Lead's foot sits on a dark image in both appearances, so it always resolves the dark value.
- Status: success, warning and danger system colors for icons and small fills; text stays in the label colors. Yellow never carries text. The one exception is a result the person's own action brings in, the test banner's status line in Settings › Notifications: it takes the accent-text token. The Library Database tag in Settings › Storage follows the library's state: accent when active, yellow when read-only, red when unavailable.
- Fills: tags and neutral badges use the badge fill token; accent fills are 12 % (22 % with Increase Contrast).
- Accent text: text and symbols in the accent use the accent-text token, which is the person's accent 15 % darker in light and 30 % lighter in dark, blended further in 5 % steps until it reaches 4.5:1 against white in light and the window background in dark (bright accents such as yellow, orange and green need it), because the system accent is one color in every appearance and gave 4.2:1 on the dark page. On the lead caption's dark scrim, the saved glyph and the intelligence tag use the lead text color instead. Text on a tinted tag or citation pill is the tint (the accent-text token for accent tags) mixed toward the primary text color (35 %, 50 % with Increase Contrast). Both keep at least 4.5:1 in light, dark and Increase Contrast.
- Separators: `AppColor.borderSubtle` maps to the system separator color; with Increase Contrast or Show Borders (section 16), borders use the contrast tokens already defined for the reader.
- Light and dark are designed together; every new color token has both values and an increased-contrast value. The in-app appearance override stays optional and defaults to System.

## 12. Shape, spacing and elevation

- Spacing uses `AppSpacing` (4 pt grid: 4, 8, 12, 16, 24, 32, 48). Two micro steps exist for text clusters only: 2 pt between stacked text lines and 6 pt between an eyebrow's parts. No other literal padding or spacing.
- Radii: `AppRadius.control` (6) for small rectangles, `card` (12; *target* 16 for story cards, Z6 #938), `container` (16), and `Capsule()` for tags and pills. Use continuous corners. On macOS 26 and later, a shape inside another rounded container or near the window corner is concentric: `ConcentricRectangle(corners: .concentric(minimum: .fixed(AppRadius.card)), isUniform: true)`.
- Never hard-code control heights or toolbar heights; the system owns them and changed them in macOS 26.
- Depth comes from edge light and plane separation, never heavy or broad gray shadows. Content cards use the elevation below and nothing else. Glass brings its own depth (section 3.3).

| State | Edge | Shadow, light appearance | Movement |
| --- | --- | --- | --- |
| Resting | 0.5–1 pt `AppColor.borderSubtle` hairline; inner top highlight, 1 pt white at 20 % | Y 1 blur 2 black 4 %, and Y 4 blur 12 black 3 % | None |
| Hover | Accent at 40 % (`accent-hover-border`); brighter top highlight | Y 2 blur 4 black 4 %, and Y 8 blur 24 black 6 % | 3 pt lift, image 1.02 inside its frame |
| Keyboard focus | Solid 1.5 pt accent ring, 2 pt offset | As hover | As hover |

- Dark keeps the same geometry on a lighter card surface; its opacities are tuned in Z6. *Target:* these values land in `AppShadow` with Z6 (#938); until then the current tokens apply.
- Layout tokens: `pageInset` 24, `cardGap` 16, list maximum width 1000, grid columns adaptive 300–420, `readingMeasure` 720.

## 13. Motion

- Use `AppMotion` (hover, state, navigation, and spring for a result the person's own action brings in, such as the test notification's outcome) or the system's own animation. Every explicit animation is `nil` when `effectiveReduceMotion` is true; symbol effects stop too.
- Animate state the person caused (expand, save, mode switch, applying queued updates). Never animate content arriving from a refresh while the person is reading.
- Launch is one settle transition: the cached snapshot appears with `AppMotion.navigation` once its first page and that page's card images are ready (`nil` under Reduce Motion), and nothing moves again until the person acts. No per-card pop-in and no progress animation over the list; fetching, clustering and image lookup start after that first frame.
- Glass morphs only between related controls in one container. No parallax, auto-playing motion, confetti or attention-seeking pulses; a card never cycles through an event's images on hover. Named exceptions, each off under Reduce Motion: the hero carousels (section 13.1); The Lead's unread dot, which breathes on a 2.6 s cycle; and the World Tension sheet's hotspot map (section 6, #718), where each pin sends out one slow ring every two seconds and the rings also stop in an inactive window and while the app is in the background.

### 13.1 Hero carousel

One policy and one component for The Lead ([today.md](today.md)) and the Briefing hero ([briefing.md](briefing.md)). They are the only auto-advancing motion in the app and are never on screen together. A lane never scrolls by itself.

- Rotate to the next slide every 45 seconds with a slow cross-fade (`AppMotion.state`, about 0.6 s).
- Pause immediately on pointer hover and on keyboard focus; resume when both clear.
- Never run while a story is open in the reader or a modal sheet.
- Under Reduce Motion (`effectiveReduceMotion`), stop the timer, disable the cross-fade and show the first story. Arrows and dots stay interactive.
- With one slide, show no arrows or dots and run no timer.
- Arrows and dots stay visible; they are never revealed by hover alone (section 15).

## 14. Symbols and menus

- SF Symbols only, monochrome by default; `.fill` variants mark the selected or active state (filled bookmark when saved, filled stack when grouping is on).
- One symbol per concept everywhere: bookmark (save), `square.and.arrow.up` (share), `safari` (open in browser), `globe` (Web view), `doc.richtext` (reader), `sparkles` (generated content, once per page, section 9), `square.stack.3d.up` (event coverage), `speaker.slash` (mute), `arrow.clockwise` (refresh), `arrow.left.arrow.right` (compare perspectives). Don't reuse a symbol for a different meaning.
- Context menus order: read state, save, mute, divider, copy link, open in browser, share, then corrective actions ("Not the Same Event") in their own section. Within a section, give every item a symbol or none. On macOS 27 the menu bar shows icons only for key actions by default; use `labelStyle(.titleAndIcon)` only to surface a key feature.

## 15. Commands, keyboard and pointer

- Every toolbar action has a menu bar command; every frequent command has a keyboard shortcut shown in its menu item. Never reuse a standard window or app shortcut (close, minimize, hide, quit, settings, full screen) for anything else; a standard document shortcut whose action does not exist here (⌘O, ⌘J) may carry a close meaning, such as Open in Browser or the next story (HIG keyboards).
- Menus: View holds layout (as List, as Grid), Group Stories by Event, text size and the sidebar; Navigate holds sections, story movement and queued updates; a Story menu holds actions on the focused or open story (read state, save, open in browser, share, Reader or Web), as Mail's Message menu does; Help lists keyboard shortcuts.
- Single-key shortcuts (J, K, M, S, O and the others in the shortcuts list) work only while the list or reader has focus and never with ⌘, ⌃ or ⌥ held.
- Story lists and grid: Space (or Story › Quick Look, ⌘Y) opens the native Quick Look panel on the focused story without leaving the list or moving its scroll position. While it is open, ↑/↓ and J/K move the focus and the preview follows; Return opens the story in the reader; Space or Esc closes the preview. The preview is a PDF drawn from local text and an already decoded image, never fetched.
- One click opens. A single click on a card, a member row or a search result opens it and selects it; the first click on an inactive window performs the action as well as activating the window (`acceptsFirstMouse`). Double-click carries no extra meaning on cards. An event card opens its overview; the lead report is one more click away, never two.
- Today edition lanes ([today.md](today.md)): ↑ and ↓ move between lanes, ← and → within a lane (and between the slides of The Lead while it has focus); J, K, ⌘J and ⌘K keep moving through every story in reading order, lane by lane; every other single-key command keeps its meaning. No new shortcut reuses a standard one.
- A sidebar row and its shortcut (⌘1–⌘4) always return to that section's list, also when the section is already selected while a story is open; they take the same path as Back and Esc.
- Every icon-only control has `.help`. Hover and focus states come from the system or the card tokens; never remove the focus ring without providing the card focus state.
- Touch: on a Mac with a touch display or Sidecar, system controls handle touch themselves. A control revealed only by pointer hover needs a touch path: keep it visible, reveal it on tap, or offer the action in a context menu (HIG Pointing devices, 28 October 2026). The story banner's close button is the one such essential control today. Touch targets are at least 24 × 24 pt without changing a control's drawn size. Hover feedback that is not an action (card lift, carousel pause) needs no touch equivalent.
- Drag and drop: OPML files and feed URLs onto the window or sidebar; feedback through the drop-target highlight and the result notice rules in section 6.

## 16. Accessibility

- Read `effectiveReduceMotion` and `effectiveContrast` (not the raw environment values), so isolated QA overrides apply.
- Every control has a label; icon-only controls have `Label` titles or `accessibilityLabel`. Labels never include shortcut suffixes.
- Cards combine into one element with a full description and named actions. Headlines and reader headings carry heading traits and levels.
- Reader paragraphs of one story may be linked with `accessibilityLinkedGroup(id:in:)` for continuous reading.
- State never relies on color alone: unread has a dot or, on Today edition cards, a heavier headline, plus a spoken label; saved has a glyph; modes have text.
- Increase Contrast uses the contrast tokens (stronger dividers, borders, fills); Reduce Transparency applies only to the macOS 15 material fallback.
- Custom interactive controls read `@Environment(\.accessibilityShowBorders)` and draw clearly visible edges when it is true. macOS 27 has a dedicated Show Borders setting; on earlier versions it is true with Increase Contrast. It back-deploys, so it needs no availability check, and it has no isolated QA override.
- Never set `accessibilityLabel` on an AppKit-backed view (`ProgressView`, `.textSelection(.enabled)` text) or combine one into a labelled element. Hide the view and label a plain container. `script/design_lint.sh` enforces this; the crash behind it is in [implementation-notes.md](implementation-notes.md).
- Live spoken VoiceOver verification is parked (#268); code-level accessibility above is not.

## 17. Copy

- Title Case for buttons, menu items, toolbar labels and window titles; sentence case for descriptions, help tooltips and status lines.
- "Story" is the user-facing word for an item; "publisher" for its source; "event" and "coverage" for grouped reports. Avoid "article" in new UI text.
- Never claim more than the data shows: feed health is operational, not a quality rating; publisher updates are not verified corrections; overviews are generated and cite sources.
- Generated content: "Generated summary", "Extractive summary", "Key points", "Event overview", "Assembled on this Mac from the cited passages" (caption or tooltip), "Assessed on this Mac". Never "AI-generated", "automated estimate" or a tone label.
- Toolbar: Refresh's tooltip is "Check feeds for new stories"; the queued-updates button reads "Show N New Stories" with the tooltip "Stories that arrived in the background". Both are listed in Help › Keyboard Shortcuts.
- Check for Updates (#992) on a story's overview: tooltip "Check feeds for new reports in this story", Story › Check for Updates, ⌥⌘R. Its result is one status line under the overview header metadata that appears on the click as "Checking your feeds…" and then changes in place: "N new reports joined this story" (never "since you last read": the baseline is the click), "No new reports from your sources", "No new reports yet. Some story matching waits while the Mac saves energy or cools down" when matching was held back, " · N feeds could not be checked" appended when feeds failed, and "Refresh is off." with the reason when the library is read-only.
- The story layer (#581) groups related events into one card; "story" stays the word for what the person opens, and it opens the overview of its newest event of two or more reports (by first report), so a later development's reports are what the card opens to; the story keeps the identity of its earliest event, and a report that joined the story alone never opens it. The story's other events keep the word "event" (no new term such as "act"): those that began before the open event are listed under "Earlier in This Story": every earlier event of the story first, then up to three other rows, lexical relation links before related-act links, each group newest first; each row shows the date of its first report and its headline and opens that event's own overview. "Timeline" stays the dated statements of the open event's overview.
- Event overview headings and evidence labels (Epic T): "Highlights", "Timeline", "Perspectives", "Industry Impact", "Earlier in This Story", "Sources (N)". Industry Impact uses exact standard sector names from the documented list: Energy, Financial Services, Healthcare, Technology, Transportation, Agriculture, Manufacturing, Retail & E-commerce, Media & Entertainment, Telecommunications, Real Estate, Defense & Aerospace. In the timeline, publication-only dates prefix with "Reported [date]"; future planned events show the "Plan" tag with VoiceOver announcing "Planned". Perspectives attribution uses "via [publisher]" or "via [wire] syndicate".
- Entity dossiers (#716): a story's people, organizations and places sit under the kicker "In this story" and each opens a popover with "Coverage", "Top publishers", "Related" and "Recent stories", closed by "Counted from the stories saved on this Mac." An entity only one story names has no chip.
- Compare Perspectives (#717): the overview's bordered action and its sheet compare two publishers' reports by meaning, on this Mac, and say "Compared by meaning on this Mac" once (or "Compared by shared words on this Mac; the meaning model was not available" when the neural embedder was not, since the labels then show overlap). A passage reads "Both report", "Reported differently" or "Only in this report" (`equal.circle`, `arrow.triangle.branch`, `doc.badge.plus`; never `sparkles`, which stays with generated text). The comparison never calls a publisher biased, neutral or right.
- Today edition lanes (section 8.8): "The Lead", "In Motion", "Your Beat", "The Deep Read", "Outside Your Usual", "The Latest", each with its one-line description in sentence case under the name. A lane never claims completeness: "new reporting", never "every development"; no count in a lane header.
- No exclamation marks, no marketing adjectives, no "AI magic".

## 18. Components

Each pattern has one implementation; new code reuses it and extends it rather than copying.

| Component | Owner | Covers |
| --- | --- | --- |
| Tokens | `DesignSystem.swift` | Color, typography, spacing, radius, layout, shadow, motion |
| Story card | `ArticleCardView.swift` | All story cards and their context menus |
| Event coverage | `EventCardView.swift` | Coverage disclosure and member rows |
| Tag | `TagView` in `DesignSystem.swift` | Category, entity, Updated, Plan, the card's intelligence state tag and citation pills; inside Highlights and Perspectives the citation is an inline run in the pill's colours (`sourcedAttributedString`), not a separate view |
| Eyebrow | `EyebrowText` in `DesignSystem.swift` | Publisher and kicker lines in cards, reader and overview |
| Intelligence label | `IntelligenceLabel` in `DesignSystem.swift` | The one generated-content label of a page; takes its font from the caller (headline in the summary panel, eyebrow in the overview, title in a sheet) |
| Grouped sheet content | `TensionIndexView.swift` until a second sheet needs it | Titled groups and aligned rows in sheets (section 8.6) |
| Hero carousel | `BriefingHeroCarouselView.swift` | The Briefing hero and The Lead (section 13.1) |
| Masthead | `ArticleListView.swift` | List title and status line |
| Updates button | `ArticleListView.swift` | Leading toolbar queued-update control |
| Lane | Z4 (#936) adds one lane view beside `ArticleListView.swift` | The Today edition's lane header and horizontal row; one implementation for every lane ([today.md](today.md)) |
| Story card variants | `ArticleCardView.swift` (Z6, #938) | Lead, Developing, Standard, Feature, Coverage and Compact presentations of the one story card (section 8.2, [today.md](today.md)) |
| Notice | `NoticeView` in `DesignSystem.swift` | Inline callouts in content |
| Reading column | `ReadingColumn` in `DesignSystem.swift` | Measure and insets for reader and overview |
| Empty states | `ContentUnavailableView` | All empty, error and no-result states |
| Publisher Health | `PublisherHealthView.swift` | The per-feed health table in its Settings sheet; wording stays operational (section 17) |

## 19. Review checklist

Copy into the PR description for UI changes and tick only what was checked.

- [ ] No new literal font size, color, spacing, radius or control height outside `DesignSystem.swift`.
- [ ] Glass only where section 3.2 allows it, through the shared helper, not nested, no drop shadow on glass, macOS 15 path present.
- [ ] No toolbar or sidebar background, no forced scroll edge style.
- [ ] Toolbar placement, grouping, tooltips and labels follow section 5; every toolbar action has a menu command.
- [ ] Sidebar, search and empty states use the system components in sections 6–8.
- [ ] Light, dark, Increase Contrast, Reduce Motion and Reduce Transparency checked, plus macOS 15 when the change gates an API; macOS 27 glass checked at clear and tinted when glass is involved.
- [ ] Narrow (900 pt) and wide windows checked; keyboard path works.
- [ ] Custom interactive controls draw visible edges with Show Borders; no essential action is reachable by hover alone.
- [ ] Copy follows section 17; one `sparkles` glyph per page, with the generated-content labels and captions of section 9.
- [ ] Written rules and the visual reference in `docs/mocks/` agree; a look that changed is re-exported in this PR.
- [ ] A single click opens; clipped images take no clicks outside their frame; every event card expands.
- [ ] Nothing moves at launch or on refresh beyond section 13; no auto-advancing motion outside section 13.1.
- [ ] `script/design_lint.sh` passes: literal fonts, colours, uppercasing and labels on AppKit-backed views stay at zero; literal spacing, frames, opacity and strokes, raw `colorSchemeContrast`/`accessibilityReduceMotion`, `foregroundColor`, legacy aliases and "article" copy only go down (lower the baseline with `--update` when they do).

## 20. Changing these documents

Change the rules first, in a focused PR with the reason and the evidence. Update the tokens in `DesignSystem.swift` in the same PR when they change, unless the rule is marked target and names the issue that delivers it. Update the affected visual reference in `docs/mocks/` in the same PR. Mars approves changes to these documents. A one-off exception is recorded in the PR that needs it; a recurring exception becomes a rule.
