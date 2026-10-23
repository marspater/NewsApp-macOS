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
    static let label = Color(NSColor.labelColor)
    static let secondaryLabel = Color(NSColor.secondaryLabelColor)
    static let tertiaryLabel = Color(NSColor.tertiaryLabelColor)
    static let quaternaryLabel = Color(NSColor.quaternaryLabelColor)

    // Semantic Accents & Status (90% Neutral, 7% Accent, 3% Intelligence)
    static var accent: Color { Color.accentColor }
    static let intelligence = Color(.displayP3, red: 0.85, green: 0.65, blue: 0.20, opacity: 1.0)  // Subtle warm gold
    static let success = Color(NSColor.systemGreen)
    static let warning = Color(NSColor.systemYellow)
    static let danger = Color(NSColor.systemRed)
    static let caution = Color(NSColor.systemOrange)
    static let flameCore = Color(.displayP3, red: 1, green: 0.97, blue: 0.72)
    static let critical = Color(NSColor.systemPurple)

    /// The World Tension scale from Zen to Boiling, for the gauge, glyph and trend points.
    static let tensionScale = Gradient(colors: [success, warning, caution, danger, critical])

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
    static let focusRing = Color.accentColor.opacity(0.65)
    static let badgeBackground = Color(NSColor.quaternaryLabelColor).opacity(0.12)
    static let unreadDot = Color.accentColor

    /// Card and container strokes: the separator, or a stronger stroke with Increase Contrast (DESIGN.md 11).
    static func border(for contrast: ColorSchemeContrast) -> Color {
        contrast == .increased ? primaryText.opacity(0.50) : borderSubtle
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
}

// MARK: - App Layout

enum AppLayout {
    static let settingsPaneWidth: CGFloat = 720
    static let settingsPaneHeight: CGFloat = 560
    static let archiveSearchWidth: CGFloat = 300
    static let archiveSearchCollapsedWidth: CGFloat = 36
    static let tensionIllustrationSize: CGFloat = 88
    static let tensionDotSize: CGFloat = 10
    static let tensionStrokeWidth: CGFloat = 3
    static let tensionSheetWidth: CGFloat = 580
    static let tensionSheetHeight: CGFloat = 660
    static let tensionChartHeight: CGFloat = 160
    static let tensionScaleHeight: CGFloat = 8
    /// The centered rule between sections of a story in the reader.
    static let readerSectionRuleWidth: CGFloat = 120
    static let tensionScaleMarkerHeight: CGFloat = 16
    static let pageInset: CGFloat = 24.0
    static let sidebarInset: CGFloat = 12.0
    static let sectionGap: CGFloat = 24.0
    static let cardGap: CGFloat = 16.0
    /// Reader and event-overview column width at text scale 1 (DESIGN.md 9).
    static let readingMeasure: CGFloat = 720.0
    static func readingColumnMaxWidth(for scale: CGFloat) -> CGFloat {
        readingMeasure * min(scale, 1.3)
    }
    static let listMaxWidth: CGFloat = 1000.0
    static let leadStoryHeight: CGFloat = 360.0
    /// Blur of the backdrop behind a square or portrait lead image.
    static let leadBackdropBlur: CGFloat = 40
    static let gridColumnMinimum: CGFloat = 300.0
    static let gridColumnMaximum: CGFloat = 420.0
    // Control and toolbar heights belong to the system (DESIGN.md 12).
}

// MARK: - App Spacing

enum AppSpacing {
    static let xxs: CGFloat = 4.0
    static let xs: CGFloat = 8.0
    static let sm: CGFloat = 12.0
    static let md: CGFloat = 16.0
    static let lg: CGFloat = 24.0
    static let xl: CGFloat = 32.0
    static let xxl: CGFloat = 48.0

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
    static let pill: CGFloat = 999.0

    // Aliases for backward compatibility
    static let small: CGFloat = 6.0
    static let medium: CGFloat = 8.0
    static let bubble: CGFloat = 12.0
}

// MARK: - App Typography

enum AppTypography {
    static let sectionHeaderTracking: Double = 0.6
    static let sourceEyebrowTracking: Double = 0.5
    static let eyebrowTracking: Double = 0.5

    // Standard semantic typographic scale
    static let title = Font.title.bold()
    static let headline = Font.headline
    static let leadStoryHeadline = Font.system(size: 28, weight: .semibold, design: .serif)
    static let body = Font.body
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
        case .detail, .metadata, .emphasis: return 13
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
        case .introduction, .fact, .body, .detail, .caption: return .regular
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
    case detail, metadata, emphasis, annotation, eyebrow, caption, captionMedium, micro
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
    static var cardSelectedGlow: Color { AppColor.accent.opacity(0.2) }
    static let cardSelectedRadius: CGFloat = 8.0
    static let cardSelectedY: CGFloat = 3.0
}

// MARK: - App Motion

enum AppMotion {
    static let hover = Animation.easeOut(duration: 0.12)
    static let state = Animation.smooth(duration: 0.24)
    static let navigation = Animation.smooth(duration: 0.3)
    static let modal = Animation.easeOut(duration: 0.2)

    // Aliases for backward compatibility
    static let quick = hover
    static let responsive = state
    static let smooth = navigation
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

/// A small capsule for a state or label ("Updated", the intelligence tag). The fill is the tint at 12 %,
/// 22 % with Increase Contrast (DESIGN.md 11).
struct TagView: View {
    let title: String
    var systemImage: String?
    var tint: Color = AppColor.secondaryText
    var font: Font = AppTypography.eyebrow
    @Environment(\.effectiveContrast) private var contrast

    var body: some View {
        HStack(spacing: AppSpacing.textStack) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
            }
            Text(title)
        }
        .font(font)
        .foregroundStyle(tint)
        .padding(.horizontal, AppSpacing.eyebrowGap)
        .padding(.vertical, AppSpacing.textStack)
        .background(tint.opacity(contrast == .increased ? 0.22 : 0.12), in: Capsule())
    }
}

extension TagView {
    /// Marks generated content; the only use of the intelligence color besides its glyphs.
    static func intelligence(_ title: String = "AI") -> TagView {
        TagView(title: title, systemImage: "sparkles", tint: AppColor.intelligence)
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
        .font(AppTypography.headline)
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
