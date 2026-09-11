// DesignSystem.swift
// NewsApp Design Token System

import SwiftUI
import AppKit

// MARK: - App Colors

enum AppColor {
    // Branded Accent Colors (used as tints/accents, not global overrides)
    static let accentPink = Color(.displayP3, red: 1.0, green: 0.22, blue: 0.50, opacity: 1.0)
    static let accentGold = Color(.displayP3, red: 1.0, green: 0.84, blue: 0.35, opacity: 1.0)
    static let accentBlue = Color(.displayP3, red: 0.30, green: 0.55, blue: 1.0, opacity: 1.0)
    
    // Semantic Tint (respects system accent color by default, allows brand tinting where appropriate)
    static var tint: Color {
        Color.accentColor
    }
    
    // Backgrounds and Surfaces
    static let surfaceDark = Color(NSColor.windowBackgroundColor)
    static let surfaceMid = Color(NSColor.controlBackgroundColor)
    static let surfaceElevated = Color(NSColor.underPageBackgroundColor)
    static let cardBackground = Color(NSColor.controlBackgroundColor.withAlphaComponent(0.6))
    
    // Typography Text Colors
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let textTertiary = Color.secondary.opacity(0.7)
    
    // Status and Badges
    static let badgeBackground = Color.secondary.opacity(0.18)
    static let unreadDot = accentPink
    static let errorRed = Color(NSColor.systemRed)
    static let successGreen = Color(NSColor.systemGreen)
    static let warningYellow = Color(NSColor.systemYellow)
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
    static let small: CGFloat = 6.0
    static let medium: CGFloat = 8.0
    static let card: CGFloat = 14.0
    static let bubble: CGFloat = 12.0
    static let pill: CGFloat = 999.0
}

// MARK: - App Typography

enum AppTypography {
    static let sectionHeaderTracking: Double = 1.2
    static let sourceEyebrowTracking: Double = 0.8
    
    static func titleFont(for theme: ArticleThemeType) -> Font {
        switch theme {
        case .casper: return .system(size: 44, weight: .bold, design: .serif)
        case .edition: return .system(size: 40, weight: .heavy, design: .default)
        case .alto: return .system(size: 36, weight: .medium, design: .monospaced)
        }
    }
    
    static func bodyFont(for theme: ArticleThemeType) -> Font {
        switch theme {
        case .casper: return .system(size: 21, weight: .regular, design: .serif)
        case .edition: return .system(size: 18, weight: .regular, design: .default)
        case .alto: return .system(size: 17, weight: .regular, design: .monospaced)
        }
    }
    
    static func bodyLineSpacing(for theme: ArticleThemeType) -> CGFloat {
        switch theme {
        case .casper: return 12.0
        case .edition: return 8.0
        case .alto: return 14.0
        }
    }
}

// MARK: - App Shadows

enum AppShadow {
    static let cardRestingColor = Color.black.opacity(0.18)
    static let cardRestingRadius: CGFloat = 8.0
    static let cardRestingY: CGFloat = 4.0
    
    static let cardHoverColor = Color.black.opacity(0.35)
    static let cardHoverRadius: CGFloat = 12.0
    static let cardHoverY: CGFloat = 6.0
    
    static let cardSelectedGlow = AppColor.accentPink.opacity(0.35)
    static let cardSelectedRadius: CGFloat = 14.0
    static let cardSelectedY: CGFloat = 6.0
}

// MARK: - App Motion

enum AppMotion {
    static let quick = Animation.easeOut(duration: 0.15)
    static let responsive = Animation.spring(response: 0.35, dampingFraction: 0.75)
    static let smooth = Animation.spring(response: 0.45, dampingFraction: 0.85)
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
