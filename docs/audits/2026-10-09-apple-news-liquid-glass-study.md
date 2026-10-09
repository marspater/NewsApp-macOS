# Apple News practices and Liquid Glass on macOS 27 — 9 October 2026

Base: `origin/main` at `4eaf39c`. This study reads Apple's current design guidance, developer documentation and session transcripts, published reports on Apple News and other apps, and the News source. It is a documentation and code review, not a hands-on visual audit: no build, launch or macOS 27 screenshot was taken in this session. The resulting rules are in [DESIGN.md](../DESIGN.md) and the work in the [adoption plan](../plans/2026-10-09-design-language-adoption.md).

## Conclusion

The transferable value of Apple News is editorial, not chrome: a calm masthead, a strong typographic hierarchy, a consistent story tile, chrome that recedes while reading and a text size that follows the reader. Its Mac app came from iOS (it was one of the first UIKit-on-Mac apps, now Mac Catalyst), and some of its Mac conventions differ from native AppKit and SwiftUI apps (⌘+ zooms the window; text size uses ⌥⌘+). Its chrome is therefore not the reference for a native SwiftUI app; the HIG and Apple's native apps are.

News already has the right skeleton: `NavigationSplitView`, a native reader toolbar, system search, `ContentUnavailableView` for search, an Icon Composer glass icon, keyboard navigation and accessibility environment overrides. The gaps that keep it from feeling native on macOS 26 and 27 are concentrated and fixable without a redesign:

1. List controls are drawn in content instead of the toolbar, including a second sidebar toggle.
2. A forced soft scroll edge everywhere and an opaque reader toolbar background fight the system glass and macOS 27's automatic edge choice.
3. Sidebar rows are buttons with hand-drawn badges instead of native rows.
4. 117 literal font sizes, 213 literal paddings and at least six hand-built pill styles fragment the type and component system.
5. The glass helpers are dead code, one of them an imitation of glass built from materials, gradients and strokes.

Liquid Glass should stay restrained: system glass everywhere it appears by itself, and custom glass for one or two floating controls only.

## Sources and method

Primary sources, read on developer.apple.com on 9 October 2026:

- Human Interface Guidelines: [Materials](https://developer.apple.com/design/human-interface-guidelines/materials), [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars), [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars) (updated 8 June 2026), [Search fields](https://developer.apple.com/design/human-interface-guidelines/search-fields) (8 June 2026), [Layout](https://developer.apple.com/design/human-interface-guidelines/layout) (9 September 2026), [Menus](https://developer.apple.com/design/human-interface-guidelines/menus) (8 June 2026), [Typography](https://developer.apple.com/design/human-interface-guidelines/typography), [Color](https://developer.apple.com/design/human-interface-guidelines/color), [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons), [Windows](https://developer.apple.com/design/human-interface-guidelines/windows), [Settings](https://developer.apple.com/design/human-interface-guidelines/settings), [Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards).
- SwiftUI documentation: [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views), [Landmarks: Building an app with Liquid Glass](https://developer.apple.com/documentation/swiftui/landmarks-building-an-app-with-liquid-glass) and its toolbar and background-extension articles, and the symbol pages for every API in the availability table below.
- WWDC26: [What's new in SwiftUI](https://developer.apple.com/videos/play/wwdc2026/269/), [Modernize your AppKit app](https://developer.apple.com/videos/play/wwdc2026/289/), [Design intuitive search experiences](https://developer.apple.com/videos/play/wwdc2026/292/), [Enhance the accessibility of your reading app](https://developer.apple.com/videos/play/wwdc2026/219/), [Principles of great design](https://developer.apple.com/videos/play/wwdc2026/250/).
- WWDC25: [Get to know the new design system](https://developer.apple.com/videos/play/wwdc2025/356/), [Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/), [Build an AppKit app with the new design](https://developer.apple.com/videos/play/wwdc2025/310/).
- Meet with Apple: [Liquid Glass showcase](https://developer.apple.com/videos/play/meet-with-apple/208/) (LTK, Slack, Tide Guide, Sky Guide, American Airlines, Lowe's, CNN and Apple's design team) and [CNN showcase](https://developer.apple.com/videos/play/meet-with-apple/256/).
- Apple News Format: [Planning the layout for your article](https://developer.apple.com/documentation/applenews/planning-the-layout-for-your-article), [Changing the appearance of your article tile in feeds](https://developer.apple.com/documentation/applenews/changing-the-appearance-of-your-article-tile-in-feeds), [Supporting Dark Mode for your article](https://developer.apple.com/documentation/applenews/supporting-dark-mode-for-your-article).

Secondary sources, through search-result summaries because this environment's egress policy blocks apple.com, support.apple.com and the press sites named here: Apple's [News on Mac keyboard shortcuts](https://support.apple.com/guide/news/iphc13bdbe67/mac), reports on iOS 26.2 News changes ([9to5Mac](https://9to5mac.com/2025/12/12/ios-26-2-has-four-new-changes-ive-used-almost-every-day/), borncity.com), macOS 27 press coverage ([Cult of Mac](https://www.cultofmac.com/news/liquid-glass-changes-ios-27-macos-27), [AppleMagazine](https://applemagazine.com/macos-27-liquid-glass/)) and NetNewsWire's [Liquid Glass plan](https://netnewswire.blog/2025/10/07/the-liquid-glass-plan.html) and [7.0 notes](https://alternativeto.net/news/2026/2/netnewswire-7-0-launches-with-liquid-glass-design-performance-enhancements-and-bug-fixes/). These are marked "reported" below.

## Liquid Glass in macOS 27

| Change | Source | Consequence for News |
| --- | --- | --- |
| Glass has a refined look and follows the new Liquid Glass slider (clear to tinted) with no code change | WWDC26 269 | Never assume a transparency level; check legibility at both ends of the slider |
| Sidebars extend to the window edges; selection is semibold; content flows behind | WWDC26 289 | Sidebar rows must be native so they pick this up; no sidebar backgrounds |
| Bordered toolbar items over the sidebar adopt glass | WWDC26 289 | Keep toolbar items standard; the sidebar's `+` button already qualifies |
| Automatic scroll edge resolves to a hard edge when free-floating text such as the window title is in the title bar | WWDC26 289 | Forcing `.soft` everywhere overrides this decision; return to automatic |
| A new interactive glass effect gives custom controls a subtle bounce when clicked, tuned for the pointer; Maps uses it; "a little goes a long way" | WWDC26 269, 289 | Use `.interactive()` only on the few custom glass controls |
| Concentric corners for views near a container's corner (`NSViewCornerConfiguration`, `.containerConcentric`); SwiftUI has `ConcentricRectangle` since macOS 26 | WWDC26 289, SwiftUI docs | Elements near window or container corners follow the container curve |
| Inactive windows dim icons and text; custom controls follow with `appearsActive` | WWDC26 269 | Custom control-layer elements read `appearsActive` |
| Menu bar menus show icons only for key actions by default; `labelStyle(.titleAndIcon)` opts in | WWDC26 269, HIG Menus | Keep menu icons purposeful and uniform per section |
| Toolbar items hide automatically as the window narrows; `visibilityPriority` ranks them | WWDC26 269, docs (macOS 26.1) | Rank Refresh and the mode picker high |
| One consistent window corner radius; darker edges and brighter highlights; clearer active-window shadow | Reported (Cult of Mac, AppleMagazine) | Automatic; nothing to adopt |

The macOS 26 foundations still apply: glass is a separate functional layer for controls and navigation, never content ([HIG Materials](https://developer.apple.com/design/human-interface-guidelines/materials)); custom toolbar backgrounds interfere with the scroll edge effect ([HIG Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars), WWDC25 323); hierarchy comes from layout and grouping rather than decoration (WWDC25 356); on macOS, mini to medium controls stay rounded rectangles and large controls become capsules (WWDC25 356, 310).

## API availability

Checked against the SwiftUI documentation on 9 October 2026. The deployment target is macOS 15, so everything marked 26 needs `if #available`.

| API | macOS | Use in News |
| --- | --- | --- |
| `glassEffect(_:in:)`, `Glass` (`regular`, `clear`, `identity`, `tint`, `interactive`), `GlassEffectContainer`, `glassEffectID`, `glassEffectUnion`, `glassEffectTransition` | 26.0 | Custom glass helpers only (updates pill, floating controls) |
| `.buttonStyle(.glass)`, `.buttonStyle(.glassProminent)` | 26.0 | Buttons on custom glass |
| `ToolbarSpacer`, `sharedBackgroundVisibility(_:)` | 26.0 | Toolbar grouping; status items without glass |
| `scrollEdgeEffectStyle(_:for:)`, `scrollEdgeEffectHidden(_:for:)` | 26.0 | Rarely; automatic is the default |
| `safeAreaBar(edge:alignment:spacing:content:)` (vertical and horizontal) | 26.0 | Any pinned bar over a scroll view |
| `backgroundExtensionEffect()` | 26.0 | Optional lead-story image under the sidebar |
| `ConcentricRectangle`, `containerShape(_:)` with `RoundedRectangularShape` | 26.0 | Concentric corners |
| `searchToolbarBehavior(_:)` | 26.0 | Let toolbar search collapse in narrow windows |
| `lineHeight(_:)` | 26.0 | Optional reader line height |
| `visibilityPriority(_:)` | 26.1 | Toolbar ranking |
| `windowToolbarFullScreenVisibility(_:)` | 15.0 | Toolbar on hover in full-screen reading |
| `toolbar(removing:)` with `.title`, `.sidebarToggle`, `.search` | 14.0 | Remove the duplicate toolbar title under a masthead |
| `toolbar(id:)`, `navigationSubtitle(_:)`, `searchable(text:tokens:...)`, `searchScopes`, `searchSuggestions`, `badge(_:)`, `ContentUnavailableView`, `accessibilityLinkedGroup(id:in:)`, `appearsActive` | 15.0 or earlier | Available without gating |
| `ToolbarOverflowMenu`, `toolbarMinimizeBehavior`, `Tab(role: .prominent)` | Not macOS: `ToolbarOverflowMenu` is documented for iOS, iPadOS, Mac Catalyst and visionOS 27; the other two were shown for iPhone and iPad | Not applicable; the macOS overflow menu is automatic |

`ToolbarContentBuilder` supports `if #available` through `buildLimitedAvailability` (macOS 14.5+) for customizable toolbar content, so toolbar spacers can be gated inside the builder; the macOS 15 build verifies this.

## Apple News practices translated to News

| Apple News practice | Evidence | News decision |
| --- | --- | --- |
| The content leads and the chrome recedes, above all while reading | Apple design team: "maybe you're reading an article like we collapse it in our news articles" (Meet with Apple 208); News iOS floating tab bar shrinks on scroll (reported) | Masthead in the scroll content, scrolling under the glass toolbar; Today adds the date to its status line. Window controls move to the toolbar |
| Editor-curated Top Stories, then trending and personal groups | Apple support pages on the Today feed (reported) | No editorial ranking here. Equivalent hierarchy comes from the Briefing, importance ratings and event grouping. An optional lead treatment for the first Today or Briefing entry never re-ranks |
| One tile anatomy: thumbnail, title, channel, date, authors, excerpt of 80–300 characters | [Apple News Format tile](https://developer.apple.com/documentation/applenews/changing-the-appearance-of-your-article-tile-in-feeds) | One story card for every list (DESIGN.md 8.2): image, publisher eyebrow, headline, two-line dek, date and state glyphs |
| Publisher identity through channel logos | Observation of Apple News feeds | Not transferred: logos would need new fetches and unverified marks. Publisher names stay as text eyebrows |
| Article layout on a column grid with a fixed design width; wider screens widen margins, never the measure | [Apple News Format layout](https://developer.apple.com/documentation/applenews/planning-the-layout-for-your-article): 7 columns at 1024 pt, 60 pt margins, 20 pt gutters; "The News app doesn't scale up" | One reading measure for reader and overview, scaled only by text size |
| Text size is a reader preference with menu commands | News on Mac: ⌥⌘+ and ⌥⌘− change text size, ⌘+ zooms the window (reported) | Persisted text size; View menu Make Text Bigger ⌘+, Smaller ⌘−, Actual Size ⌘0 (native SwiftUI convention, as in Books) |
| Keyboard-first story navigation | News on Mac: ⌘→/⌘← next and previous story, ⌘↑/⌘↓ top and bottom, ⌃⌘S sidebar, ⌘S save, ⌘R refresh (reported) | Keep J/K and ⌘J/⌘K, ⌘S, ⌘R and the system ⌃⌘S; decide whether to add News-style aliases (plan decision D5) |
| Story actions in one menu: save, share, suggest less, block channel | Observation of the Apple News story menu | Already present as read, save, mute publisher, copy link, open, share, "Not the Same Event"; ordering fixed in DESIGN.md 14 |
| Dark Mode adapts publisher styling but leaves photos and full-screen captions alone | [Apple News Format Dark Mode](https://developer.apple.com/documentation/applenews/supporting-dark-mode-for-your-article) | Reader uses semantic colors; images are never inverted |
| Quick links as glass pills at the top of Today on iPhone, picking up color from content beneath | iOS 26.2 (reported) | Not transferred: the Mac sidebar already gives direct access; pills would duplicate it in the content layer |
| Search suggestions in the style of Music and TV | iOS 26.2 (reported) | Operator suggestions become tokens; recent searches can follow in a menu, as WWDC26 292 recommends for Mac toolbar search |

## Liquid Glass beyond Apple News

| App | Technique | Transfer to News |
| --- | --- | --- |
| Maps (macOS 27) | Interactive glass on custom floating controls; a weather view concentric with the window corner | The queued-updates pill and any floating Web or media controls use interactive glass; concentric shapes near window corners |
| Landmarks sample (Apple) | `backgroundExtensionEffect()` on hero images under the sidebar and inspector; horizontal shelves that scroll beneath the sidebar; toolbar split into groups with `ToolbarSpacer`; glass badges that morph in a container | Optional lead-story image extended under the sidebar (plan phase 6); toolbar grouping now. No shelves: a news list is vertical |
| CNN | Glass only on video player overlay controls; glass applied once at the top level, never nested; padding kept outside the glass modifier; no glass in lists or animations because of GPU cost; "edge to edge layouts, minimal chrome and a focus on storytelling" | Adopted as DESIGN.md 3.3 rules |
| Tide Guide | Interactive glass buttons that morph; `identity` glass that only shows on interaction; a glass highlight for the selected chart level; a glass popover instead of a context menu for chart settings; "adopt and then redesign" | Reading options become a popover (system glass) with text size and style controls; menu bar commands stay. Content-layer glass tricks are not adopted |
| Lumy | A glass scrubber for the time of day | Possible later for an overview timeline; not planned |
| Lowe's, American Airlines | Brand bar and logo moved into content and scrolling away; "Don't use it just because it's new" | The masthead scrolls away; no branded chrome |
| Slack | Several custom glass header attempts, ending close to the original | Restraint: no custom glass headers |
| Apple design team | Colored toolbar controls were "a little too prominent on the Mac", so Mac controls stayed monochrome | Toolbar icons stay monochrome; accent marks state only |
| NetNewsWire 7 (RSS reader) | Requires macOS 26 for its glass release; toolbar buttons follow Liquid Glass standards; refresh status moved to the navigation subtitle on iOS; timeline slides under the floating feeds column on iPad (reported) | Keep macOS 15 support with gated glass instead of raising the minimum; refresh status stays in the masthead status line |

## Current app audit

| Area | Finding | Consequence | Plan phase |
| --- | --- | --- | --- |
| Glass helpers | `FrostedSurfaceModifier` (`GlassSystem.swift:46-105`) builds imitation glass from `ultraThinMaterial`, a tint, a white gradient, a rim stroke and a shadow; `nativeLiquidGlass` and `inGlassContainer` (`:107-139`, `:170-184`) are unused and gated with `#if canImport(FoundationModels)` as an SDK proxy | Dead code that would reintroduce fake glass if reused; the gate is unrelated to the API | 1 |
| Scroll edges | `softScrollEdge()` (`GlassSystem.swift:144-152`) forces `.soft` on the split view, sidebar, list and reader (`MainView.swift:88`, `SidebarView.swift:50`, `ArticleListView.swift:140`, `ArticleDetailView.swift:107,345`) | Overrides the system choice, including macOS 27's hard edge under title text | 2 |
| Reader toolbar | `.toolbarBackground(.visible, for: .windowToolbar)` (`ArticleDetailView.swift:109`) | An opaque bar blocks glass and the scroll edge effect | 2 |
| List chrome | Window controls drawn in content in a pinned `safeAreaInset` header (`ArticleListView.swift:127-132`, `393-503`): a second sidebar toggle (`395-406`), group toggle (`448-458`), layout picker (`460-470`), shortcuts popover (`472-484`), refresh (`487-498`) | Controls sit outside the glass toolbar, have no menu commands (except refresh) and the pinned header has no scroll edge treatment | 2 |
| Window title | `Window("News", id: "main")` (`NewsApp.swift:30`); no `navigationTitle` | The window is named after the app, against the HIG | 2 |
| Shortcuts | ⇧⌘W toggles Reader/Web (`NewsApp.swift:132`), the standard "close a file and its associated windows"; layout, grouping and text size have no menu commands | Conflicts with system expectations; toolbar-only actions | 2 |
| Sidebar rows | Rows are `Button`s inside `List(selection:)` with hand-drawn capsule badges and an 11 pt font (`SidebarView.swift:97-123`); progress scaled with `scaleEffect(0.7)` (`:105-108`) | Misses native selection, keyboard and sidebar-size behavior and the macOS 27 sidebar styling | 3 |
| Sidebar notices | Drop confirmations are inserted as list rows (`SidebarView.swift:39-41`, `79-93`) | Content shifts inside the navigation list | 3 |
| Search | `searchable(placement: .sidebar)` (`MainView.swift:86`) while results appear in the detail column; operators are plain text | HIG and WWDC26 292 put such search at the trailing end of the toolbar; tokens are not used | 3 |
| Empty states | Custom empty and failure views (`ArticleListView.swift:598-701`) beside `ContentUnavailableView` for search and errors (`:98-100`) | Two visual languages for the same state | 3 |
| Typography | 117 `.font(.system(size:))` calls in views (42 in `EventOverviewReaderView.swift`, 33 in `ArticleDetailView.swift`, 24 in `SettingsView.swift`); the list card headline is a literal (`ArticleCardView.swift:90`) | Sizes drift between screens; tokens do not govern most text | 4 |
| Spacing | 213 literal padding or spacing values in views | Inconsistent rhythm | 4, then opportunistic |
| Color | `Color.blue` (`EventOverviewReaderView.swift:703`); tertiary text and borders are opacity-reduced primaries (`DesignSystem.swift:19,29`) | Ignores the accent and system label and separator colors | 4 |
| Pills and tags | At least six hand-built capsules: AI badge with a "✦" glyph (`ArticleCardView.swift:119-132`), "Updated" (`EventCardView.swift:68-75`), overview kickers and citations (`EventOverviewReaderView.swift:313-343`, `520-551`), "Plan" (`:697-706`), summary tags (`ArticleDetailView.swift:558-567`) | Same concept, different shapes, sizes and fills | 4 |
| Uppercase text | Strings uppercased in code (`ArticleCardView.swift:66`, `ArticleDetailView.swift:272`, `EventCardView.swift:161`) and literal uppercase labels (`ArticleDetailView.swift:453`, `ArticleListView.swift:878,891,907`, `EventOverviewReaderView.swift:314,330`) | VoiceOver may read uppercase words letter by letter | 4 |
| Reading measure | 700 pt in the reader (`ArticleDetailView.swift:341`), 720 pt in the overview (`EventOverviewReaderView.swift:48-50`, pinned by `NativeUIQAChecks`) | The two reading surfaces differ | 5 |
| Text size | `readerTextScale` is per-view `@State` (`ArticleDetailView.swift:46,70`) and only in the Reading options menu (`:779`) | Resets when another story is opened; no menu bar command | 5 |
| Reader buttons | Custom capsule buttons in the terminal affordance (`ArticleDetailView.swift:569-635`) | Non-standard controls next to system ones | 5 |
| Settings | Fixed 680 × 490 window (`SettingsView.swift:65`), extra padding around grouped forms (`:98,296,375,451,513,556`), selected pane not remembered (`:14`) | HIG asks panes to size to content and reopen the last pane | 7 |
| Tokens | `AppLayout.toolbarHeight` and `controlHeight` hard-code system metrics (`DesignSystem.swift:42-43`); alias tokens remain (`:66-69`, `:145-148`, `:159-162`) | System metrics changed in macOS 26; aliases blur intent | 1, then 4 |

Strengths to keep: the reader's native toolbar placements, the Icon Composer glass icon, `ContentUnavailableView.search`, the `effectiveReduceMotion` and `effectiveContrast` overrides used across views, card accessibility actions, keyboard navigation and Reduce Motion gating of animations.

## Do not transfer

- Apple News's Catalyst chrome and shortcuts where they differ from native AppKit and SwiftUI conventions.
- Publisher logos, brand-colored section headers or a brand accent: the system accent is the person's choice and the content is the color.
- Glass on cards, rows, tags or the reader (HIG Materials; CNN's performance finding).
- Quick-link pills in content, custom overflow menus, custom glass headers.
- Raising the minimum to macOS 26 for glass: availability gates keep macOS 15 working.

## Validation

Documentation only. Checked that every relative link and path resolves and that file and line references match `4eaf39c`. No build, test, launch or visual check was required or run for this change.

## Limits

- The macOS 27 behavior described here comes from Apple's documentation, session transcripts and reports, not from inspecting the app on macOS 27; each implementation phase includes its own visual checks.
- Reports reached only through search summaries (marked "reported") may omit or simplify details. Apple News behavior on the Mac was not reverse-engineered.
- Counts of literal values come from source searches and include a few legitimate cases (decorative symbol sizes in empty states, monospaced code) that the plan will review individually.
