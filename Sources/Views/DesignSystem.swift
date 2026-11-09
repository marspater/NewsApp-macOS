// Copyright 2026 Mars Pater
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// DesignSystem.swift
// NewsApp Design Token System

import AppKit
import SwiftUI

// MARK: - App Colors

enum AppColor {
    // Semantic Surfaces & Backgrounds
    static let background = Color(NSColor.windowBackgroundColor)
    static let surface = Color(NSColor.controlBackgroundColor)
    static let elevatedSurface = Color(NSColor.underPageBackgroundColor)
    // NSColor.withAlphaComponent freezes the appearance at first use; SwiftUI opacity stays dynamic.
    static let cardBackground = Color(NSColor.controlBackgroundColor).opacity(0.6)

    // Semantic Typography Text Colors
    static let primaryText = Color(NSColor.labelColor)
    static let secondaryText = Color(NSColor.secondaryLabelColor)
    static let tertiaryText = Color(NSColor.tertiaryLabelColor)

    // System label colors (DESIGN.md 11): hierarchy without lowering primary-text opacity
    static let secondaryLabel = Color(NSColor.secondaryLabelColor)
    static let quaternaryLabel = Color(NSColor.quaternaryLabelColor)

    // Semantic Accents & Status (90% Neutral, 7% Accent, 3% Intelligence)
    static var accent: Color { Color.accentColor }
    /// A quiet identity mark in the Feed Catalog, not a selection or status color.
    static var publisherMonogramBackground: Color { accent.opacity(0.12) }
    /// The accent for text: the system accent is one color in every appearance, which gave 4.2:1 on the dark page
    /// background. This keeps the person's accent choice, a little darker in light and lighter in dark, so text in it
    /// stays above 4.5:1 (#754). Fills, strokes and symbols keep `accent`.
    static let accentText = Color(
        NSColor(name: "accentText") { appearance in
            var color = NSColor.controlAccentColor
            appearance.performAsCurrentDrawingAppearance {
                let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                // Light measures against white, the brightest page or card; dark against the window background.
                color = readableAccent(
                    NSColor.controlAccentColor, dark: dark, on: dark ? NSColor.windowBackgroundColor : .white)
            }
            return color
        })

    /// The accent blended 15 % toward black in light (30 % toward white in dark), then further in 5 % steps until it
    /// reaches 4.5:1 on `background`: bright accents such as yellow, orange and green gave about 2–3:1 at 15 %.
    static func readableAccent(_ accent: NSColor, dark: Bool, on background: NSColor) -> NSColor {
        let target: NSColor = dark ? .white : .black
        var fraction: CGFloat = dark ? 0.3 : 0.15
        while fraction < 1, let blend = accent.blended(withFraction: fraction, of: target),
            contrastRatio(blend, background) < 4.5
        {
            fraction += 0.05
        }
        return accent.blended(withFraction: min(fraction, 1), of: target) ?? target
    }

    /// WCAG 2 contrast ratio of two colors.
    static func contrastRatio(_ first: NSColor, _ second: NSColor) -> CGFloat {
        func luminance(_ color: NSColor) -> CGFloat {
            guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
            func linear(_ value: CGFloat) -> CGFloat {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent)
                + 0.0722 * linear(rgb.blueComponent)
        }
        let (a, b) = (luminance(first), luminance(second))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
    /// Subtle warm gold for generated-content marks: darker on light, brighter on dark, saturated with Increase Contrast.
    static let intelligence = Color(
        nsColor: NSColor(name: "intelligence") { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let contrast = appearance.name.rawValue.contains("HighContrast")
            if contrast {
                return dark
                    ? NSColor(displayP3Red: 1.0, green: 0.84, blue: 0.40, alpha: 1)
                    : NSColor(displayP3Red: 0.55, green: 0.38, blue: 0.0, alpha: 1)
            }
            return dark
                ? NSColor(displayP3Red: 0.93, green: 0.75, blue: 0.32, alpha: 1)
                : NSColor(displayP3Red: 0.72, green: 0.52, blue: 0.10, alpha: 1)
        })
    static let success = Color(NSColor.systemGreen)
    static let warning = Color(NSColor.systemYellow)
    static let danger = Color(NSColor.systemRed)
    static let caution = Color(NSColor.systemOrange)
    /// The bright centre of the tension flame; a touch deeper on light backgrounds and with Increase Contrast.
    static let flameCore = Color(
        nsColor: NSColor(name: "flameCore") { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let contrast = appearance.name.rawValue.contains("HighContrast")
            if dark && !contrast { return NSColor(displayP3Red: 1, green: 0.97, blue: 0.72, alpha: 1) }
            return NSColor(displayP3Red: 1, green: contrast ? 0.85 : 0.92, blue: contrast ? 0.35 : 0.55, alpha: 1)
        })
    static let critical = Color(NSColor.systemPurple)

    // The hotspot map of the World Tension sheet (W4 #718): three bands, a sea, land and graticule that stay quiet.
    static func hotspot(_ level: HotspotTensionLevel) -> Color {
        switch level {
        case .elevated: return success
        case .significant: return caution
        case .critical: return danger
        }
    }
    static let mapWater = background
    static let mapLand = Color(NSColor.separatorColor).opacity(0.4)
    static let mapGraticule = Color(NSColor.separatorColor)
    /// A region's glow and ring: stronger when chosen and with Increase Contrast, so the band shows without color's help.
    static func hotspotGlow(_ color: Color, selected: Bool, contrast: ColorSchemeContrast) -> Color {
        color.opacity((selected ? 0.45 : 0.25) + (contrast == .increased ? 0.2 : 0))
    }
    static func hotspotRing(_ color: Color, selected: Bool, contrast: ColorSchemeContrast) -> Color {
        color.opacity(selected || contrast == .increased ? 0.9 : 0.5)
    }
    /// The pulse ring fades as it expands (`phase` runs 0 ..< 1).
    static func hotspotPulse(_ color: Color, phase: Double) -> Color { color.opacity(0.6 * (1 - phase)) }

    /// The World Tension scale from Zen to Boiling, for the gauge, glyph and trend points.
    static let tensionScale = Gradient(colors: [success, warning, caution, danger, critical])
    /// The mild glyph's breathing halo.
    static var tensionHalo: Color { tension(.mild).opacity(0.4) }

    static func tension(_ level: TensionLevel) -> Color {
        switch level {
        case .zen: return success
        case .mild: return warning
        case .warm: return caution
        case .hot: return danger
        case .boiling: return critical
        }
    }

    // Borders, Focus Rings & Badges
    static let borderSubtle = Color(NSColor.separatorColor)
    static let separator = Color(NSColor.separatorColor)

    /// A hovered card's accent border (DESIGN.md 8.2).
    static let hoverBorderOpacity: Double = 0.40
    static var hoverBorder: Color { accent.opacity(hoverBorderOpacity) }
    static let badgeBackground = Color(NSColor.quaternaryLabelColor).opacity(0.12)
    static let unreadDot = Color.accentColor
    /// The block a citation jumped to, until the reader dismisses the citation.
    static let passageHighlight = Color.accentColor.opacity(0.12)
    /// A passage the reader highlighted (V1 #711): a caution wash the primary text stays readable on.
    static let noteHighlight = caution.opacity(0.28)
    /// The dotted underline that goes with a highlight, so the state does not rest on color alone (DESIGN.md 11).
    static let noteHighlightMark = Text.LineStyle(pattern: .dot, color: caution)
    /// A sentence the publisher added in an update (V2 #712): a soft accent wash.
    static let addedPassage = Color.accentColor.opacity(0.14)
    /// The dashed underline that goes with it, so an added sentence does not rest on color alone (DESIGN.md 11).
    static let addedPassageMark = Text.LineStyle(pattern: .dash, color: accent)
    /// The overview timeline's connecting line, stronger with Increase Contrast.
    static func timelineRail(for contrast: ColorSchemeContrast) -> Color {
        Color.accentColor.opacity(contrast == .increased ? 0.6 : 0.3)
    }

    /// Card and container strokes: the separator, or a stronger stroke with Increase Contrast (DESIGN.md 11).
    static func border(for contrast: ColorSchemeContrast) -> Color {
        contrast == .increased ? primaryText.opacity(0.50) : borderSubtle
    }

    /// The faint outline that separates a tension dot or scale from its background.
    static func markerOutline(for contrast: ColorSchemeContrast) -> Color {
        border(for: contrast).opacity(0.35)
    }

    /// Captions and other secondary text in the reader reach full contrast with Increase Contrast.
    static func secondaryText(for contrast: ColorSchemeContrast) -> Color {
        contrast == .increased ? primaryText : secondaryText
    }

    /// Dates and other metadata move one label level up with Increase Contrast.
    static func tertiaryText(for contrast: ColorSchemeContrast) -> Color {
        contrast == .increased ? secondaryText : tertiaryText
    }

    // Image-caption contrast remains independent of Liquid Glass transparency.
    static let leadPlaceholder = Color(NSColor.darkGray)
    static let leadScrim = Color.black.opacity(0.84)
    /// Dims the blurred copy behind a square or portrait lead image so the photo itself stands out.
    static let leadBackdropDim = leadPlaceholder.opacity(0.45)
    static let leadText = Color.white
    static let leadSecondaryText = Color.white.opacity(0.85)
    /// The Briefing hero's scrim: the lead scrim at the foot, clear above 65 % of the height (DESIGN.md 8.4).
    static let leadScrimFade = LinearGradient(
        colors: [leadScrim, Color.clear], startPoint: .bottom, endPoint: UnitPoint(x: 0.5, y: 0.35))
    /// The hero carousel's arrow backing and its inactive page dots, over the photo.
    static let carouselControl = Color.black.opacity(0.45)
    static let carouselInactiveDot = Color.white.opacity(0.4)
}

// MARK: - App Layout

enum AppLayout {
    static let settingsPaneWidth: CGFloat = 720
    static let settingsPaneHeight: CGFloat = 560
    static let mainWindowMinimumWidth: CGFloat = 900
    static let mainWindowMinimumHeight: CGFloat = 600
    static let archiveSearchWidth: CGFloat = 300
    static let archiveSearchCollapsedWidth: CGFloat = 36
    static let tensionIllustrationSize: CGFloat = 88
    static let tensionDotSize: CGFloat = 10
    static let tensionStrokeWidth: CGFloat = 3
    static let tensionSheetWidth: CGFloat = 580
    static let tensionSheetHeight: CGFloat = 660
    static let tensionChartHeight: CGFloat = 160
    static let tensionScaleHeight: CGFloat = 8
    static let hotspotMapHeight: CGFloat = 320
    /// Hotspot markers (W4 #718): a region's ring and glow at rest and chosen, a pin between its smallest and largest
    /// size (it grows with its coverage and its tension), and the strokes of a marker's score tag.
    static let hotspotRingSize: CGFloat = 16
    static let hotspotRingGrowth: CGFloat = 12
    static let hotspotRingSelectedSize: CGFloat = 24
    static let hotspotGlowSize: CGFloat = 60
    static let hotspotGlowSelectedSize: CGFloat = 90
    static let hotspotPinMinimumSize: CGFloat = 14
    static let hotspotPinGrowth: CGFloat = 8
    static let hotspotPinSelectedGrowth: CGFloat = 4
    /// A country or a sea draws larger and dashed, so its center is never read as a place.
    static let hotspotApproximateScale: CGFloat = 1.5
    static let hotspotTagStroke: CGFloat = 1
    static let hotspotTagStrokeStrong: CGFloat = 2
    static let hotspotPulseStroke: CGFloat = 2
    /// The centered rule between sections of a story in the reader.
    static let readerSectionRuleWidth: CGFloat = 120
    /// A decoded image narrower than this keeps its own width; wider ones fill the measure.
    static let readerSmallImageWidth: CGFloat = 400
    /// Portrait figures stop here instead of filling the window height.
    static let readerFigureMaxHeight: CGFloat = 560
    static let progressBarHeight: CGFloat = 2
    static let catalogSheetWidth: CGFloat = 720
    static let catalogSheetMinHeight: CGFloat = 560
    static let publisherHealthSheetWidth: CGFloat = 720
    static let publisherHealthSheetMinHeight: CGFloat = 560
    static let publisherHealthFeedColumnMinWidth: CGFloat = 150
    static let publisherHealthNumberColumnWidth: CGFloat = 68
    static let publisherHealthTextColumnWidth: CGFloat = 72
    static let publisherHealthRecommendationColumnMinWidth: CGFloat = 192
    static let smartBinderSheetWidth: CGFloat = 520
    static let smartBinderSheetHeight: CGFloat = 600
    static let iconButtonSize: CGFloat = 28
    /// Overview timeline rail: dot, rail column and the connecting line.
    static let timelineDotSize: CGFloat = 8
    static let timelineRailWidth: CGFloat = 12
    static let timelineRailStroke: CGFloat = 1.5
    /// Highlight bullets sit on the first line's x-height.
    static let bulletTopInset: CGFloat = 7
    /// The "[n]" column in Sources grows with the digit count.
    static func overviewIndexColumnWidth(count: Int) -> CGFloat { count >= 10 ? 32 : 24 }
    static let tensionScaleMarkerHeight: CGFloat = 16
    static let pageInset: CGFloat = 24.0
    static let sidebarInset: CGFloat = 12.0
    static let cardGap: CGFloat = 16.0
    /// Reader and event-overview column width at text scale 1 (DESIGN.md 9).
    static let readingMeasure: CGFloat = 720.0
    static func readingColumnMaxWidth(for scale: CGFloat) -> CGFloat {
        readingMeasure * min(scale, 1.3)
    }
    static let listMaxWidth: CGFloat = 1000.0
    /// List card: one fixed height, with a square image column of the same width.
    static let listCardHeight: CGFloat = 170.0
    static let listCardImageWidth: CGFloat = 170.0
    /// Grid card image or editorial placeholder header.
    static let editorialHeaderHeight: CGFloat = 140.0
    static let leadStoryHeight: CGFloat = 360.0
    static let unreadDotSize: CGFloat = 6.0
    /// Sidebar and reader popovers.
    static let popoverWidth: CGFloat = 280.0
    /// The entity dossier popover (W2 #716): its width, the tallest it grows before it scrolls, and the 30-day chart.
    static let entityDossierWidth: CGFloat = 360
    static let entityDossierMaxHeight: CGFloat = 520
    static let entityChartHeight: CGFloat = 96
    /// The Compare Perspectives sheet (W3 #717): wide enough for two columns, never narrower than the stacked layout.
    static let dualReaderSheetWidth: CGFloat = 1240
    static let dualReaderSheetHeight: CGFloat = 760
    static let dualReaderSheetMinimumWidth: CGFloat = 720
    static let dualReaderSheetMinimumHeight: CGFloat = 520
    static let keyboardShortcutsPopoverWidth: CGFloat = 380
    static let searchSuggestionIconWidth: CGFloat = 16
    static let publisherMonogramSize: CGFloat = 32
    /// Passage quote bars and reader callout indicators.
    static let quoteBarWidth: CGFloat = 3.0
    /// Collapsible inspector side panels.
    static let inspectorMinimumWidth: CGFloat = 260.0
    static let inspectorIdealWidth: CGFloat = 300.0
    static let inspectorMaximumWidth: CGFloat = 360.0
    // Strokes: a Retina hairline at rest, the hover border and the keyboard focus ring (DESIGN.md 8.2).
    static let hairline: CGFloat = 0.5
    static let hoverStroke: CGFloat = 1.0
    static let focusStroke: CGFloat = 1.5
    /// Blur of the backdrop behind a square or portrait lead image.
    static let leadBackdropBlur: CGFloat = 40
    static let gridColumnMinimum: CGFloat = 300.0
    static let gridColumnMaximum: CGFloat = 420.0
    /// Briefing hero carousel: arrow circle, page dots and the pointer target around a small control.
    static let carouselControlSize: CGFloat = 32
    static let carouselDotSize: CGFloat = 8
    static let carouselActiveDotWidth: CGFloat = 16
    static let minimumHitTarget: CGFloat = 44
    /// World Tension strip: driving headlines take three columns on a wide board and two at the narrowest window.
    static let tensionDriverMinimum: CGFloat = 260
    // Briefing war room (#848).
    /// The board's measure, as on the canvas; the Briefing masthead uses it too so the two align.
    static let briefingMaxWidth: CGFloat = 1360
    /// Below this content width the right column of Situational awareness wraps under the carousel.
    static let briefingSplitMinimum: CGFloat = 960
    /// Below this content width Weak signals and Forward watch stack instead of sitting side by side.
    static let briefingPairMinimum: CGFloat = 1056
    /// Modules that share a row of their pillar are at least this wide.
    static let briefingModuleMinimum: CGFloat = 420
    /// The Customize Briefing sheet.
    static let briefingCustomizeWidth: CGFloat = 420
    static let briefingCustomizeHeight: CGFloat = 520
    /// The Briefing's most-covered story tile carries an accent border this wide.
    static let leadTileStroke: CGFloat = 2
    // Control and toolbar heights belong to the system (DESIGN.md 12).

    // The app-drawn story banner (DESIGN.md 8.7), sized like the system banner it stands in for.
    static let bannerWidth: CGFloat = 344
    static let bannerIconSize: CGFloat = 32
    /// The photo's share of the trailing side; the text runs over its dissolving half.
    static let bannerPhotoWidth: CGFloat = 168
    /// Taller than any banner, so filling the frame crops the photo top and bottom and never cuts the fade.
    static let bannerPhotoHeight: CGFloat = 128
    static let bannerTextTrailingInset: CGFloat = 52
    static let bannerMargin: CGFloat = 16
}

// MARK: - App Spacing

enum AppSpacing {
    static let xxs: CGFloat = 4.0
    static let xs: CGFloat = 8.0
    static let sm: CGFloat = 12.0
    static let md: CGFloat = 16.0
    static let lg: CGFloat = 24.0
    static let xl: CGFloat = 32.0

    // Micro steps for text clusters only (DESIGN.md 12)
    /// Between stacked text lines.
    static let textStack: CGFloat = 2.0
    /// Between an eyebrow's parts.
    static let eyebrowGap: CGFloat = 6.0
}

// MARK: - App Corner Radius

enum AppRadius {
    static let control: CGFloat = 6.0
    static let card: CGFloat = 12.0
    static let container: CGFloat = 16.0
    /// The story banner, matched to the system banner's corners.
    static let banner: CGFloat = 20.0

    // Aliases for backward compatibility
}

// MARK: - App Typography

enum AppTypography {
    static let sectionHeaderTracking: Double = 0.6
    static let eyebrowTracking: Double = 0.5

    // Standard semantic typographic scale
    static let title = Font.title.bold()
    static let headline = Font.headline
    static let leadStoryHeadline = Font.system(size: 28, weight: .semibold, design: .serif)
    static let body = Font.body
    /// Words a search matched inside a card's excerpt (#708): body text in semibold, so the match does not rely on
    /// color (DESIGN.md 8.2).
    static let bodyMatch = Font.body.weight(.semibold)
    static let label = Font.callout.weight(.medium)
    static let caption = Font.subheadline

    // System text styles for chrome (DESIGN.md 10)
    static let masthead = Font.largeTitle.bold()
    /// The news tension reading ("44°").
    static let tensionReading = Font.system(size: 44, weight: .bold, design: .rounded)
    static let sectionTitle = Font.title3.weight(.semibold)
    static let callout = Font.callout
    /// A summary paragraph that leads a sheet or panel, such as the news tension explanation.
    static let lede = Font.title3
    /// Publisher and kicker; pair with `eyebrowTracking` and `.textCase(.uppercase)`.
    static let eyebrow = Font.caption2.weight(.semibold)
    /// A cited fact in the publisher's voice: the editorial serif at callout size (Briefing, #848).
    static let quote = Font.system(.callout, design: .serif)

    static func cardHeadline(_ layout: StoryCardLayout) -> Font {
        switch layout {
        case .list: return .system(size: 20, weight: .semibold, design: .serif)
        case .grid: return .system(size: 15, weight: .semibold)
        }
    }

    // Reader Article Typography Themes
    static func titleFont(for theme: ArticleThemeType, scale: CGFloat = 1) -> Font {
        switch theme {
        case .casper: return .system(size: 34 * scale, weight: .bold, design: .serif)
        case .edition: return .system(size: 32 * scale, weight: .heavy, design: .default)
        case .alto: return .system(size: 28 * scale, weight: .medium, design: .monospaced)
        }
    }

    static func headlineFont(for theme: ArticleThemeType) -> Font {
        switch theme {
        case .casper: return .system(size: 16, weight: .bold, design: .serif)
        case .edition: return .system(size: 15, weight: .bold, design: .default)
        case .alto: return .system(size: 15, weight: .semibold, design: .monospaced)
        }
    }

    static func leadFont(for theme: ArticleThemeType, scale: CGFloat = 1) -> Font {
        switch theme {
        case .casper: return .system(size: 20 * scale, weight: .regular, design: .serif)
        case .edition: return .system(size: 18 * scale, weight: .regular, design: .default)
        case .alto: return .system(size: 16 * scale, weight: .medium, design: .monospaced)
        }
    }

    /// Body text size at text scale 1; reader headings and code are sized from it.
    static func bodySize(for theme: ArticleThemeType) -> CGFloat {
        switch theme {
        case .casper: return 18
        case .edition: return 16
        case .alto: return 15
        }
    }

    static func bodyFont(for theme: ArticleThemeType, scale: CGFloat = 1) -> Font {
        .system(size: bodySize(for: theme) * scale, weight: .regular, design: theme == .casper ? .serif : .default)
    }

    /// Headings use the style's display face (the headline's), so Casper stays serif and Alto monospaced.
    private static func displayDesign(for theme: ArticleThemeType) -> Font.Design {
        switch theme {
        case .casper: return .serif
        case .edition: return .default
        case .alto: return .monospaced
        }
    }

    /// Section heading size inside publisher text: level 2 (heading) or 3 and deeper (subheading). Never smaller than
    /// the body, so a subheading still reads as one.
    static func readerHeadingSize(level: Int, theme: ArticleThemeType) -> CGFloat {
        (bodySize(for: theme) * (level <= 2 ? 1.35 : 1.1)).rounded()
    }

    static func readerHeadingFont(level: Int, theme: ArticleThemeType, scale: CGFloat = 1) -> Font {
        .system(
            size: readerHeadingSize(level: level, theme: theme) * scale, weight: level <= 2 ? .bold : .semibold,
            design: displayDesign(for: theme))
    }

    static func readerQuoteFont(for theme: ArticleThemeType, scale: CGFloat = 1) -> Font {
        bodyFont(for: theme, scale: scale).italic()
    }

    /// Figure captions and credits.
    static func readerCaptionFont(scale: CGFloat = 1) -> Font {
        .system(size: 13 * scale)
    }

    /// Raise and drop of `<sup>` and `<sub>` text in the reader, in points.
    static let superscriptOffset: CGFloat = 6
    static let subscriptOffset: CGFloat = 3

    /// A cited publisher passage, distinct from generated summaries.
    static let readerCitation = Font.system(size: 13, weight: .medium, design: .serif)

    /// Event overview has its own editorial hierarchy, scaled with the shared reader preference.
    static func overviewFont(_ role: OverviewTextRole, scale: CGFloat = 1) -> Font {
        .system(
            size: overviewSize(role) * scale, weight: overviewWeight(role),
            design: role == .title ? .serif : .default)
    }

    private static func overviewSize(_ role: OverviewTextRole) -> CGFloat {
        switch role {
        case .title: return 30
        case .section: return 18
        case .subheading, .introduction: return 16
        case .fact: return 15
        case .body, .bodyMedium: return 14
        case .metadata, .emphasis: return 13
        case .annotation: return 12
        case .eyebrow, .caption, .captionMedium: return 11
        case .micro: return 10
        }
    }

    private static func overviewWeight(_ role: OverviewTextRole) -> Font.Weight {
        switch role {
        case .title, .section, .subheading: return .bold
        case .emphasis, .eyebrow, .micro: return .semibold
        case .bodyMedium, .metadata, .annotation, .captionMedium: return .medium
        case .introduction, .fact, .body, .caption: return .regular
        }
    }

    /// Code blocks and inline code: monospaced, a step below the body and scaled with it.
    static func readerCodeFont(for theme: ArticleThemeType, scale: CGFloat = 1) -> Font {
        .system(size: (bodySize(for: theme) * 0.85).rounded() * scale, design: .monospaced)
    }

    static func bodyLineSpacing(for theme: ArticleThemeType) -> CGFloat {
        switch theme {
        case .casper: return 10.0
        case .edition: return 8.0
        case .alto: return 12.0
        }
    }
}

enum OverviewTextRole: Sendable {
    case title, section, subheading, introduction, fact, body, bodyMedium
    case metadata, emphasis, annotation, eyebrow, caption, captionMedium, micro
}

enum StoryCardLayout: Sendable {
    case list
    case grid
}

// MARK: - App Shadows

enum AppShadow {
    static let cardRestingColor = Color.black.opacity(0.06)
    static let cardRestingRadius: CGFloat = 6.0
    static let cardRestingY: CGFloat = 2.0

    static let cardHoverColor = Color.black.opacity(0.12)
    static let cardHoverRadius: CGFloat = 10.0
    static let cardHoverY: CGFloat = 4.0

    static let cardFocusRingColor = AppColor.accent.opacity(0.5)
    static let cardFocusRingRadius: CGFloat = 4.0
    static let cardFocusRingY: CGFloat = 0.0

    // Backward compatibility alias (now a restrained accent glow, not radioactive pink)
}

// MARK: - App Motion

enum AppMotion {
    static let hover = Animation.easeOut(duration: 0.12)
    static let state = Animation.smooth(duration: 0.24)
    static let navigation = Animation.smooth(duration: 0.3)
    /// The hotspot pins' pulse (DESIGN.md 13): one slow ring every two seconds, drawn at 20 frames a second, and
    /// stopped under Reduce Motion, in an inactive window and while the app is not active.
    static let pulsePeriod: TimeInterval = 2.0
    static let pulseFrameInterval: TimeInterval = 1.0 / 20.0

    // Aliases for backward compatibility
    static let quick = hover
    static let responsive = state
}

// MARK: - Components (DESIGN.md 18)

/// Publisher name or kicker above a headline. Uppercased for display only, so VoiceOver reads words.
struct EyebrowText: View {
    let text: String
    let color: Color

    var font: Font = AppTypography.eyebrow

    init(_ text: String, color: Color = AppColor.secondaryText, font: Font = AppTypography.eyebrow) {
        self.text = text
        self.color = color
        self.font = font
    }

    var body: some View {
        Text(text)
            .font(font)
            .tracking(AppTypography.eyebrowTracking)
            .textCase(.uppercase)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// The unread marker: an accent dot at the trailing end of a card's or row's eyebrow line (DESIGN.md 8.2).
struct UnreadDot: View {
    var body: some View {
        Circle()
            .fill(AppColor.unreadDot)
            .frame(width: AppLayout.unreadDotSize, height: AppLayout.unreadDotSize)
            .accessibilityLabel("Unread")
    }
}

/// A small capsule for a state or label ("Updated", the intelligence tag). The fill is the tint at 12 %,
/// 22 % with Increase Contrast (DESIGN.md 11); the text is the tint mixed toward the primary text color.
struct TagView: View {
    let title: String
    var systemImage: String?
    var tint: Color = AppColor.secondaryText
    var font: Font = AppTypography.eyebrow
    /// Replaces the mixed text color where the tag sits on a fixed surface, such as the lead caption's dark scrim.
    var foreground: Color?
    @Environment(\.effectiveContrast) private var contrast

    var body: some View {
        HStack(spacing: AppSpacing.textStack) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            Text(title)
        }
        .font(font)
        .foregroundStyle(foreground ?? textColor)
        .padding(.horizontal, AppSpacing.eyebrowGap)
        .padding(.vertical, AppSpacing.textStack)
        .background(fill, in: Capsule())
    }

    private var textColor: Color { Self.textColor(tint: tint, contrast: contrast) }
    private var fill: Color { Self.fill(tint: tint, contrast: contrast) }

    /// Tinted text is mixed toward the primary text color (darker in light, lighter in dark, more with Increase
    /// Contrast), so it keeps at least 4.5:1 on its own wash; the bare tint fell to 2.9:1 in dark Increase Contrast
    /// (#754). The accent starts from the accent-text token: a yellow accent mixed from the bare tint gave 3.8:1.
    nonisolated static func textColor(tint: Color, contrast: ColorSchemeContrast) -> Color {
        if tint == AppColor.secondaryText { return tint }
        let base = tint == AppColor.accent ? AppColor.accentText : tint
        return base.mix(with: AppColor.primaryText, by: contrast == .increased ? 0.5 : 0.35)
    }

    /// Neutral tags share the badge background; tinted tags take a wash of their tint.
    nonisolated static func fill(tint: Color, contrast: ColorSchemeContrast) -> Color {
        if tint == AppColor.secondaryText { return AppColor.badgeBackground }
        return tint.opacity(contrast == .increased ? 0.22 : 0.12)
    }
}

extension TagView {
    /// Marks generated content; the only use of the intelligence color besides its glyphs.
    static func intelligence(_ title: String = "AI", foreground: Color? = nil) -> TagView {
        TagView(title: title, systemImage: "sparkles", tint: AppColor.intelligence, foreground: foreground)
    }
}

// MARK: - Shared content labels and notices

/// Generated content is always identified by a sparkles glyph, not by gold body text.
struct IntelligenceLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        HStack(spacing: AppSpacing.eyebrowGap) {
            Image(systemName: "sparkles")
                .foregroundStyle(AppColor.intelligence)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(AppColor.primaryText)
        }
        // No font of its own: the caller sets it (headline in the summary panel, eyebrow in the overview).
        .accessibilityElement(children: .combine)
    }
}

/// Consistent in-content notice, never a floating glass control.
struct NoticeView<Content: View>: View {
    var tint: Color = AppColor.secondaryLabel
    @ViewBuilder let content: Content
    @Environment(\.effectiveContrast) private var contrast

    init(tint: Color = AppColor.secondaryLabel, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        content
            .padding(AppSpacing.sm)
            .background(
                tint.opacity(contrast == .increased ? 0.18 : 0.10),
                in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    .strokeBorder(
                        tint.opacity(contrast == .increased ? 1 : 0.30), lineWidth: contrast == .increased ? 1.0 : 0.5)
            }
    }
}

/// A quiet panel for in-content sections (reader summary, analysis): surface fill, card radius, contrast-aware border.
struct ContentPanel: ViewModifier {
    @Environment(\.effectiveContrast) private var contrast
    func body(content: Content) -> some View {
        content
            .padding(AppSpacing.md)
            .background(AppColor.surface, in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    .strokeBorder(AppColor.border(for: contrast), lineWidth: AppLayout.hairline)
            )
    }
}

/// Reader and overview share both their measure and page insets.
struct ReadingColumn: ViewModifier {
    let textScale: CGFloat
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, AppLayout.pageInset)
            .padding(.vertical, AppSpacing.xl)
            .containerRelativeFrame(.horizontal) { available, _ in
                min(available, AppLayout.readingColumnMaxWidth(for: textScale))
            }
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// The floating story banner's surface (DESIGN.md 3.2): regular glass on macOS 26 and later, the regular material on
/// macOS 15. The system adapts both to Reduce Transparency and Increase Contrast. The glass sits behind the content,
/// not around it, so the photo and text also draw where no backdrop exists (offscreen renders).
struct BannerSurface<S: Shape>: ViewModifier {
    let shape: S
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.background { Color.clear.glassEffect(.regular, in: shape) }
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

/// A stateless focused command action: compares equal across renders so `.focusedSceneValue` does not trigger an
/// infinite `App` -> `Window` re-evaluation loop when the window is key (#778).
struct FocusedCommandAction: Equatable {
    let perform: () -> Void
    static func == (_: Self, _: Self) -> Bool { true }
}
