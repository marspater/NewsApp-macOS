// DesignSystem.swift
// NewsApp Design Token System

import SwiftUI
import AppKit

// MARK: - App Colors

enum AppColor {
    // Semantic Surfaces & Backgrounds
    static let background = Color(NSColor.windowBackgroundColor)
    static let surface = Color(NSColor.controlBackgroundColor)
    static let elevatedSurface = Color(NSColor.underPageBackgroundColor)
    static let cardBackground = Color(NSColor.controlBackgroundColor.withAlphaComponent(0.6))
    
    // Semantic Typography Text Colors
    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    static let tertiaryText = Color.secondary.opacity(0.65)
    
    // Semantic Accents & Status (90% Neutral, 7% Accent, 3% Intelligence)
    static var accent: Color { Color.accentColor }
    static let intelligence = Color(.displayP3, red: 0.85, green: 0.65, blue: 0.20, opacity: 1.0) // Subtle warm gold
    static let success = Color(NSColor.systemGreen)
    static let warning = Color(NSColor.systemYellow)
    static let danger = Color(NSColor.systemRed)
    
    // Borders, Focus Rings & Badges
    static let borderSubtle = Color.primary.opacity(0.08)
    static let focusRing = Color.accentColor.opacity(0.65)
    static let badgeBackground = Color.secondary.opacity(0.12)
    static let unreadDot = Color.accentColor
}

// MARK: - App Layout

enum AppLayout {
    static let pageInset: CGFloat = 24.0
    static let sidebarInset: CGFloat = 12.0
    static let sectionGap: CGFloat = 24.0
    static let cardGap: CGFloat = 16.0
    static let toolbarHeight: CGFloat = 44.0
    static let controlHeight: CGFloat = 28.0
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
    
    // Standard semantic typographic scale
    static let display = Font.system(size: 32, weight: .bold)
    static let title = Font.system(size: 22, weight: .bold)
    static let headline = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 14, weight: .regular)
    static let bodySmall = Font.system(size: 13, weight: .regular)
    static let label = Font.system(size: 12, weight: .medium)
    static let caption = Font.system(size: 11, weight: .regular)
    static let metadata = Font.system(size: 10, weight: .semibold)
    
    // Reader Article Typography Themes
    static func titleFont(for theme: ArticleThemeType) -> Font {
        switch theme {
        case .casper: return .system(size: 34, weight: .bold, design: .serif)
        case .edition: return .system(size: 32, weight: .heavy, design: .default)
        case .alto: return .system(size: 28, weight: .medium, design: .monospaced)
        }
    }
    
    static func headlineFont(for theme: ArticleThemeType) -> Font {
        switch theme {
        case .casper: return .system(size: 16, weight: .bold, design: .serif)
        case .edition: return .system(size: 15, weight: .bold, design: .default)
        case .alto: return .system(size: 15, weight: .semibold, design: .monospaced)
        }
    }
    
    static func leadFont(for theme: ArticleThemeType) -> Font {
        switch theme {
        case .casper: return .system(size: 20, weight: .regular, design: .serif)
        case .edition: return .system(size: 18, weight: .regular, design: .default)
        case .alto: return .system(size: 16, weight: .medium, design: .monospaced)
        }
    }
    
    static func bodyFont(for theme: ArticleThemeType) -> Font {
        switch theme {
        case .casper: return .system(size: 18, weight: .regular, design: .serif)
        case .edition: return .system(size: 16, weight: .regular, design: .default)
        case .alto: return .system(size: 15, weight: .regular, design: .default)
        }
    }
    
    static func bodyLineSpacing(for theme: ArticleThemeType) -> CGFloat {
        switch theme {
        case .casper: return 10.0
        case .edition: return 8.0
        case .alto: return 12.0
        }
    }
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

// MARK: - Structured Article Filter Query

struct ArticleFilterQuery: Equatable, Sendable {
    var sourceFilter: String?
    var categoryFilter: String?
    var isReadFilter: Bool?
    var isSavedFilter: Bool?
    var terms: [String] = []
    
    var isEmpty: Bool {
        sourceFilter == nil && categoryFilter == nil && isReadFilter == nil && isSavedFilter == nil && terms.isEmpty
    }
    
    init(
        sourceFilter: String? = nil,
        categoryFilter: String? = nil,
        isReadFilter: Bool? = nil,
        isSavedFilter: Bool? = nil,
        terms: [String] = []
    ) {
        self.sourceFilter = sourceFilter
        self.categoryFilter = categoryFilter
        self.isReadFilter = isReadFilter
        self.isSavedFilter = isSavedFilter
        self.terms = terms
    }
    
    static func parse(_ rawText: String) -> ArticleFilterQuery {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ArticleFilterQuery() }
        
        var query = ArticleFilterQuery()
        let lowerText = trimmed.lowercased()
        
        if lowerText.contains("source:") || lowerText.contains("category:") || lowerText.contains("is:") {
            for token in trimmed.components(separatedBy: .whitespaces) {
                let lowerToken = token.lowercased()
                if lowerToken.hasPrefix("source:") {
                    query.sourceFilter = String(token.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                } else if lowerToken.hasPrefix("category:") {
                    query.categoryFilter = String(token.dropFirst(9)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                } else if lowerToken == "is:read" {
                    query.isReadFilter = true
                } else if lowerToken == "is:unread" {
                    query.isReadFilter = false
                } else if lowerToken == "is:saved" {
                    query.isSavedFilter = true
                } else if !token.isEmpty {
                    query.terms.append(lowerToken)
                }
            }
        } else {
            query.terms = [lowerText]
        }
        
        return query
    }
    
    func matches(article: FeedArticle, isRead: Bool, isSaved: Bool) -> Bool {
        if isEmpty { return true }
        
        if let s = sourceFilter, !s.isEmpty {
            if !article.source.lowercased().contains(s) { return false }
        }
        
        if let c = categoryFilter, !c.isEmpty {
            guard let cat = article.category?.lowercased(), cat.contains(c) else { return false }
        }
        
        if let r = isReadFilter {
            if isRead != r { return false }
        }
        
        if let sv = isSavedFilter {
            if isSaved != sv { return false }
        }
        
        if !terms.isEmpty {
            let combined = "\(article.title) \(article.description) \(article.category ?? "")".lowercased()
            for term in terms {
                if !combined.contains(term) { return false }
            }
        }
        
        return true
    }
}
