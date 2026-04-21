import SwiftUI

// P3 palette (shared with MainView conceptually)
private let stAccentPink = Color(.displayP3, red: 1.0, green: 0.22, blue: 0.50, opacity: 1.0)
private let stSurfaceDark = Color(.displayP3, red: 0.08, green: 0.08, blue: 0.10, opacity: 1.0)
private let stTextPrimary = Color(.displayP3, red: 0.95, green: 0.95, blue: 0.97, opacity: 1.0)
private let stTextSecondary = Color(.displayP3, red: 0.65, green: 0.65, blue: 0.70, opacity: 1.0)

struct SettingsView: View {
    @EnvironmentObject var feedManager: FeedManager
    @State private var newFeedURL: String = ""
    @State private var selectedTab = 0
    @State private var fetchInterval: Double = 15
    @State private var notificationsEnabled: Bool = true
    @State private var aiEnabled: Bool = true
    @State private var cacheSize: String = "Calculating..."

    var body: some View {
        TabView(selection: $selectedTab) {
            subscriptionsTab
                .tabItem { Label("Subscriptions", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(0)

            preferencesTab
                .tabItem { Label("Preferences", systemImage: "gearshape") }
                .tag(1)

            cacheTab
                .tabItem { Label("Storage", systemImage: "externaldrive") }
                .tag(2)
        }
        .frame(width: 560, height: 440)
        .background(stSurfaceDark)
        .onAppear { calculateCacheSize() }
    }

    // MARK: - Subscriptions Tab

    private var subscriptionsTab: some View {
        VStack(spacing: 0) {
            // Add feed bar
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .foregroundColor(stAccentPink)
                    .font(.system(size: 18))
                TextField("Enter RSS feed URL", text: $newFeedURL)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(8)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(8)
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
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider().background(Color.white.opacity(0.1))

            // Feed list
            List {
                ForEach(feedManager.feedURLs, id: \.self) { urlString in
                    HStack(spacing: 12) {
                        Image(systemName: "dot.radiowaves.up.forward")
                            .foregroundColor(stAccentPink)
                            .font(.system(size: 14))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(urlString)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(stTextPrimary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button {
                            feedManager.removeFeed(url: urlString)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(.red.opacity(0.7))
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 6)
                    .listRowBackground(Color.white.opacity(0.03))
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: - Preferences Tab

    private var preferencesTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Fetch interval
            VStack(alignment: .leading, spacing: 8) {
                Text("Background Fetch Interval")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(stTextPrimary)
                Picker("", selection: $fetchInterval) {
                    Text("15 minutes").tag(15.0)
                    Text("30 minutes").tag(30.0)
                    Text("1 hour").tag(60.0)
                }
                .pickerStyle(.segmented)
            }

            Divider().background(Color.white.opacity(0.1))

            // Notifications toggle
            Toggle(isOn: $notificationsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Push Notifications")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(stTextPrimary)
                    Text("Get alerts for important stories matching your interests")
                        .font(.system(size: 12))
                        .foregroundColor(stTextSecondary)
                }
            }
            .toggleStyle(.switch)
            .tint(stAccentPink)

            Divider().background(Color.white.opacity(0.1))

            // AI toggle
            Toggle(isOn: $aiEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI Article Analysis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(stTextPrimary)
                    Text("Uses on-device NLP for sentiment scoring and entity extraction")
                        .font(.system(size: 12))
                        .foregroundColor(stTextSecondary)
                }
            }
            .toggleStyle(.switch)
            .tint(stAccentPink)

            Spacer()
        }
        .padding(24)
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
                .foregroundColor(stTextPrimary)

            Text(cacheSize)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(stAccentPink)

            Text("Article data and images are cached locally\nfor fast offline access")
                .font(.system(size: 12))
                .foregroundColor(stTextSecondary)
                .multilineTextAlignment(.center)

            Button("Clear Cache") {
                clearCache()
            }
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
            if totalSize < 1024 {
                formatted = "\(totalSize) B"
            } else if totalSize < 1024 * 1024 {
                formatted = String(format: "%.1f KB", Double(totalSize) / 1024.0)
            } else {
                formatted = String(format: "%.1f MB", Double(totalSize) / (1024.0 * 1024.0))
            }

            DispatchQueue.main.async {
                self.cacheSize = formatted
            }
        }
    }

    private func clearCache() {
        let fm = FileManager.default
        let paths = fm.urls(for: .cachesDirectory, in: .userDomainMask)
        let cacheDir = paths[0].appendingPathComponent("com.marspater.news.cache")
        try? fm.removeItem(at: cacheDir)
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        cacheSize = "0 B"
    }
}
