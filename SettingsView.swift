import SwiftUI

private let stAccentPink = AppColor.accentPink
private let stTextSecondary = AppColor.textSecondary

struct SettingsView: View {
    @EnvironmentObject var appSettings: AppSettings
    @EnvironmentObject var feedManager: FeedManager
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var readManager: ReadManager
    
    @State private var newFeedURL: String = ""
    @State private var selectedTab = 0
    @State private var cacheSize: String = "Calculating..."
    @State private var opmlStatusMessage: String? = nil
    @ObservedObject private var updateChecker = UpdateChecker.shared

    var body: some View {
        TabView(selection: $selectedTab) {
            subscriptionsTab
                .tabItem { Label("Subscriptions", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(0)

            preferencesTab
                .tabItem { Label("Preferences", systemImage: "gearshape") }
                .tag(1)
                
            appearanceTab
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
                .tag(2)

            cacheTab
                .tabItem { Label("Storage", systemImage: "externaldrive") }
                .tag(3)
        }
        .frame(width: 560, height: 440)
        .onAppear { calculateCacheSize() }
    }

    // MARK: - Subscriptions Tab
    private var subscriptionsTab: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .foregroundColor(stAccentPink)
                    .font(.system(size: 18))
                TextField("Enter RSS feed URL", text: $newFeedURL)
                    .textFieldStyle(.roundedBorder)
                Button("Subscribe") {
                    if !newFeedURL.isEmpty {
                        feedManager.addFeed(url: newFeedURL)
                        newFeedURL = ""
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(stAccentPink)
                .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)

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
                        .foregroundColor(.green)
                }

                Spacer()
                Text("\(feedManager.feedURLs.count) feeds")
                    .font(.caption)
                    .foregroundColor(stTextSecondary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

            Divider()

            List {
                ForEach(feedManager.feedURLs, id: \.self) { urlString in
                    HStack(spacing: 12) {
                        let status = feedManager.feedStatuses[urlString] ?? .idle
                        switch status {
                        case .idle:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 14))
                                .help("Feed is active and up to date")
                        case .loading:
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                                .frame(width: 14, height: 14)
                                .help("Fetching updates...")
                        case .failed(let err):
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                                .font(.system(size: 14))
                                .help(err.localizedDescription)
                        }
                        Text(urlString)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                        Button {
                            feedManager.removeFeed(url: urlString)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(.red.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 6)
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Preferences Tab
    private var preferencesTab: some View {
        Form {
            Section {
                Picker("Background Fetch Interval", selection: Binding(
                    get: { appSettings.fetchIntervalMinutes },
                    set: { feedManager.setFetchInterval(minutes: $0) }
                )) {
                    Text("15 minutes").tag(15.0)
                    Text("30 minutes").tag(30.0)
                    Text("1 hour").tag(60.0)
                }
                .pickerStyle(.menu)
            }
            
            Section {
                Toggle("Push Notifications", isOn: Binding(
                    get: { appSettings.notificationsEnabled },
                    set: { appSettings.setNotificationsEnabled($0) }
                ))
                Text("Get alerts for important stories matching your interests")
                    .font(.caption)
                    .foregroundColor(stTextSecondary)
                
                if appSettings.notificationsEnabled {
                    Picker("Notification Detail", selection: Binding(
                        get: { appSettings.notificationMode },
                        set: { appSettings.setNotificationMode($0) }
                    )) {
                        ForEach(AppSettings.NotificationMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)

                    Text(appSettings.notificationMode == .private
                         ? "Shows generic alerts with no identifying source or headline."
                         : (appSettings.notificationMode == .minimal
                            ? "Aggregates alerts into a single count summary."
                            : "Displays article headline, source, and lead image."))
                        .font(.caption)
                        .foregroundColor(stTextSecondary)
                }
                    
                Toggle("AI Article Analysis", isOn: Binding(
                    get: { appSettings.aiEnabled },
                    set: { appSettings.setAIEnabled($0) }
                ))
                Text("Uses on-device NLP for sentiment scoring and entity extraction")
                    .font(.caption)
                    .foregroundColor(stTextSecondary)

                Toggle("Allow Insecure HTTP Feeds", isOn: Binding(
                    get: { appSettings.allowInsecureHTTP },
                    set: { appSettings.setAllowInsecureHTTP($0) }
                ))
                Text("Permit non-HTTPS feeds (Warning: unencrypted traffic over the network)")
                    .font(.caption)
                    .foregroundColor(stTextSecondary)
            }
            
            Section {
                Toggle("Auto-Hide Read Articles", isOn: $themeManager.autoHideRead)
                Text("Articles will disappear from filtered views once read")
                    .font(.caption)
                    .foregroundColor(stTextSecondary)
            }

            Section("Software Updates") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("NewsApp v\(updateChecker.currentAppVersion)")
                            .font(.system(size: 13, weight: .medium))
                        if let status = updateChecker.statusMessage {
                            Text(status)
                                .font(.caption)
                                .foregroundColor(updateChecker.updateAvailable ? stAccentPink : stTextSecondary)
                        }
                    }
                    Spacer()
                    if updateChecker.isChecking {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else if updateChecker.updateAvailable {
                        Button("View Release") {
                            updateChecker.openReleasePage()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(stAccentPink)
                    } else {
                        Button("Check Now") {
                            Task {
                                await updateChecker.checkForUpdates(userInitiated: true)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
    
    // MARK: - Appearance Tab
    private var appearanceTab: some View {
        Form {
            Section(header: Text("App Theme")) {
                Picker("Appearance", selection: $themeManager.appearance) {
                    ForEach(AppAppearance.allCases) { app in
                        Text(app.rawValue).tag(app)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.bottom, 10)
            }
            
            Section(header: Text("Article Typography Theme")) {
                Picker("Theme style", selection: $themeManager.articleTheme) {
                    ForEach(ArticleThemeType.allCases) { theme in
                        Text(theme.rawValue).tag(theme)
                    }
                }
                .pickerStyle(.radioGroup)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Cache Tab
    private var cacheTab: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 40))
                .foregroundColor(stTextSecondary)
            Text("Cached Data")
                .font(.system(size: 16, weight: .semibold))
            Text(cacheSize)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(stAccentPink)
            Text("Article data and images are cached locally\nfor fast offline access")
                .font(.system(size: 12))
                .foregroundColor(stTextSecondary)
                .multilineTextAlignment(.center)
            Button("Clear Cache") { clearCache() }
                .buttonStyle(.bordered)
                .tint(.red)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers
    private func calculateCacheSize() {
        DispatchQueue.global().async {
            let totalSize = CacheManager.shared.calculateTotalCacheSize()
            let formatted: String
            if totalSize < 1024 { formatted = "\(totalSize) B" }
            else if totalSize < 1024 * 1024 { formatted = String(format: "%.1f KB", Double(totalSize) / 1024.0) }
            else { formatted = String(format: "%.1f MB", Double(totalSize) / (1024.0 * 1024.0)) }
            DispatchQueue.main.async { self.cacheSize = formatted }
        }
    }

    private func clearCache() {
        CacheManager.shared.clearAllCache()
        cacheSize = "0 B"
    }
}
