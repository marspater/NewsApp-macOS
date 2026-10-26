// AppContainer.swift
// NewsApp Centralized Dependency Container

import SwiftUI

/// Centralized application dependency container reducing manual environment-object plumbing.
///
/// `AppContainer` serves as the root dependency injection registry for the application, initializing
/// and holding shared references to core coordinators, persistence stores, and configuration managers.
@MainActor
final class AppContainer: ObservableObject {
    /// The shared singleton container instance.
    static let shared = AppContainer()

    // MARK: - Core Services & Stores

    /// Central application settings and user preferences store.
    let appSettings: AppSettings

    /// Observable article library store managing reactive story queries and read counts.
    let articleStore: ArticleStore

    /// High-level coordinator managing feed ingestion, scheduling, and background refresh cycles.
    let feedManager: FeedManager

    /// Reconciliation manager handling read/unread state reconciliation.
    let readManager: ReadManager

    /// Manager orchestrating saved story bookmarks and Spotlight indexing.
    let savedStories: SavedStoriesManager

    /// Visual appearance and Liquid Glass theme manager.
    let themeManager: ThemeManager

    // MARK: - Initialization

    /// Initializes a new container with the provided dependencies or defaults.
    ///
    /// - Parameters:
    ///   - appSettings: Optional settings store. Defaults to ``AppSettings/shared``.
    ///   - articleStore: Optional article store. Defaults to ``ArticleStore/shared``.
    ///   - feedManager: Optional feed coordinator. Defaults to a standard ``FeedManager``.
    ///   - readManager: Optional read manager. Defaults to a standard `ReadManager`.
    ///   - savedStories: Optional saved stories manager. Defaults to a standard `SavedStoriesManager`.
    ///   - themeManager: Optional theme manager. Defaults to ``ThemeManager/shared``.
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
        self.feedManager = feedManager ?? FeedManager(settings: self.appSettings, store: self.articleStore)
        self.readManager = readManager ?? ReadManager(articleStore: self.articleStore)
        self.savedStories = savedStories ?? SavedStoriesManager(articleStore: self.articleStore)
        self.themeManager = themeManager ?? ThemeManager.shared
    }
}
