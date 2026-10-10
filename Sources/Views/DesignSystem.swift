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
    static let cardBackground = Color(NSColor.controlBackgroundColor.withAlphaComponent(0.6))

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

    // Borders, Focus Rings & Badges
    static let borderSubtle = Color(NSColor.separatorColor)
    static let separator = Color(NSColor.separatorColor)
    static let focusRing = Color.accentColor.opacity(0.65)
    static let badgeBackground = Color(NSColor.quaternaryLabelColor).opacity(0.12)
    static let unreadDot = Color.accentColor

    // Image-caption contrast remains independent of Liquid Glass transparency.
    static let leadPlaceholder = Color(NSColor.darkGray)
    static let leadScrim = Color.black.opacity(0.84)
    static let leadText = Color.white
    static let leadSecondaryText = Color.white.opacity(0.85)
}

// MARK: - App Layout

enum AppLayout {
    static let pageInset: CGFloat = 24.0
    static let sidebarInset: CGFloat = 12.0
    static let sectionGap: CGFloat = 24.0
    static let cardGap: CGFloat = 16.0
    /// Reader and event-overview column width at text scale 1 (DESIGN.md 9).
    static let readingMeasure: CGFloat = 720.0
    static let listMaxWidth: CGFloat = 1000.0
    static let leadStoryHeight: CGFloat = 360.0
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
    static let sectionTitle = Font.title3.weight(.semibold)
    static let callout = Font.callout
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

    static func bodyFont(for theme: ArticleThemeType, scale: CGFloat = 1) -> Font {
        switch theme {
        case .casper: return .system(size: 18 * scale, weight: .regular, design: .serif)
        case .edition: return .system(size: 16 * scale, weight: .regular, design: .default)
        case .alto: return .system(size: 15 * scale, weight: .regular, design: .default)
        }
    }

    /// Section headings inside publisher text: level 2 (heading) or 3 (subheading).
    static func readerHeadingFont(level: Int, scale: CGFloat = 1) -> Font {
        level <= 2
            ? .system(size: 22 * scale, weight: .bold)
            : .system(size: 15 * scale, weight: .semibold)
    }

    static func readerQuoteFont(for theme: ArticleThemeType, scale: CGFloat = 1) -> Font {
        bodyFont(for: theme, scale: scale).italic()
    }

    /// Figure captions and credits.
    static func readerCaptionFont(scale: CGFloat = 1) -> Font {
        .system(size: 11 * scale)
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

    static func readerCodeFont() -> Font {
        .system(.body, design: .monospaced)
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
    static let state = Animation.spring(response: 0.28, dampingFraction: 0.8)
    static let navigation = Animation.spring(response: 0.38, dampingFraction: 0.82)
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
                    .stroke(tint.opacity(contrast == .increased ? 1 : 0.30), lineWidth: 1)
            }
    }
}
