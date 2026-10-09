import SwiftUI
import AppKit

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case subscriptions
    case muting
    case appearance
    case notifications
    case intelligence
    case privacy
    case storage
    case updates

    var id: String { rawValue }
}

struct SettingsView: View {
    static let lastPaneStorageKey = "lastSettingsPane"
    static let paneWidth: CGFloat = 500

    @EnvironmentObject var appSettings: AppSettings
    @EnvironmentObject var articleStore: ArticleStore
    @EnvironmentObject var feedManager: FeedManager
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var readManager: ReadManager
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    
    @AppStorage(SettingsView.lastPaneStorageKey) private var selectedPane: SettingsPane = .general
    @State private var newFeedURL: String = ""
    @State private var webCacheSize: String = "Calculating..."
    @State private var databaseSize: String = "Calculating..."
    @State private var totalStorageSize: String = "Calculating..."
    @State private var cacheActionMessage: String? = nil
    @State private var opmlStatusMessage: String? = nil
    @State private var showsCatalog = false
    @State private var newMutedSource = ""
    @State private var newMutedTopic = ""
    @State private var muteCounts = MuteRuleCounts()
    @State private var confirmsUnmuteAll = false
    @ObservedObject private var updateChecker = UpdateChecker.shared

    var body: some View {
        TabView(selection: $selectedPane) {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsPane.general)

            feedsTab
                .tabItem { Label("Subscriptions", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(SettingsPane.subscriptions)

            mutingTab
                .tabItem { Label("Muting", systemImage: "speaker.slash") }
                .tag(SettingsPane.muting)
                
            appearanceTab
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
                .tag(SettingsPane.appearance)

            notificationsTab
                .tabItem { Label("Notifications", systemImage: "bell") }
                .tag(SettingsPane.notifications)

            intelligenceTab
                .tabItem { Label("Intelligence", systemImage: "sparkles") }
                .tag(SettingsPane.intelligence)

            privacyTab
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
                .tag(SettingsPane.privacy)

            storageTab
                .tabItem { Label("Storage", systemImage: "externaldrive") }
                .tag(SettingsPane.storage)

            updatesTab
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
                .tag(SettingsPane.updates)
        }
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
                    .font(AppTypography.caption)
                    .foregroundColor(AppColor.secondaryText)
            }
            
            Section("Reading Behavior") {
                Toggle("Auto-Hide Read Articles", isOn: $themeManager.autoHideRead)
                Text("Articles will disappear from filtered views once marked as read.")
                    .font(AppTypography.caption)
                    .foregroundColor(AppColor.secondaryText)
            }
        }
        .formStyle(.grouped)
        .frame(width: Self.paneWidth)
    }

    // MARK: - 2. Subscriptions / Feeds Tab

    private var feedsTab: some View {
        VStack(spacing: 0) {
            // Add feed row
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .foregroundColor(AppColor.accent)
                    .imageScale(.large)
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
                    showsCatalog = true
                } label: {
                    Label("Browse Catalog...", systemImage: "books.vertical")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    OPMLDialogs.importOPML { data in
                        let count = feedManager.importFeeds(from: data)
                        opmlStatusMessage = count > 0 ? "Imported \(count) feed(s)" : "No new feeds imported."
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
                        .font(AppTypography.caption)
                        .foregroundColor(AppColor.success)
                }

                Spacer()
                Text("\(feedManager.feedURLs.count) feeds")
                    .font(AppTypography.caption)
                    .foregroundColor(AppColor.secondaryText)
            }
            .padding(.horizontal, AppLayout.pageInset)
            .padding(.bottom, 10)

            Divider()

            // Feed list
            List {
                ForEach(feedManager.feedURLs, id: \.self) { urlString in
                    HStack(spacing: 12) {
                        let status = feedManager.feedStatuses[urlString]
                        switch status {
                        case nil:
                            // No refresh this session yet: the health line below carries the stored state.
                            Image(systemName: "circle.dashed")
                                .foregroundColor(AppColor.secondaryText)
                                .font(AppTypography.body)
                                .accessibilityHidden(true)
                        case .idle?:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(AppColor.success)
                                .font(AppTypography.body)
                                .help("Feed is active and up to date")
                                .accessibilityLabel("Feed is active and up to date")
                        case .loading?:
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                                .frame(width: 14, height: 14)
                                .help("Fetching updates...")
                                .accessibilityLabel("Fetching updates...")
                        case .failed(let err)?:
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(AppColor.warning)
                                .font(AppTypography.body)
                                .help(err.localizedDescription)
                                .accessibilityLabel(err.localizedDescription)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(urlString)
                                .font(AppTypography.label.monospaced())
                                .lineLimit(1)
                                .foregroundColor(AppColor.primaryText)
                            FeedHealthLine(health: feedManager.feedHealth[urlString])
                        }
                        Spacer()
                        Button(role: .destructive) {
                            feedManager.removeFeed(url: urlString)
                        } label: {
                            Image(systemName: "trash")
                                .font(AppTypography.label)
                                .foregroundColor(AppColor.danger)
                        }
                        .buttonStyle(.plain)
                        .help("Unsubscribe from feed")
                        .accessibilityLabel("Unsubscribe from feed")
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.plain)

            Text(FeedHealth.disclaimer)
                .font(AppTypography.caption)
                .foregroundColor(AppColor.tertiaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppLayout.pageInset)
                .padding(.vertical, 8)
        }
        .frame(width: Self.paneWidth, height: 440)
        .task { await feedManager.reloadFeedHealth() }
        .sheet(isPresented: $showsCatalog) {
            FeedCatalogView()
        }
    }

    // MARK: - Muting Tab

    private var mutingTab: some View {
        Form {
            Section {
                Text("Muted stories leave Today, Unread, your sections, search and notifications. Saved Stories and History still list everything, and each list shows how many stories muting hides.")
                    .font(AppTypography.caption)
                    .foregroundColor(AppColor.secondaryText)
            }

            Section("Sources") {
                HStack(spacing: 10) {
                    TextField("Publisher hostname, such as example.com", text: $newMutedSource)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(muteNewSource)
                    Button("Mute", action: muteNewSource)
                        .controlSize(.small)
                        .disabled(MuteRules.host(newMutedSource) == nil)
                }
                Text("Hides stories whose link is on this host or one of its subdomains.")
                    .font(AppTypography.caption)
                    .foregroundColor(AppColor.secondaryText)
                ForEach(appSettings.muteRules.sources, id: \.self) { host in
                    mutingRow(host, count: muteCounts.sources[host] ?? 0) { appSettings.unmuteSource(host) }
                }
            }

            Section("Topics") {
                HStack(spacing: 10) {
                    TextField("Word or phrase", text: $newMutedTopic)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(muteNewTopic)
                    Button("Mute", action: muteNewTopic)
                        .controlSize(.small)
                        .disabled(MuteRules.phrase(newMutedTopic).isEmpty)
                }
                Text("Matches whole words in headlines and feed summaries, ignoring case: “art” hides “Art fair” but not “Artist”.")
                    .font(AppTypography.caption)
                    .foregroundColor(AppColor.secondaryText)
                ForEach(appSettings.muteRules.topics, id: \.self) { topic in
                    mutingRow(topic, count: muteCounts.topics[topic] ?? 0) { appSettings.unmuteTopic(topic) }
                }
            }

            Section {
                Button("Unmute All…", role: .destructive) { confirmsUnmuteAll = true }
                    .disabled(appSettings.muteRules.isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: Self.paneWidth)
        .task(id: appSettings.muteRules) {
            if let counts = try? await articleStore.database.mutedRuleCounts(appSettings.muteRules) {
                muteCounts = counts
            }
        }
        .confirmationDialog("Unmute every source and topic?", isPresented: $confirmsUnmuteAll) {
            Button("Unmute All", role: .destructive) { appSettings.clearMuting() }
        } message: {
            Text("Muted stories return to every list.")
        }
    }

    private func mutingRow(_ rule: String, count: Int, unmute: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(rule)
                .lineLimit(1)
                .foregroundColor(AppColor.primaryText)
            Spacer()
            Text(count == 1 ? "1 stored story" : "\(count) stored stories")
                .font(AppTypography.caption)
                .foregroundColor(AppColor.secondaryText)
            Button(action: unmute) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(AppColor.secondaryText)
            }
            .buttonStyle(.plain)
            .help("Unmute \(rule)")
            .accessibilityLabel("Unmute \(rule)")
        }
        .accessibilityElement(children: .contain)
    }

    private func muteNewSource() {
        if appSettings.muteSource(newMutedSource) != nil { newMutedSource = "" }
    }

    private func muteNewTopic() {
        if appSettings.muteTopic(newMutedTopic) != nil { newMutedTopic = "" }
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
                    .font(AppTypography.caption)
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
                        Image(systemName: appSettings.notificationMode == .privacy ? "lock.fill" : "info.circle")
                            .foregroundColor(appSettings.notificationMode == .privacy ? AppColor.success : AppColor.accent)
                        Text(appSettings.notificationMode.detail)
                            .font(AppTypography.caption)
                            .foregroundColor(AppColor.secondaryText)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: Self.paneWidth)
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
                    .font(AppTypography.caption)
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
                                .font(AppTypography.caption)
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
                                .font(AppTypography.caption)
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
                                .font(AppTypography.caption)
                                .foregroundColor(AppColor.secondaryText)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section("News Tension Index (Experiment)") {
                Toggle("Collect Panel Feeds for Tension Indicator", isOn: Binding(
                    get: { appSettings.tensionCollectionOptIn },
                    set: { feedManager.setTensionCollectionOptIn($0) }
                ))
                Text("Fetches articles from the 12 international panel feeds to calculate the news tension indicator. These articles are stored locally for tension analysis and will not generate unread notifications unless you subscribe to the feeds directly.")
                    .font(AppTypography.caption)
                    .foregroundColor(AppColor.secondaryText)
                Button("Show News Tension…") { openWindow(id: "tension") }
            }
        }
        .formStyle(.grouped)
        .frame(width: Self.paneWidth)
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
                            .font(AppTypography.caption)
                            .foregroundColor(AppColor.warning)
                    }
                } else {
                    Text("Enforces strict HTTPS connections for all feed ingestion and remote media assets.")
                        .font(AppTypography.caption)
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
                                .font(AppTypography.caption)
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
                                .font(AppTypography.caption)
                                .foregroundColor(AppColor.secondaryText)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .frame(width: Self.paneWidth)
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
                    .font(AppTypography.caption)
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
        .frame(width: Self.paneWidth)
    }

    // MARK: - 7. Storage Tab

    private var storageTab: some View {
        VStack(spacing: 16) {
            // Header stats
            HStack(spacing: 16) {
                Image(systemName: "externaldrive.fill")
                    .font(AppTypography.masthead)
                    .foregroundColor(AppColor.secondaryText)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Total Storage Usage")
                        .font(AppTypography.callout)
                        .foregroundColor(AppColor.secondaryText)
                    Text(totalStorageSize)
                        .font(AppTypography.title.monospacedDigit())
                        .foregroundColor(AppColor.primaryText)
                }

                Spacer()

                if let message = cacheActionMessage {
                    Text(message)
                        .font(AppTypography.label)
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
                                .font(AppTypography.headline)
                                .foregroundColor(AppColor.primaryText)
                            Text(webCacheSize)
                                .font(AppTypography.label.monospaced())
                                .foregroundColor(AppColor.secondaryText)
                        }
                        Text("HTTP network responses, temporary web data, and cached images.")
                            .font(AppTypography.caption)
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
                                .font(AppTypography.headline)
                                .foregroundColor(AppColor.primaryText)
                            Text("\(articleStore.articles.count) articles")
                                .font(AppTypography.label.monospacedDigit())
                                .foregroundColor(AppColor.secondaryText)
                        }
                        Text("Cached full article bodies. Subscriptions and saved stories are kept.")
                            .font(AppTypography.caption)
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
                                .font(AppTypography.headline)
                                .foregroundColor(AppColor.primaryText)
                            let aiCount = articleStore.articles.filter { $0.aiSummary != nil }.count
                            Text("\(aiCount) enriched")
                                .font(AppTypography.label.monospacedDigit())
                                .foregroundColor(AppColor.secondaryText)
                        }
                        Text("Generated summaries, key points, and entities. Subscriptions and articles remain.")
                            .font(AppTypography.caption)
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
                                .font(AppTypography.headline)
                                .foregroundColor(AppColor.primaryText)
                            Text(databaseSize)
                                .font(AppTypography.label.monospaced())
                                .foregroundColor(AppColor.secondaryText)
                        }
                        Text("Persistent WAL database containing subscriptions, history, and search index.")
                            .font(AppTypography.caption)
                            .foregroundColor(AppColor.secondaryText)
                    }
                    Spacer()
                    Text("Active")
                        .font(AppTypography.caption.bold())
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
                            .font(AppTypography.headline)
                            .foregroundColor(AppColor.danger)
                        Text("Purges web cache, article content, and AI analysis. Preserves subscriptions, saved stories, and read history.")
                            .font(AppTypography.caption)
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
            .padding(.bottom, AppSpacing.lg)
        }
        .frame(width: Self.paneWidth)
    }

    // MARK: - 8. Updates Tab

    private var updatesTab: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(AppTypography.masthead)
                .imageScale(.large)
                .foregroundColor(AppColor.accent)
                .padding(.top, 24)

            VStack(spacing: 4) {
                Text("NewsApp for macOS")
                    .font(AppTypography.headline.bold())
                    .foregroundColor(AppColor.primaryText)
                Text("Version \(updateChecker.currentAppVersion)")
                    .font(AppTypography.callout)
                    .foregroundColor(AppColor.secondaryText)
            }

            if let status = updateChecker.statusMessage {
                Text(status)
                    .font(AppTypography.callout)
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
                        .font(AppTypography.caption)
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
            .padding(.bottom, 16)

            VStack(spacing: 4) {
                Text("Direct release channel via GitHub Releases.")
                    .font(AppTypography.caption)
                    .foregroundColor(AppColor.secondaryText)
                Text("Native, privacy-first RSS reader with zero telemetry.")
                    .font(AppTypography.caption)
                    .foregroundColor(AppColor.tertiaryText)
            }
            .padding(.bottom, 16)
        }
        .frame(width: Self.paneWidth)
    }

    // MARK: - Storage & Cache Calculation Helpers

    private func calculateStorageSizes() {
        Task.detached(priority: .utility) {
            let webBytes = CacheManager.shared.calculateTotalCacheSize()
            let dbBytes = Self.calculateDatabaseBytes()
            let totalBytes = webBytes + dbBytes

            let formattedWeb = Self.formatBytes(webBytes)
            let formattedDb = Self.formatBytes(dbBytes)
            let formattedTotal = Self.formatBytes(totalBytes)

            await MainActor.run {
                self.webCacheSize = formattedWeb
                self.databaseSize = formattedDb
                self.totalStorageSize = formattedTotal
            }
        }
    }

    private nonisolated static func calculateDatabaseBytes() -> Int64 {
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

    private nonisolated static func formatBytes(_ bytes: Int64) -> String {
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
            do {
                try await articleStore.clearAIAnalysis()
                calculateStorageSizes()
                showActionMessage("AI analysis data cleared.")
            } catch {
                showActionMessage("Cache cleanup failed: \(error.localizedDescription)")
            }
        }
    }

    private func clearArticleData() {
        Task {
            do {
                try await articleStore.clearArticleCache()
                calculateStorageSizes()
                showActionMessage("Article body cache cleared.")
            } catch {
                showActionMessage("Cache cleanup failed: \(error.localizedDescription)")
            }
        }
    }

    private func clearEverythingData() {
        Task {
            CacheManager.shared.clearWebCache()
            do {
                try await articleStore.clearAllDatabaseCache()
                calculateStorageSizes()
                showActionMessage("All local caches cleared.")
            } catch {
                showActionMessage("Cache cleanup failed: \(error.localizedDescription)")
            }
        }
    }

    private func showActionMessage(_ msg: String) {
        withAnimation(reduceMotion ? nil : AppMotion.responsive) {
            cacheActionMessage = msg
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation(reduceMotion ? nil : AppMotion.responsive) {
                if cacheActionMessage == msg {
                    cacheActionMessage = nil
                }
            }
        }
    }
}
