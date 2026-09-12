import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var appSettings: AppSettings
    @EnvironmentObject var articleStore: ArticleStore
    @EnvironmentObject var feedManager: FeedManager
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var readManager: ReadManager
    
    @State private var newFeedURL: String = ""
    @State private var selectedTab = 0
    @State private var webCacheSize: String = "Calculating..."
    @State private var databaseSize: String = "Calculating..."
    @State private var totalStorageSize: String = "Calculating..."
    @State private var cacheActionMessage: String? = nil
    @State private var opmlStatusMessage: String? = nil
    @ObservedObject private var updateChecker = UpdateChecker.shared

    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(0)

            feedsTab
                .tabItem { Label("Subscriptions", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(1)
                
            appearanceTab
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
                .tag(2)

            notificationsTab
                .tabItem { Label("Notifications", systemImage: "bell") }
                .tag(3)

            intelligenceTab
                .tabItem { Label("Intelligence", systemImage: "sparkles") }
                .tag(4)

            privacyTab
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
                .tag(5)

            storageTab
                .tabItem { Label("Storage", systemImage: "externaldrive") }
                .tag(6)

            updatesTab
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
                .tag(7)
        }
        .frame(width: 620, height: 490)
        .onAppear { calculateStorageSizes() }
    }

    // MARK: - 1. General Tab

    private var generalTab: some View {
        Form {
            Section("Feed Refresh & Sync") {
                Picker("Background Refresh Interval", selection: Binding(
                    get: { appSettings.fetchIntervalMinutes },
                    set: { feedManager.setFetchInterval(minutes: $0) }
                )) {
                    Text("15 minutes").tag(15.0)
                    Text("30 minutes").tag(30.0)
                    Text("1 hour").tag(60.0)
                    Text("2 hours").tag(120.0)
                }
                .pickerStyle(.menu)
                
                Text("Periodic feed updates occur in the background when NewsApp is running.")
                    .font(.caption)
                    .foregroundColor(AppColor.secondaryText)
            }
            
            Section("Reading Behavior") {
                Toggle("Auto-Hide Read Articles", isOn: $themeManager.autoHideRead)
                Text("Articles will disappear from filtered views once marked as read.")
                    .font(.caption)
                    .foregroundColor(AppColor.secondaryText)
            }
        }
        .formStyle(.grouped)
        .padding(AppLayout.pageInset)
    }

    // MARK: - 2. Subscriptions / Feeds Tab

    private var feedsTab: some View {
        VStack(spacing: 0) {
            // Add feed row
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .foregroundColor(AppColor.accent)
                    .font(.system(size: 18))
                TextField("Enter RSS / Atom / JSON Feed URL", text: $newFeedURL)
                    .textFieldStyle(.roundedBorder)
                Button("Subscribe") {
                    let trimmed = newFeedURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        feedManager.addFeed(url: trimmed)
                        newFeedURL = ""
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColor.accent)
                .controlSize(.small)
                .disabled(newFeedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, AppLayout.pageInset)
            .padding(.top, 16)
            .padding(.bottom, 10)

            // OPML actions bar
            HStack(spacing: 10) {
                Button {
                    OPMLDialogs.importOPML { data in
                        let count = feedManager.importFeeds(from: data)
                        opmlStatusMessage = "Imported \(count) feed(s)"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            opmlStatusMessage = nil
                        }
                    }
                } label: {
                    Label("Import OPML...", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    let opml = feedManager.exportOPML()
                    OPMLDialogs.exportOPML(xmlString: opml)
                } label: {
                    Label("Export OPML...", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if let msg = opmlStatusMessage {
                    Text(msg)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(AppColor.success)
                }

                Spacer()
                Text("\(feedManager.feedURLs.count) feeds")
                    .font(.caption)
                    .foregroundColor(AppColor.secondaryText)
            }
            .padding(.horizontal, AppLayout.pageInset)
            .padding(.bottom, 10)

            Divider()

            // Feed list
            List {
                ForEach(feedManager.feedURLs, id: \.self) { urlString in
                    HStack(spacing: 12) {
                        let status = feedManager.feedStatuses[urlString] ?? .idle
                        switch status {
                        case .idle:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(AppColor.success)
                                .font(.system(size: 13))
                                .help("Feed is active and up to date")
                        case .loading:
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                                .frame(width: 14, height: 14)
                                .help("Fetching updates...")
                        case .failed(let err):
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(AppColor.warning)
                                .font(.system(size: 13))
                                .help(err.localizedDescription)
                        }
                        Text(urlString)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .lineLimit(1)
                            .foregroundColor(AppColor.primaryText)
                        Spacer()
                        Button(role: .destructive) {
                            feedManager.removeFeed(url: urlString)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 12))
                                .foregroundColor(AppColor.danger)
                        }
                        .buttonStyle(.plain)
                        .help("Unsubscribe from feed")
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: - 3. Notifications Tab

    private var notificationsTab: some View {
        Form {
            Section("Notification Delivery") {
                Toggle("Enable Notifications", isOn: Binding(
                    get: { appSettings.notificationsEnabled },
                    set: { appSettings.setNotificationsEnabled($0) }
                ))
                Text("Receive native macOS notification alerts when high-importance news arrives.")
                    .font(.caption)
                    .foregroundColor(AppColor.secondaryText)
            }
            
            if appSettings.notificationsEnabled {
                Section("Notification Privacy & Detail") {
                    Picker("Detail Level", selection: Binding(
                        get: { appSettings.notificationMode },
                        set: { appSettings.setNotificationMode($0) }
                    )) {
                        ForEach(AppSettings.NotificationMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    HStack(spacing: 8) {
                        Image(systemName: appSettings.notificationMode == .private ? "lock.fill" : "info.circle")
                            .foregroundColor(appSettings.notificationMode == .private ? AppColor.success : AppColor.accent)
                        Text(appSettings.notificationMode == .private
                             ? "Private mode: Displays generic alerts with no identifying headlines, sources, or preview text."
                             : (appSettings.notificationMode == .minimal
                                ? "Minimal mode: Aggregates new stories into a single count summary (e.g., '5 new articles')."
                                : "Full mode: Displays article headline, source publication, and lead image banner."))
                            .font(.caption)
                            .foregroundColor(AppColor.secondaryText)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .formStyle(.grouped)
        .padding(AppLayout.pageInset)
    }

    // MARK: - 4. Intelligence Tab

    private var intelligenceTab: some View {
        Form {
            Section("On-Device Intelligence") {
                Toggle("Enable AI Article Analysis", isOn: Binding(
                    get: { appSettings.aiEnabled },
                    set: { appSettings.setAIEnabled($0) }
                ))
                Text("Generates executive summaries, key takeaways, entity tags, and sentiment analysis.")
                    .font(.caption)
                    .foregroundColor(AppColor.secondaryText)
            }

            Section("Architecture & Privacy Guarantees") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "sparkles")
                            .foregroundColor(AppColor.intelligence)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Apple-Native On-Device Models")
                                .font(AppTypography.label)
                                .foregroundColor(AppColor.primaryText)
                            Text("Powered exclusively by Apple NaturalLanguage and on-device FoundationModels when available.")
                                .font(.caption)
                                .foregroundColor(AppColor.secondaryText)
                        }
                    }

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "bolt.shield")
                            .foregroundColor(AppColor.accent)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("On-Demand Execution")
                                .font(AppTypography.label)
                                .foregroundColor(AppColor.primaryText)
                            Text("Analysis runs lazily only when you open an article for reading, preserving battery, CPU, and Neural Engine resources.")
                                .font(.caption)
                                .foregroundColor(AppColor.secondaryText)
                        }
                    }

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "hand.raised.fill")
                            .foregroundColor(AppColor.success)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Zero Cloud Telemetry")
                                .font(AppTypography.label)
                                .foregroundColor(AppColor.primaryText)
                            Text("No text, prompts, or embeddings are ever transmitted to third-party servers or external AI APIs.")
                                .font(.caption)
                                .foregroundColor(AppColor.secondaryText)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .padding(AppLayout.pageInset)
    }

    // MARK: - 5. Privacy & Security Tab

    private var privacyTab: some View {
        Form {
            Section("Network Security Boundary") {
                Toggle("Allow Insecure HTTP Feeds", isOn: Binding(
                    get: { appSettings.allowInsecureHTTP },
                    set: { appSettings.setAllowInsecureHTTP($0) }
                ))
                
                if appSettings.allowInsecureHTTP {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(AppColor.warning)
                        Text("Warning: Unencrypted HTTP feeds transmit data in plain text across your local network and internet providers.")
                            .font(.caption)
                            .foregroundColor(AppColor.warning)
                    }
                } else {
                    Text("Enforces strict HTTPS connections for all feed ingestion and remote media assets.")
                        .font(.caption)
                        .foregroundColor(AppColor.secondaryText)
                }
            }

            Section("Security Standards") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "shield.lefthalf.filled")
                            .foregroundColor(AppColor.accent)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Hardened Runtime & App Sandbox")
                                .font(AppTypography.label)
                                .foregroundColor(AppColor.primaryText)
                            Text("Restricts file system and process access to NewsApp's isolated container.")
                                .font(.caption)
                                .foregroundColor(AppColor.secondaryText)
                        }
                    }

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "network.badge.shield.half.filled")
                            .foregroundColor(AppColor.success)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Direct Connection")
                                .font(AppTypography.label)
                                .foregroundColor(AppColor.primaryText)
                            Text("Fetches feeds directly from publishers without middleman cloud servers, proxy aggregators, or telemetry logging.")
                                .font(.caption)
                                .foregroundColor(AppColor.secondaryText)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .padding(AppLayout.pageInset)
    }
    
    // MARK: - 6. Appearance Tab

    private var appearanceTab: some View {
        Form {
            Section("App Appearance") {
                Picker("Interface Style", selection: $themeManager.appearance) {
                    ForEach(AppAppearance.allCases) { app in
                        Text(app.rawValue).tag(app)
                    }
                }
                .pickerStyle(.segmented)
                
                Text("Select whether NewsApp follows your macOS system appearance or stays locked to light or dark mode.")
                    .font(.caption)
                    .foregroundColor(AppColor.secondaryText)
            }
            
            Section("Article Typography") {
                Picker("Theme Style", selection: $themeManager.articleTheme) {
                    ForEach(ArticleThemeType.allCases) { theme in
                        Text(theme.rawValue).tag(theme)
                    }
                }
                .pickerStyle(.radioGroup)
                
                // Typography Preview
                VStack(alignment: .leading, spacing: 6) {
                    Text("The quick brown fox jumps over the lazy dog.")
                        .font(AppTypography.headlineFont(for: themeManager.articleTheme))
                        .foregroundColor(AppColor.primaryText)
                    Text("Editorial typography determines the headline and body font families, line spacing, and tracking used in reader mode.")
                        .font(AppTypography.bodyFont(for: themeManager.articleTheme))
                        .foregroundColor(AppColor.secondaryText)
                        .lineSpacing(AppTypography.bodyLineSpacing(for: themeManager.articleTheme))
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: AppRadius.control).fill(AppColor.surface))
            }
        }
        .formStyle(.grouped)
        .padding(AppLayout.pageInset)
    }

    // MARK: - 7. Storage Tab

    private var storageTab: some View {
        VStack(spacing: 16) {
            // Header stats
            HStack(spacing: 16) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 32))
                    .foregroundColor(AppColor.secondaryText)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Total Storage Usage")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppColor.secondaryText)
                    Text(totalStorageSize)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(AppColor.primaryText)
                }

                Spacer()

                if let message = cacheActionMessage {
                    Text(message)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppColor.success)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: AppRadius.control).fill(AppColor.success.opacity(0.12)))
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, AppLayout.pageInset)
            .padding(.top, 16)

            Divider()

            // Itemized breakdown table
            VStack(spacing: 12) {
                // Row 1: Web & Media Cache
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Web & Media Cache")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(AppColor.primaryText)
                            Text(webCacheSize)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(AppColor.secondaryText)
                        }
                        Text("HTTP network responses, temporary web data, and cached images.")
                            .font(.caption)
                            .foregroundColor(AppColor.secondaryText)
                    }
                    Spacer()
                    Button("Clear") {
                        clearWebCache()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                // Row 2: Article Bodies
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Article Content Cache")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(AppColor.primaryText)
                            Text("\(articleStore.articles.count) articles")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(AppColor.secondaryText)
                        }
                        Text("Cached full article bodies. Subscriptions and saved stories are kept.")
                            .font(.caption)
                            .foregroundColor(AppColor.secondaryText)
                    }
                    Spacer()
                    Button("Clear") {
                        clearArticleData()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                // Row 3: AI Analysis Data
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("AI Analysis Data")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(AppColor.primaryText)
                            let aiCount = articleStore.articles.filter { $0.aiSummary != nil }.count
                            Text("\(aiCount) enriched")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(AppColor.secondaryText)
                        }
                        Text("Generated summaries, key points, and entities. Subscriptions and articles remain.")
                            .font(.caption)
                            .foregroundColor(AppColor.secondaryText)
                    }
                    Spacer()
                    Button("Clear") {
                        clearAIData()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                // Row 4: Database Storage
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Local SQLite & FTS5 Index")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(AppColor.primaryText)
                            Text(databaseSize)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(AppColor.secondaryText)
                        }
                        Text("Persistent WAL database containing subscriptions, history, and search index.")
                            .font(.caption)
                            .foregroundColor(AppColor.secondaryText)
                    }
                    Spacer()
                    Text("Active")
                        .font(.caption.bold())
                        .foregroundColor(AppColor.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: AppRadius.control).fill(AppColor.surface))
                }

                Divider().padding(.vertical, 4)

                // Clear everything
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Purge All Caches")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(AppColor.danger)
                        Text("Purges web cache, article content, and AI analysis. Preserves subscriptions.")
                            .font(.caption)
                            .foregroundColor(AppColor.secondaryText)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        clearEverythingData()
                    } label: {
                        Text("Clear All")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, AppLayout.pageInset)

            Spacer()
        }
    }

    // MARK: - 8. Updates Tab

    private var updatesTab: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 44))
                .foregroundColor(AppColor.accent)
                .padding(.top, 24)

            VStack(spacing: 4) {
                Text("NewsApp for macOS")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(AppColor.primaryText)
                Text("Version \(updateChecker.currentAppVersion)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(AppColor.secondaryText)
            }

            if let status = updateChecker.statusMessage {
                Text(status)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(updateChecker.updateAvailable ? AppColor.accent : AppColor.secondaryText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: AppRadius.control).fill(AppColor.surface))
            }

            HStack(spacing: 12) {
                if updateChecker.isChecking {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking for updates...")
                        .font(.caption)
                        .foregroundColor(AppColor.secondaryText)
                } else if updateChecker.updateAvailable {
                    Button("View Release on GitHub") {
                        updateChecker.openReleasePage()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppColor.accent)
                } else {
                    Button("Check for Updates") {
                        Task {
                            await updateChecker.checkForUpdates(userInitiated: true)
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.top, 8)

            Spacer()

            VStack(spacing: 4) {
                Text("Direct release channel via GitHub Releases.")
                    .font(.caption2)
                    .foregroundColor(AppColor.secondaryText)
                Text("Native, privacy-first RSS reader with zero telemetry.")
                    .font(.caption2)
                    .foregroundColor(AppColor.tertiaryText)
            }
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Storage & Cache Calculation Helpers

    private func calculateStorageSizes() {
        DispatchQueue.global().async {
            let webBytes = CacheManager.shared.calculateTotalCacheSize()
            let dbBytes = calculateDatabaseBytes()
            let totalBytes = webBytes + dbBytes

            let formattedWeb = Self.formatBytes(webBytes)
            let formattedDb = Self.formatBytes(dbBytes)
            let formattedTotal = Self.formatBytes(totalBytes)

            DispatchQueue.main.async {
                self.webCacheSize = formattedWeb
                self.databaseSize = formattedDb
                self.totalStorageSize = formattedTotal
            }
        }
    }

    nonisolated private func calculateDatabaseBytes() -> Int64 {
        let fileManager = FileManager.default
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return 0 }
        let dbDir = appSupport.appendingPathComponent("com.marspater.news", isDirectory: true)
        let files = ["news.sqlite3", "news.sqlite3-wal", "news.sqlite3-shm"]
        var total: Int64 = 0
        for file in files {
            let path = dbDir.appendingPathComponent(file).path
            if let attrs = try? fileManager.attributesOfItem(atPath: path),
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        return total
    }

    nonisolated private static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024.0) }
        return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
    }

    private func clearWebCache() {
        CacheManager.shared.clearWebCache()
        calculateStorageSizes()
        showActionMessage("Web and media cache cleared.")
    }

    private func clearAIData() {
        Task {
            await articleStore.clearAIAnalysis()
            calculateStorageSizes()
            showActionMessage("AI analysis data cleared.")
        }
    }

    private func clearArticleData() {
        Task {
            await articleStore.clearArticleCache()
            calculateStorageSizes()
            showActionMessage("Article body cache cleared.")
        }
    }

    private func clearEverythingData() {
        Task {
            CacheManager.shared.clearWebCache()
            await articleStore.clearAllDatabaseCache()
            calculateStorageSizes()
            showActionMessage("All local caches cleared.")
        }
    }

    private func showActionMessage(_ msg: String) {
        withAnimation {
            cacheActionMessage = msg
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation {
                if cacheActionMessage == msg {
                    cacheActionMessage = nil
                }
            }
        }
    }
}
