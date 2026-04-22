import SwiftUI

private let stAccentPink = Color(.displayP3, red: 1.0, green: 0.22, blue: 0.50, opacity: 1.0)
private let stTextSecondary = Color.secondary

struct SettingsView: View {
    @EnvironmentObject var feedManager: FeedManager
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var readManager: ReadManager
    
    @State private var newFeedURL: String = ""
    @State private var selectedTab = 0
    @State private var cacheSize: String = "Calculating..."

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
            .padding(20)

            Divider()

            List {
                ForEach(feedManager.feedURLs, id: \.self) { urlString in
                    HStack(spacing: 12) {
                        Image(systemName: "dot.radiowaves.up.forward")
                            .foregroundColor(stAccentPink)
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
                    get: { feedManager.fetchIntervalMinutes },
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
                    get: { feedManager.notificationsEnabled },
                    set: { feedManager.setNotificationsEnabled($0) }
                ))
                Text("Get alerts for important stories matching your interests")
                    .font(.caption)
                    .foregroundColor(stTextSecondary)
                    
                Toggle("AI Article Analysis", isOn: Binding(
                    get: { feedManager.aiEnabled },
                    set: { feedManager.setAIEnabled($0) }
                ))
                Text("Uses on-device NLP for sentiment scoring and entity extraction")
                    .font(.caption)
                    .foregroundColor(stTextSecondary)
            }
            
            Section {
                Toggle("Auto-Hide Read Articles", isOn: $themeManager.autoHideRead)
                Text("Articles will disappear from filtered views once read")
                    .font(.caption)
                    .foregroundColor(stTextSecondary)
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
            let fm = FileManager.default
            let paths = fm.urls(for: .cachesDirectory, in: .userDomainMask)
            let cacheDir = paths[0].appendingPathComponent("com.marspater.news.cache")
            var totalSize: Int64 = 0
            if let enumerator = fm.enumerator(at: cacheDir, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let fileURL as URL in enumerator {
                    if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        totalSize += Int64(size)
                    }
                }
            }
            let formatted: String
            if totalSize < 1024 { formatted = "\(totalSize) B" }
            else if totalSize < 1024 * 1024 { formatted = String(format: "%.1f KB", Double(totalSize) / 1024.0) }
            else { formatted = String(format: "%.1f MB", Double(totalSize) / (1024.0 * 1024.0)) }
            DispatchQueue.main.async { self.cacheSize = formatted }
        }
    }

    private func clearCache() {
        let fm = FileManager.default
        let paths = fm.urls(for: .cachesDirectory, in: .userDomainMask)
        let cacheDir = paths[0].appendingPathComponent("com.marspater.news.cache")
        try? fm.removeItem(at: cacheDir)
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        cacheSize = "0 B"
        readManager.readArticles.removeAll()
        UserDefaults.standard.set([], forKey: "com.marspater.news.readArticlesList")
    }
}
