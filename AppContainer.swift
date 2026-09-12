// AppContainer.swift
// NewsApp Centralized Dependency Container

import SwiftUI

/// Centralized application dependency container reducing manual environment-object plumbing.
@MainActor
final class AppContainer: ObservableObject {
    static let shared = AppContainer()

    let appSettings: AppSettings
    let articleStore: ArticleStore
    let feedManager: FeedManager
    let readManager: ReadManager
    let savedStories: SavedStoriesManager
    let themeManager: ThemeManager

    init(
        appSettings: AppSettings? = nil,
        articleStore: ArticleStore? = nil,
        feedManager: FeedManager? = nil,
        readManager: ReadManager? = nil,
        savedStories: SavedStoriesManager? = nil,
        themeManager: ThemeManager? = nil
    ) {
        self.appSettings = appSettings ?? AppSettings.shared
        self.articleStore = articleStore ?? ArticleStore.shared
        self.feedManager = feedManager ?? FeedManager()
        self.readManager = readManager ?? ReadManager.shared
        self.savedStories = savedStories ?? SavedStoriesManager.shared
        self.themeManager = themeManager ?? ThemeManager.shared
    }
}
