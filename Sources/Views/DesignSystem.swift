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
    /// The original-reports count on The Lead and Coverage cards, and nothing else (DESIGN.md 11).
    static let originalReports = Color(
        nsColor: NSColor(name: "originalReports") { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let contrast = appearance.name.rawValue.contains("HighContrast")
            if contrast {
                return dark
                    ? NSColor(srgbRed: 0x8F / 255, green: 0xE8 / 255, blue: 0xDB / 255, alpha: 1)
                    : NSColor(srgbRed: 0, green: 0x5A / 255, blue: 0x55 / 255, alpha: 1)
            }
            return dark
                ? NSColor(srgbRed: 0x65 / 255, green: 0xD4 / 255, blue: 0xC5 / 255, alpha: 1)
                : NSColor(srgbRed: 0, green: 0x6F / 255, blue: 0x69 / 255, alpha: 1)
        })
    /// The dark value of `originalReports`, for The Lead's foot, which sits on a dark image in both appearances.
    static let originalReportsOnImage = Color(
        nsColor: NSColor(srgbRed: 0x65 / 255, green: 0xD4 / 255, blue: 0xC5 / 255, alpha: 1))
    /// The fill of a status pill on a photo ("Updated 14 min ago"): the person's accent, darkened until white text
    /// on it reaches 4.5:1, in both appearances because the pill sits on an image.
    static let statusPill = Color(
        NSColor(name: "statusPill") { _ in readableAccent(NSColor.controlAccentColor, dark: false, on: .white) })
    /// A story card's inner top highlight (DESIGN.md 12): white at 20 %, brighter on hover; quieter on the dark
    /// card surface, where white reads much stronger.
    static func cardTopHighlight(hovered: Bool) -> Color { hovered ? cardTopHighlightRaised : cardTopHighlightResting }
    private static let cardTopHighlightResting = topHighlight(light: 0.20, dark: 0.08)
    private static let cardTopHighlightRaised = topHighlight(light: 0.45, dark: 0.16)
    private static func topHighlight(light: CGFloat, dark: CGFloat) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return NSColor.white.withAlphaComponent(isDark ? dark : light)
            })
    }
    /// A stable identity color for a publisher's monogram, from the system palette by the name's letters.
    static func publisherMonogram(_ name: String) -> Color {
        let palette: [NSColor] = [
            .systemBlue, .systemIndigo, .systemPurple, .systemPink, .systemRed, .systemOrange, .systemBrown,
            .systemGreen, .systemTeal, .systemGray,
        ]
        let sum = name.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 9973 }
        return Color(nsColor: palette[sum % palette.count])
    }
    /// A monogram's disc: a wash of the publisher's color on a card, the solid color on The Lead's image.
    static func publisherMonogramFill(_ name: String, tinted: Bool) -> Color {
        publisherMonogram(name).opacity(tinted ? 0.22 : 1)
    }
    /// The letter on a washed monogram: the publisher's color mixed halfway toward the primary text color.
    static func publisherMonogramText(_ name: String) -> Color {
        publisherMonogram(name).mix(with: primaryText, by: 0.5)
    }
    /// The surface a Compact card's photo dissolves into: the card fill, opaque at the text and clear at the photo.
    static let compactPhotoFade = LinearGradient(
        stops: [.init(color: surface, location: 0), .init(color: surface.opacity(0), location: 0.55)],
        startPoint: .leading, endPoint: .trailing)
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
    /// The Lead's image fades into the page along its lower edge (docs/design/today.md): no panel behind the text.
    static let leadPageFade = LinearGradient(
        stops: [.init(color: background.opacity(0), location: 0.93), .init(color: background, location: 1)],
        startPoint: .top, endPoint: .bottom)
    /// Darkens The Lead's image where its text sits: strongest at the leading edge, gone past the middle.
    static let leadTextScrim = LinearGradient(
        stops: [
            .init(color: Color.black.opacity(0.72), location: 0),
            .init(color: Color.black.opacity(0.5), location: 0.45),
            .init(color: Color.black.opacity(0.12), location: 1),
        ], startPoint: .leading, endPoint: .trailing)
    /// Darkens the foot of The Lead's image, where the time, publishers and original reports sit, so they stay
    /// legible on a bright photo.
    static let leadFootScrim = LinearGradient(
        stops: [
            .init(color: Color.black.opacity(0), location: 0.55), .init(color: Color.black.opacity(0.6), location: 0.9),
        ],
        startPoint: .top, endPoint: .bottom)
    /// A gray content pill on The Lead's image (reading time).
    static let leadPill = Color.white.opacity(0.16)
    static let leadPillBorder = Color.white.opacity(0.3)
    /// The Lead's status pill ("Developing") on its dark image: the person's accent, lightened as accent text is
    /// on a dark page, on a wash of itself.
    static let leadStatus = Color(
        NSColor(name: "leadStatus") { _ in readableAccent(NSColor.controlAccentColor, dark: true, on: .black) })
    static var leadStatusFill: Color { leadStatus.opacity(0.22) }
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
    /// Opens from Settings like Publisher Health, so it takes the same bounds (#1265).
    static let catalogSheetMinHeight: CGFloat = publisherHealthSheetMinHeight
    static let catalogSheetHeight: CGFloat = publisherHealthSheetIdealHeight
    static let publisherHealthSheetWidth: CGFloat = 720
    /// The sheet opens below the Settings window's toolbar, where the 560 pt pane leaves room for its content plus the
    /// sheet's own bottom bar with Done; a 560 pt content height put Done below the window edge (#1265). The table
    /// scrolls, so the header, footnote and Done stay visible.
    static let publisherHealthSheetMinHeight: CGFloat = 400
    static let publisherHealthSheetIdealHeight: CGFloat = 480
    static let publisherHealthSheetMaxHeight: CGFloat = publisherHealthSheetIdealHeight
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
    /// How far in from the sidebar's trailing edge a section header's button sits so it ends where the count badges of
    /// the rows below end: a header runs wider than a row, whose badge sits inside the selection capsule. Measured
    /// offscreen on macOS 27 by `Tests/Harness/SidebarCaptures.swift` (the badge ends 21.5 pt, a bare header button
    /// 4.5 pt from the edge of a 240 pt sidebar).
    static let sidebarHeaderActionInset: CGFloat = 17.0
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
    /// The Lead follows the window: 240 pt at the 600 pt minimum height, 0.6 pt more per window point, at most 440.
    static func leadHeight(windowHeight: CGFloat) -> CGFloat {
        min(440, max(240, 240 + (windowHeight - mainWindowMinimumHeight) * 0.6))
    }
    /// The Lead's text column never runs wider than a comfortable headline measure.
    static let leadTextMaxWidth: CGFloat = 640
    static let breathingDotSize: CGFloat = 8
    static let unreadDotSize: CGFloat = 6.0
    // Today edition cards (docs/design/today.md)
    static let laneCardWidth: CGFloat = 320
    static let featureCardWidth: CGFloat = 400
    /// The Feature card's image is 3:2 of the card's width.
    static let featureImageHeight: CGFloat = featureCardWidth / 1.5
    static let compactCardMinimumHeight: CGFloat = 104
    /// The Latest's Compact grid: two columns still fit the 660 pt column of the minimum window.
    static let compactColumnMinimum: CGFloat = 280
    /// The Compact card's photo fills this share of the card from the trailing edge.
    static let compactPhotoShare: CGFloat = 0.52
    /// Compact text may reach this share of the card's width, over the photo's dissolving edge.
    static let compactTextShare: CGFloat = 0.66
    static let cardHoverLift: CGFloat = 3
    static let cardHoverImageScale: CGFloat = 1.02
    static let cardTopHighlightHeight: CGFloat = 1
    static let focusRingOffset: CGFloat = 2
    static let cardMonogramSize: CGFloat = 18
    /// Each later monogram covers this much of the one before it.
    static let cardMonogramOverlap: CGFloat = 6
    static let cardMonogramStroke: CGFloat = 1.5
    static let progressDotSize: CGFloat = 6
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
    /// How many grid columns of at least `minimum` fit `width`.
    static func gridColumnCount(width: CGFloat, minimum: CGFloat = gridColumnMinimum) -> Int {
        max(1, Int((width + cardGap) / (minimum + cardGap)))
    }
    /// The items of one grid column: every `count`th item, starting at `column`. Columns are independent, so reading
    /// order runs across and an expanded card grows only its own column (#1227).
    static func gridColumn<Item>(_ column: Int, of count: Int, in items: [Item]) -> [Item] {
        guard count > 1 else { return items }
        return stride(from: column, to: items.count, by: count).map { items[$0] }
    }
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
    /// A sideways swipe this far closes the banner, the touch path for the hover-only close button.
    static let bannerSwipeDistance: CGFloat = 60
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
    /// Story cards (Mars, 9 November 2026; DESIGN.md 12).
    static let storyCard: CGFloat = 16.0
    static let container: CGFloat = 16.0
    /// The story banner, matched to the system banner's corners.
    static let banner: CGFloat = 20.0

    // Aliases for backward compatibility
}

// MARK: - App Typography

enum AppTypography {
    static let sectionHeaderTracking: Double = 0.6
    static let eyebrowTracking: Double = 0.6

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

    /// Today edition card headlines: serif, 20 pt on Feature and 15 pt elsewhere. Read state is carried by weight
    /// and color, since these cards show no unread dot (DESIGN.md 8.2).
    static func editionHeadline(feature: Bool, isRead: Bool) -> Font {
        .system(size: feature ? 20 : 15, weight: isRead ? .medium : .semibold, design: .serif)
    }
    static let monogram = Font.system(size: 9, weight: .bold, design: .rounded)
    /// The Lead's headline: serif, 2.4 % of the window's width, between 22 and 34 pt.
    static func leadHeadline(windowWidth: CGFloat) -> Font {
        .system(size: min(34, max(22, windowWidth * 0.024)), weight: .semibold, design: .serif)
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

    static func overviewSize(_ role: OverviewTextRole) -> CGFloat {
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
    /// One shadow layer. SwiftUI's radius is half a design tool's blur.
    struct Layer {
        let color: Color
        let radius: CGFloat
        let y: CGFloat
    }

    /// Black at the light-appearance opacity of DESIGN.md 12; dark keeps the geometry and needs about four times
    /// the opacity to separate a card from the darker page.
    private static func shade(_ light: CGFloat) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return NSColor.black.withAlphaComponent(dark ? min(1, light * 4) : light)
            })
    }

    // Story card elevation (DESIGN.md 12): a tight contact shadow and a soft ambient one.
    static let cardRestingContact = Layer(color: shade(0.04), radius: 1, y: 1)
    static let cardRestingAmbient = Layer(color: shade(0.03), radius: 6, y: 4)
    static let cardHoverContact = Layer(color: shade(0.04), radius: 2, y: 2)
    static let cardHoverAmbient = Layer(color: shade(0.06), radius: 12, y: 8)

    // Single-layer tokens for the Briefing's cards and small marks.
    static let cardRestingColor = Color.black.opacity(0.06)
    static let cardRestingRadius: CGFloat = 6.0
    static let cardRestingY: CGFloat = 2.0

    static let cardHoverColor = Color.black.opacity(0.12)
    static let cardHoverRadius: CGFloat = 10.0
    static let cardHoverY: CGFloat = 4.0

    static let cardFocusRingColor = AppColor.accent.opacity(0.5)
    static let cardFocusRingRadius: CGFloat = 4.0
    static let cardFocusRingY: CGFloat = 0.0
}

// MARK: - App Motion

enum AppMotion {
    static let hover = Animation.easeOut(duration: 0.12)
    static let state = Animation.smooth(duration: 0.24)
    static let navigation = Animation.smooth(duration: 0.3)
    /// A result the person's own action brings in, such as the test notification's outcome: a short spring that settles
    /// at once (DESIGN.md 13).
    static let spring = Animation.spring(duration: 0.45, bounce: 0.3)
    /// The hotspot pins' pulse (DESIGN.md 13): one slow ring every two seconds, drawn at 20 frames a second, and
    /// stopped under Reduce Motion, in an inactive window and while the app is not active.
    /// The Lead's unread dot breathes on a 2.6 s cycle (DESIGN.md 13); off under Reduce Motion.
    static let breathe = Animation.easeInOut(duration: 1.3).repeatForever(autoreverses: true)
    static let breatheDimmed: Double = 0.35
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

/// A source named inside a sentence (event overview highlights and perspectives): a quiet neutral chip that wraps
/// with the text. `InlineChipText` builds the text and `InlineChipRenderer` draws the rounded fill, which an
/// attributed string's own background cannot do (it is a square).
enum InlineChip {
    static let cornerRadius: CGFloat = 4.0

    static func fill(contrast: ColorSchemeContrast) -> Color {
        Color(contrast == .increased ? NSColor.tertiaryLabelColor : NSColor.quaternaryLabelColor)
    }

    /// Secondary text mixed toward primary, so the label keeps 4.5:1 on the chip's own fill.
    static func textColor(contrast: ColorSchemeContrast) -> Color {
        AppColor.secondaryText.mix(with: AppColor.primaryText, by: contrast == .increased ? 0.8 : 0.5)
    }
}

/// Marks the runs of one inline chip; runs with the same index on a line share one fill.
struct InlineChipAttribute: TextAttribute {
    let index: Int
}

struct InlineChipRenderer: TextRenderer {
    let fill: Color

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            var chips: [Int: CGRect] = [:]
            for run in line {
                guard let chip = run[InlineChipAttribute.self] else { continue }
                let bounds = run.typographicBounds.rect
                chips[chip.index] = chips[chip.index]?.union(bounds) ?? bounds
            }
            for bounds in chips.values {
                context.fill(
                    Path(roundedRect: bounds, cornerRadius: InlineChip.cornerRadius, style: .continuous),
                    with: .color(fill))
            }
            for run in line { context.draw(run) }
        }
    }
}

extension Text {
    /// One text from an attributed string whose chip runs are named by `chipIndex`: every run keeps its own
    /// attributes (font, color, link), and a chip run also carries the attribute the renderer looks for.
    init(_ attributed: AttributedString, chipIndex: (AttributedString.Runs.Run) -> Int?) {
        self = attributed.runs.reduce(Text(verbatim: "")) { text, run in
            let piece = Text(AttributedString(attributed[run.range]))
            guard let index = chipIndex(run) else { return Text("\(text)\(piece)") }
            return Text("\(text)\(piece.customAttribute(InlineChipAttribute(index: index)))")
        }
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

/// The surface of a control that floats over a photo (The Lead's dots and arrows): glass tinted dark on macOS 26
/// and later, so white marks on it stay legible when the photo is bright or the window is inactive and the glass
/// turns pale; the same dark backing with the regular material on macOS 15.
struct PhotoControlSurface<S: Shape>: ViewModifier {
    let shape: S
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            // The marks are the glass's own content, so they draw above it. Glass placed behind them as a background
            // was composited over them by the shared container: in an inactive window it turns pale and the white
            // dots and arrows vanished, also with a dark backing (live passes, 11 and 12 November 2026).
            content
                .background(AppColor.carouselControl, in: shape)
                .glassEffect(.regular, in: shape)
        } else {
            content.background(AppColor.carouselControl, in: shape).background(.regularMaterial, in: shape)
        }
    }
}

/// Floating controls over content (The Lead's dots and arrows): their glass shapes share one container on macOS 26
/// and later, so neighbouring shapes blend instead of stacking (DESIGN.md 3.3). Each control takes its surface from
/// `BannerSurface`.
struct FloatingGlassGroup<Content: View>: View {
    var spacing: CGFloat = AppSpacing.xs
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { HStack(spacing: spacing) { content } }
        } else {
            HStack(spacing: spacing) { content }
        }
    }
}

extension View {
    /// A disclosure's label that toggles it from anywhere on its row: on macOS only the triangle does by default.
    func disclosureRow(_ isExpanded: Binding<Bool>) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { isExpanded.wrappedValue.toggle() }
            .accessibilityAddTraits(.isButton)
    }
}

/// The list or grid choice of each list (Today, Unread, a section…), kept apart so one list's layout does not
/// change another's (Mars, 11 November 2026). A list never chosen for follows the earlier single preference.
enum ListLayoutPreference {
    static let key = "articleGridLayoutBySection"

    static func choices(_ stored: String) -> [String: Bool] {
        (try? JSONDecoder().decode([String: Bool].self, from: Data(stored.utf8))) ?? [:]
    }

    static func isGrid(_ section: String, stored: String, fallback: Bool) -> Bool {
        choices(stored)[section] ?? fallback
    }

    static func setting(_ isGrid: Bool, for section: String, in stored: String) -> String {
        var all = choices(stored)
        all[section] = isGrid
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(all)).flatMap { String(data: $0, encoding: .utf8) } ?? stored
    }
}

/// A stateless focused command action: compares equal across renders so `.focusedSceneValue` does not trigger an
/// infinite `App` -> `Window` re-evaluation loop when the window is key (#778).
struct FocusedCommandAction: Equatable {
    let perform: () -> Void
    static func == (_: Self, _: Self) -> Bool { true }
}
