import AppKit
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case subscriptions
    case muting
    case reading
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
    /// Wide enough for all ten tabs in the toolbar, so none overflow into a menu.
    static let paneWidth = AppLayout.settingsPaneWidth
    static let paneHeight = AppLayout.settingsPaneHeight

    static func predefinedCategory(for section: String) -> NewsCategory? {
        let name = section.trimmingCharacters(in: .whitespacesAndNewlines)
        if let category = NewsCategory.allCases.first(where: {
            $0.rawValue.caseInsensitiveCompare(name) == .orderedSame
        }) {
            return category
        }
        switch name.lowercased() {
        case "tech": return .technology
        case "u.s. politics": return .politics
        case "health & wellness": return .health
        default: return nil
        }
    }

    /// A category is on while any sidebar section maps to it; turning it off removes every such section. Shared
    /// with the first-launch sheet.
    static func sectionBinding(_ category: NewsCategory, feedManager: FeedManager) -> Binding<Bool> {
        Binding(
            get: { feedManager.userSections.contains { predefinedCategory(for: $0) == category } },
            set: { enabled in
                if enabled {
                    feedManager.addSection(category.rawValue)
                } else {
                    for section in feedManager.userSections where predefinedCategory(for: section) == category {
                        feedManager.removeSection(section)
                    }
                }
            })
    }

    @EnvironmentObject var appSettings: AppSettings
    @EnvironmentObject var articleStore: ArticleStore
    @EnvironmentObject var feedManager: FeedManager
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var readManager: ReadManager
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow

    @AppStorage(SettingsView.lastPaneStorageKey) private var selectedPane: SettingsPane = .general
    @AppStorage("briefingEditionHour") private var briefingEditionHour = FiniteBriefing.defaultEditionHour
    @AppStorage(AppSettings.readingInterestsResetAtKey) private var readingInterestsResetAt = 0.0
    @State private var newFeedURL: String = ""
    @State private var webCacheSize: String = "Calculating…"
    @State private var databaseSize: String = "Calculating…"
    @State private var totalStorageSize: String = "Calculating…"
    @State private var cacheActionMessage: String? = nil
    @State private var cacheActionFailed = false
    @State private var pendingClear: StorageClear?
    @State private var pendingUnsubscribe: String?
    @State private var showsCatalog = false
    @State private var newMutedSource = ""
    @State private var newMutedTopic = ""
    @State private var muteCounts = MuteRuleCounts()
    /// The reader's current top interest categories, shown with the full-mode notification rule.
    @State private var notificationInterests: [String] = []
    @State private var confirmsUnmuteAll = false
    @State private var inferredInterests: [String: Int] = [:]
    @State private var confirmsResetInterests = false
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

            readingTab
                .tabItem { Label("Reading", systemImage: "book") }
                .tag(SettingsPane.reading)

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
        .frame(width: Self.paneWidth, height: Self.paneHeight)
        .onAppear { calculateStorageSizes() }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .tracking(AppTypography.sectionHeaderTracking)
    }

    // MARK: - 1. General Tab

    private var generalTab: some View {
        Form {
            Section(header: sectionHeader("Feed Refresh & Sync")) {
                Picker(
                    "Background Refresh Interval",
                    selection: Binding(
                        get: { appSettings.fetchIntervalMinutes },
                        set: { feedManager.setFetchInterval(minutes: $0) }
                    )
                ) {
                    Text("15 minutes").tag(15.0)
                    Text("30 minutes").tag(30.0)
                    Text("1 hour").tag(60.0)
                    Text("2 hours").tag(120.0)
                }
                .pickerStyle(.menu)

                Text("Periodic feed updates occur in the background when News is running.")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColor.secondaryText)
            }

            Section(header: sectionHeader("Predefined Categories")) {
                ForEach(NewsCategory.allCases, id: \.self) { category in
                    Toggle(category.rawValue, isOn: Self.sectionBinding(category, feedManager: feedManager))
                }
                Text("Choose the categories shown in the sidebar. Your existing sections stay available.")
                    .font(AppTypography.caption).foregroundStyle(AppColor.secondaryText)
            }

            Section(header: sectionHeader("Reading Behavior")) {
                Toggle("Auto-Hide Read Stories", isOn: $themeManager.autoHideRead)
                Text("Stories will disappear from filtered views once marked as read.")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColor.secondaryText)
                Picker("Daily Briefing Edition", selection: $briefingEditionHour) {
                    ForEach(0..<24, id: \.self) { hour in
                        Text(
                            Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())?
                                .formatted(date: .omitted, time: .shortened) ?? "\(hour):00"
                        ).tag(hour)
                    }
                }
                Text("Briefing selects one edition a day at this time and keeps it until the next one.")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColor.secondaryText)
            }
        }
        .formStyle(.grouped)
        .frame(width: Self.paneWidth)
    }

    // MARK: - 2. Subscriptions / Feeds Tab

    private var feedsTab: some View {
        VStack(spacing: 0) {
            // Add feed row
            HStack(spacing: AppSpacing.xs) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(AppColor.accentText)
                    .imageScale(.large)
                TextField("Feed URL", text: $newFeedURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(subscribeFromField)
                Button("Subscribe", action: subscribeFromField)
                    .buttonStyle(.borderedProminent)
                    .tint(AppColor.accent)
                    .controlSize(.small)
                    .disabled(newFeedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, AppLayout.pageInset)
            .padding(.top, AppSpacing.md)
            .padding(.bottom, AppSpacing.xs)

            // OPML actions bar
            HStack(spacing: AppSpacing.xs) {
                Button {
                    showsCatalog = true
                } label: {
                    Label("Browse Catalog…", systemImage: "books.vertical")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    OPMLDialogs.importOPML { data in
                        let count = feedManager.importFeeds(from: data)
                        showActionMessage(
                            count > 0 ? "Imported \(count) \(count == 1 ? "feed" : "feeds")" : "No new feeds imported")
                    }
                } label: {
                    Label("Import OPML…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    let opml = feedManager.exportOPML()
                    OPMLDialogs.exportOPML(xmlString: opml)
                } label: {
                    Label("Export OPML…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                actionStatus

                Spacer()
                Text("\(feedManager.feedURLs.count) \(feedManager.feedURLs.count == 1 ? "feed" : "feeds")")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColor.secondaryText)
            }
            .padding(.horizontal, AppLayout.pageInset)
            .padding(.bottom, AppSpacing.xs)

            Divider()

            // Form keeps subscription actions reachable through system keyboard navigation.
            Form {
                let starLimitReached = appSettings.starredFeedURLs.count >= AppSettings.starredFeedLimit
                if starLimitReached {
                    Text("Up to \(AppSettings.starredFeedLimit) feeds can be starred")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColor.secondaryText)
                }
                ForEach(feedManager.feedURLs, id: \.self) { urlString in
                    HStack(spacing: AppSpacing.sm) {
                        let status = feedManager.feedStatuses[urlString]
                        switch status {
                        case nil:
                            // No refresh this session yet: the health line below carries the stored state.
                            Image(systemName: "circle.dashed")
                                .foregroundStyle(AppColor.secondaryText)
                                .font(AppTypography.body)
                                .accessibilityHidden(true)
                        case .idle?:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(AppColor.success)
                                .font(AppTypography.body)
                                .help("Feed is active and up to date")
                                .accessibilityLabel("Feed is active and up to date")
                        case .loading?:
                            // The AppKit-backed spinner is hidden; a plain container carries the label (DESIGN.md 16).
                            HStack {
                                ProgressView()
                                    .controlSize(.mini)
                                    .accessibilityHidden(true)
                            }
                            .help("Fetching updates…")
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Fetching updates…")
                        case .failed(let err)?:
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(AppColor.warning)
                                .font(AppTypography.body)
                                .help(err.localizedDescription)
                                .accessibilityLabel(err.localizedDescription)
                        }
                        VStack(alignment: .leading, spacing: AppSpacing.textStack) {
                            Text(urlString)
                                .font(AppTypography.label.monospaced())
                                .lineLimit(1)
                                .foregroundStyle(AppColor.primaryText)
                            FeedHealthLine(health: feedManager.feedHealth[urlString])
                            if let advisory = appSettings.visibleAdvisory(for: urlString) {
                                let alternatives = FeedCatalog.alternatives(for: urlString)
                                    .filter { !appSettings.isSubscribed($0) }
                                NoticeView(tint: AppColor.warning) {
                                    VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                                        Text("Review note (\(advisory.date)): \(advisory.summary)")
                                            .font(AppTypography.caption)
                                            .foregroundStyle(AppColor.primaryText)
                                            .fixedSize(horizontal: false, vertical: true)
                                        HStack(spacing: AppSpacing.sm) {
                                            if !alternatives.isEmpty {
                                                Menu("Alternatives") {
                                                    ForEach(alternatives) { feed in
                                                        Button("Subscribe to \(feed.title)") {
                                                            feedManager.addCatalogFeeds([feed])
                                                        }
                                                    }
                                                }
                                                .font(AppTypography.caption)
                                                .controlSize(.small)
                                                .fixedSize()
                                                .accessibilityLabel("Alternatives to \(urlString)")
                                            }

                                            Button("Dismiss") {
                                                appSettings.dismissAdvisory(for: urlString, date: advisory.date)
                                            }
                                            .font(AppTypography.caption)
                                            .controlSize(.small)
                                            .accessibilityLabel("Dismiss review note for \(urlString)")
                                        }
                                    }
                                }
                            }
                        }
                        Spacer()
                        let starred = appSettings.starredFeedURLs.contains(urlString)
                        Button {
                            appSettings.setFeedStarred(urlString, !starred)
                        } label: {
                            Image(systemName: starred ? "star.fill" : "star")
                                .font(AppTypography.label)
                                .foregroundStyle(starred ? AppColor.accentText : AppColor.secondaryText)
                        }
                        .buttonStyle(.plain)
                        .disabled(!starred && starLimitReached)
                        .help(
                            starred
                                ? "Notifies about every story"
                                : starLimitReached
                                    ? "Up to \(AppSettings.starredFeedLimit) feeds can be starred"
                                    : "Notify about every story"
                        )
                        .accessibilityLabel(
                            starred
                                ? "Stop notifying about every story from this feed"
                                : "Notify about every story from this feed")
                        Button(role: .destructive) {
                            pendingUnsubscribe = urlString
                        } label: {
                            Image(systemName: "trash")
                                .font(AppTypography.label)
                                .foregroundStyle(AppColor.danger)
                        }
                        .buttonStyle(.plain)
                        .help("Unsubscribe from feed")
                        .accessibilityLabel("Unsubscribe from feed")
                    }
                    .padding(.vertical, AppSpacing.xxs)
                    .accessibilityElement(children: .contain)
                }
            }
            .formStyle(.grouped)
            .confirmationDialog(
                "Unsubscribe from “\(pendingUnsubscribe ?? "")”?",
                isPresented: Binding(get: { pendingUnsubscribe != nil }, set: { if !$0 { pendingUnsubscribe = nil } }),
                presenting: pendingUnsubscribe
            ) { url in
                Button("Unsubscribe", role: .destructive) { feedManager.removeFeed(url: url) }
            } message: { _ in
                Text("Stories already in your library stay; no new stories arrive from this feed.")
            }

            Text(FeedHealth.disclaimer)
                .font(AppTypography.caption)
                .foregroundStyle(AppColor.tertiaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppLayout.pageInset)
                .padding(.vertical, AppSpacing.xs)
        }
        .frame(width: Self.paneWidth, height: Self.paneHeight)
        .task { await feedManager.reloadFeedHealth() }
        .sheet(isPresented: $showsCatalog) {
            FeedCatalogView()
        }
    }

    // MARK: - Muting Tab

    private var mutingTab: some View {
        Form {
            Section {
                Text(
                    "Muted stories leave Today, Unread, your sections, search and notifications. Saved Stories and History still list everything, and each list shows how many stories muting hides."
                )
                .font(AppTypography.caption)
                .foregroundStyle(AppColor.secondaryText)
            }

            Section(header: sectionHeader("Sources")) {
                HStack(spacing: AppSpacing.xs) {
                    TextField("Publisher hostname, such as example.com", text: $newMutedSource)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(muteNewSource)
                    Button("Mute", action: muteNewSource)
                        .controlSize(.small)
                        .disabled(MuteRules.host(newMutedSource) == nil)
                }
                Text("Hides stories whose link is on this host or one of its subdomains.")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColor.secondaryText)
                ForEach(appSettings.muteRules.sources, id: \.self) { host in
                    mutingRow(host, count: muteCounts.sources[host] ?? 0) { appSettings.unmuteSource(host) }
                }
            }

            Section(header: sectionHeader("Topics")) {
                HStack(spacing: AppSpacing.xs) {
                    TextField("Word or phrase", text: $newMutedTopic)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(muteNewTopic)
                    Button("Mute", action: muteNewTopic)
                        .controlSize(.small)
                        .disabled(MuteRules.phrase(newMutedTopic).isEmpty)
                }
                Text(
                    "Matches whole words in headlines and feed summaries, ignoring case: “art” hides “Art fair” but not “Artist”."
                )
                .font(AppTypography.caption)
                .foregroundStyle(AppColor.secondaryText)
                ForEach(appSettings.muteRules.topics, id: \.self) { topic in
                    mutingRow(topic, count: muteCounts.topics[topic] ?? 0) { appSettings.unmuteTopic(topic) }
                }
            }

            Section(header: sectionHeader("Topic Sets")) {
                Text("Each set mutes a fixed list of words and phrases together, as whole words, with one switch.")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColor.secondaryText)
                ForEach(MuteTopicSet.all, content: topicSetRow)
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
            Text("Muted stories return to every list, and every topic set is switched off.")
        }
    }

    /// One switch per fixed topic set, with its phrases and, when on, how many stored stories it hides.
    private func topicSetRow(_ topicSet: MuteTopicSet) -> some View {
        let isOn = appSettings.muteRules.topicSets.contains(topicSet.id)
        let count = muteCounts.topicSets[topicSet.id] ?? 0
        let binding = Binding(get: { isOn }, set: { appSettings.setTopicSet(topicSet.id, muted: $0) })
        return Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: AppSpacing.textStack) {
                Text(topicSet.title)
                    .foregroundStyle(AppColor.primaryText)
                Text(topicSet.phrases.joined(separator: ", "))
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColor.secondaryText)
                    .lineLimit(2)
                if isOn {
                    Text(count == 1 ? "Hides 1 stored story" : "Hides \(count) stored stories")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColor.secondaryText)
                }
            }
        }
    }

    private func mutingRow(_ rule: String, count: Int, unmute: @escaping () -> Void) -> some View {
        HStack(spacing: AppSpacing.sm) {
            Text(rule)
                .lineLimit(1)
                .foregroundStyle(AppColor.primaryText)
            Spacer()
            Text(count == 1 ? "1 stored story" : "\(count) stored stories")
                .font(AppTypography.caption)
                .foregroundStyle(AppColor.secondaryText)
            Button(action: unmute) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(AppColor.secondaryText)
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

    // MARK: - Reading Tab

    private var readingTab: some View {
        Form {
            Section(header: sectionHeader("Inferred Interests")) {
                Text(
                    "News infers your topic interests privately on this Mac based on stories you read and save over the last 30 days. These signals help prioritize relevant coverage in your Daily Briefing."
                )
                .font(AppTypography.caption)
                .foregroundStyle(AppColor.secondaryText)

                if sortedInterests.isEmpty {
                    Text("No reading interests recorded yet. Read or save stories to build interest signals.")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColor.tertiaryText)
                        .padding(.vertical, AppSpacing.xxs)
                } else {
                    ForEach(sortedInterests, id: \.category) { item in
                        HStack {
                            Text(categoryDisplayName(for: item.category))
                                .font(AppTypography.body)
                                .foregroundStyle(AppColor.primaryText)
                            Spacer()
                            Text("\(item.score) \(item.score == 1 ? "point" : "points")")
                                .font(AppTypography.label.monospacedDigit())
                                .foregroundStyle(AppColor.secondaryText)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            "\(categoryDisplayName(for: item.category)), \(item.score) \(item.score == 1 ? "point" : "points")"
                        )
                    }
                }
            }

            Section {
                Button("Reset Reading Interests…", role: .destructive) {
                    confirmsResetInterests = true
                }
                .disabled(inferredInterests.isEmpty && readingInterestsResetAt == 0)
                .accessibilityLabel("Reset Reading Interests")
                .accessibilityHint(
                    "Clears all inferred category weights immediately. Preserves read history and saved stories."
                )

                Text("Clears all inferred category weights immediately. Read history and saved stories are preserved.")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColor.secondaryText)
            }
        }
        .formStyle(.grouped)
        .frame(width: Self.paneWidth)
        .task(id: readingInterestsResetAt) {
            await reloadReadingInterests()
        }
        .confirmationDialog(
            "Reset reading interests?",
            isPresented: $confirmsResetInterests
        ) {
            Button("Reset Reading Interests", role: .destructive) {
                resetReadingInterests()
            }
        } message: {
            Text(
                "Inferred category signals will be cleared immediately. Your read history and saved stories will not be deleted."
            )
        }
    }

    private var sortedInterests: [(category: String, score: Int)] {
        inferredInterests
            .map { (category: $0.key, score: $0.value) }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                return lhs.category < rhs.category
            }
    }

    private func categoryDisplayName(for key: String) -> String {
        if let category = NewsCategory.match(from: key) {
            return category.rawValue
        }
        return key.capitalized
    }

    @MainActor
    private func reloadReadingInterests() async {
        let cutoff = readingInterestsResetAt > 0 ? Date(timeIntervalSince1970: readingInterestsResetAt) : nil
        do {
            inferredInterests = try await articleStore.database.briefingInterests(now: Date(), resetAt: cutoff)
        } catch {
            inferredInterests = [:]
        }
    }

    private func resetReadingInterests() {
        let now = Date().timeIntervalSince1970
        readingInterestsResetAt = now
        inferredInterests = [:]
    }

    // MARK: - 3. Notifications Tab

    private var notificationsTab: some View {
        Form {
            Section(header: sectionHeader("Notification Delivery")) {
                Toggle(
                    "Enable Notifications",
                    isOn: Binding(
                        get: { appSettings.notificationsEnabled },
                        set: { appSettings.setNotificationsEnabled($0) }
                    ))
                Text("Receive native macOS notification alerts when high-importance news arrives.")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColor.secondaryText)
                Toggle(
                    "Show Badge on Dock Icon",
                    isOn: Binding(
                        get: { appSettings.showsDockBadge },
                        set: { appSettings.setShowsDockBadge($0) }
                    ))
                Text(
                    "Counts unread stories in today's Briefing and unread stories a notification showed since News opened."
                )
                .font(AppTypography.caption)
                .foregroundStyle(AppColor.secondaryText)
                Toggle(
                    "Show in Menu Bar",
                    isOn: Binding(
                        get: { appSettings.showsMenuBarExtra },
                        set: { appSettings.setShowsMenuBarExtra($0) }
                    ))
            }

            if appSettings.notificationsEnabled {
                Section(header: sectionHeader("Notification Privacy & Detail")) {
                    Picker(
                        "Detail Level",
                        selection: Binding(
                            get: { appSettings.notificationMode },
                            set: { appSettings.setNotificationMode($0) }
                        )
                    ) {
                        ForEach(AppSettings.NotificationMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    HStack(spacing: AppSpacing.xs) {
                        Image(systemName: appSettings.notificationMode == .privacy ? "lock.fill" : "info.circle")
                            .foregroundStyle(
                                appSettings.notificationMode == .privacy ? AppColor.success : AppColor.accentText)
                        Text(appSettings.notificationMode.detail)
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColor.secondaryText)
                    }
                    .padding(.top, AppSpacing.xxs)
                    if appSettings.notificationMode == .full {
                        Text(fullNotificationRule)
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColor.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: Self.paneWidth)
        .task {
            // The same interests notification triage ranks by, so a reset shows here at once (#806).
            let cutoff = readingInterestsResetAt > 0 ? Date(timeIntervalSince1970: readingInterestsResetAt) : nil
            let weights = (try? await articleStore.database.briefingInterests(now: Date(), resetAt: cutoff)) ?? [:]
            notificationInterests = NotificationService.rankedInterests(weights).compactMap { key in
                NewsCategory.allCases.first { $0.rawValue.lowercased() == key }?.rawValue
            }
        }
    }

    /// The full-mode rule in one sentence, with the interests it currently reads (#588, #665).
    private var fullNotificationRule: String {
        let interests =
            notificationInterests.isEmpty
            ? "your top reading interests (none yet; they come from the stories you open and save)"
            : "your top reading interests (\(notificationInterests.joined(separator: ", ")))"
        return
            "Major news covered by four or more publishers always notifies; starred feeds arrive grouped, one banner per feed every 20 minutes at most; other breaking stories, and stories in \(interests) that three or more publishers cover, notify at most five times an hour."
    }

    // MARK: - 4. Intelligence Tab

    private var intelligenceTab: some View {
        Form {
            Section(header: sectionHeader("On-Device Intelligence")) {
                Toggle(
                    "Enable AI Story Analysis",
                    isOn: Binding(
                        get: { appSettings.aiEnabled },
                        set: { appSettings.setAIEnabled($0) }
                    ))
                Text("Summaries, key points, entities and tone for each story, generated on this Mac.")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColor.secondaryText)
            }

            Section(header: sectionHeader("How It Works")) {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    HStack(alignment: .top, spacing: AppSpacing.xs) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(AppColor.intelligence)
                            .padding(.top, AppSpacing.textStack)
                        VStack(alignment: .leading, spacing: AppSpacing.textStack) {
                            Text("Apple models on this Mac")
                                .font(AppTypography.label)
                                .foregroundStyle(AppColor.primaryText)
                            Text(
                                "Uses Apple's Natural Language framework and, where available, the on-device Foundation Models."
                            )
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColor.secondaryText)
                        }
                    }

                    HStack(alignment: .top, spacing: AppSpacing.xs) {
                        Image(systemName: "bolt.shield")
                            .foregroundStyle(AppColor.accentText)
                            .padding(.top, AppSpacing.textStack)
                        VStack(alignment: .leading, spacing: AppSpacing.textStack) {
                            Text("When it runs")
                                .font(AppTypography.label)
                                .foregroundStyle(AppColor.primaryText)
                            Text(
                                "Analysis runs on demand and after feed refreshes. World Tension assessments pause in Low Power Mode or under thermal pressure."
                            )
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColor.secondaryText)
                        }
                    }

                    HStack(alignment: .top, spacing: AppSpacing.xs) {
                        Image(systemName: "hand.raised.fill")
                            .foregroundStyle(AppColor.success)
                            .padding(.top, AppSpacing.textStack)
                        VStack(alignment: .leading, spacing: AppSpacing.textStack) {
                            Text("Nothing leaves your Mac")
                                .font(AppTypography.label)
                                .foregroundStyle(AppColor.primaryText)
                            Text(
                                "No text, prompts or embeddings are sent anywhere."
                            )
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColor.secondaryText)
                        }
                    }
                }
                .padding(.vertical, AppSpacing.xxs)
            }

            Section(header: sectionHeader("World Tension Index (Experiment)")) {
                Toggle(
                    "Collect Panel Feeds for Tension Indicator",
                    isOn: Binding(
                        get: { appSettings.tensionCollectionOptIn },
                        set: { feedManager.setTensionCollectionOptIn($0) }
                    ))
                Text(
                    "Fetches stories from the 12 international panel feeds to calculate the AI World Tension assessment. Analysis-only stories stay out of your feed, Briefing and unread counts unless you subscribe. Stories you read or save remain accessible."
                )
                .font(AppTypography.caption)
                .foregroundStyle(AppColor.secondaryText)
                Button("Show World Tension…") {
                    NewsTensionRequest.post()
                    openWindow(id: "main")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: Self.paneWidth)
    }

    // MARK: - 5. Privacy & Security Tab

    private var privacyTab: some View {
        Form {
            Section(header: sectionHeader("Network")) {
                Toggle(
                    "Allow Insecure HTTP Feeds",
                    isOn: Binding(
                        get: { appSettings.allowInsecureHTTP },
                        set: { appSettings.setAllowInsecureHTTP($0) }
                    ))

                if appSettings.allowInsecureHTTP {
                    NoticeView(tint: AppColor.warning) {
                        Label {
                            Text("Feeds over plain HTTP can be read and changed by anyone on the network path.")
                                .font(AppTypography.caption)
                                .foregroundStyle(AppColor.primaryText)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(AppColor.warning)
                        }
                    }
                } else {
                    Text("Feeds and images are loaded over HTTPS only.")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColor.secondaryText)
                }
            }

            Section(header: sectionHeader("Security Standards")) {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    HStack(alignment: .top, spacing: AppSpacing.xs) {
                        Image(systemName: "shield.lefthalf.filled")
                            .foregroundStyle(AppColor.accentText)
                            .padding(.top, AppSpacing.textStack)
                        VStack(alignment: .leading, spacing: AppSpacing.textStack) {
                            Text("Hardened Runtime & App Sandbox")
                                .font(AppTypography.label)
                                .foregroundStyle(AppColor.primaryText)
                            Text("Restricts file system and process access to News's isolated container.")
                                .font(AppTypography.caption)
                                .foregroundStyle(AppColor.secondaryText)
                        }
                    }

                    HStack(alignment: .top, spacing: AppSpacing.xs) {
                        Image(systemName: "network.badge.shield.half.filled")
                            .foregroundStyle(AppColor.success)
                            .padding(.top, AppSpacing.textStack)
                        VStack(alignment: .leading, spacing: AppSpacing.textStack) {
                            Text("Direct Connection")
                                .font(AppTypography.label)
                                .foregroundStyle(AppColor.primaryText)
                            Text(
                                "Fetches feeds directly from publishers without middleman cloud servers, proxy aggregators, or telemetry logging."
                            )
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColor.secondaryText)
                        }
                    }
                }
                .padding(.vertical, AppSpacing.xxs)
            }
        }
        .formStyle(.grouped)
        .frame(width: Self.paneWidth)
    }

    // MARK: - 6. Appearance Tab

    private var appearanceTab: some View {
        Form {
            Section(header: sectionHeader("App Appearance")) {
                Picker("Interface Style", selection: $themeManager.appearance) {
                    ForEach(AppAppearance.allCases) { app in
                        Text(app.rawValue).tag(app)
                    }
                }
                .pickerStyle(.segmented)

                Text(
                    "Select whether News follows your macOS system appearance or stays locked to light or dark mode."
                )
                .font(AppTypography.caption)
                .foregroundStyle(AppColor.secondaryText)
            }

            Section(header: sectionHeader("Reading")) {
                Picker("Reading Style", selection: $themeManager.articleTheme) {
                    ForEach(ArticleThemeType.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .pickerStyle(.radioGroup)

                // Typography Preview
                VStack(alignment: .leading, spacing: AppSpacing.eyebrowGap) {
                    Text("The quick brown fox jumps over the lazy dog.")
                        .font(AppTypography.headlineFont(for: themeManager.articleTheme))
                        .foregroundStyle(AppColor.primaryText)
                    Text(
                        "Editorial typography determines the headline and body font families, line spacing, and tracking used in reader mode."
                    )
                    .font(AppTypography.bodyFont(for: themeManager.articleTheme))
                    .foregroundStyle(AppColor.secondaryText)
                    .lineSpacing(AppTypography.bodyLineSpacing(for: themeManager.articleTheme))
                }
                .padding(AppSpacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                        .fill(AppColor.surface)
                )
            }
        }
        .formStyle(.grouped)
        .frame(width: Self.paneWidth)
    }

    // MARK: - 7. Storage Tab

    private var storageTab: some View {
        Form {
            Section {
                LabeledContent {
                    Text(totalStorageSize)
                        .font(AppTypography.title.monospacedDigit())
                        .foregroundStyle(AppColor.primaryText)
                } label: {
                    Label("Total Storage", systemImage: "externaldrive")
                }
                actionStatus
            }

            Section(header: sectionHeader("Caches")) {
                storageRow(
                    "Web & Media Cache", detail: webCacheSize,
                    description: "HTTP responses, temporary web data and cached images."
                ) {
                    Button("Clear") { clearWebCache() }
                }
                storageRow(
                    "Story Text",
                    detail: "\(articleStore.articles.count) \(articleStore.articles.count == 1 ? "story" : "stories")",
                    description: "Cached full story text. Subscriptions and saved stories are kept."
                ) {
                    Button("Clear…") { pendingClear = .stories }
                }
                storageRow(
                    "AI Analysis Data",
                    detail: "\(articleStore.articles.filter { $0.aiSummary != nil }.count) analysed",
                    description:
                        "Summaries, key points, entities, event overviews and story embeddings. Subscriptions and stories remain."
                ) {
                    Button("Clear…") { pendingClear = .analysis }
                }
                storageRow(
                    "Library Database", detail: databaseSize,
                    description: "Subscriptions, read history, saved stories and the search index."
                ) {
                    TagView(
                        title: articleStore.databaseHealthNotice == nil ? "Active" : "Read-Only",
                        tint: articleStore.databaseHealthNotice == nil ? AppColor.secondaryText : AppColor.warning
                    )
                }
                if let healthNotice = articleStore.databaseHealthNotice {
                    NoticeView(tint: AppColor.warning) {
                        Label {
                            Text(healthNotice)
                                .font(AppTypography.callout)
                                .foregroundStyle(AppColor.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(AppColor.warning)
                        }
                    }
                }
            }

            Section(header: sectionHeader("Backup")) {
                storageRow(
                    "Back Up Library", detail: nil,
                    description: "Saves stories, read history, saved stories and settings to one file you choose."
                ) {
                    Button("Back Up Library…") { LibraryBackup.backUpLibrary() }
                }
                storageRow(
                    "Restore Library", detail: nil,
                    description:
                        "Replaces the library with a backup, and settings if the backup includes them, then relaunches. The current library is kept beside it."
                ) {
                    Button("Restore Library…") { LibraryBackup.restoreLibrary() }
                }
            }

            Section(header: sectionHeader("Retention")) {
                retentionRow
            }

            Section {
                storageRow(
                    "Clear All Caches", detail: nil,
                    description:
                        "Removes the web cache, story text and AI analysis. Subscriptions, saved stories and read history are kept."
                ) {
                    Button("Clear All…", role: .destructive) { pendingClear = .all }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: Self.paneWidth)
        .confirmationDialog(
            pendingClear?.question ?? "",
            isPresented: Binding(get: { pendingClear != nil }, set: { if !$0 { pendingClear = nil } }),
            presenting: pendingClear
        ) { target in
            Button(target.action, role: .destructive) {
                switch target {
                case .stories: clearArticleData()
                case .analysis: clearAIData()
                case .all: clearEverythingData()
                }
            }
        } message: { target in
            Text(target.consequence)
        }
    }

    /// One storage row: title and size, a caption, and the action on the trailing edge.
    private func storageRow<Action: View>(
        _ title: String, detail: String?, description: String, @ViewBuilder action: () -> Action
    ) -> some View {
        LabeledContent {
            action().controlSize(.small)
        } label: {
            HStack(spacing: AppSpacing.eyebrowGap) {
                Text(title)
                if let detail {
                    Text(detail).font(AppTypography.label.monospacedDigit()).foregroundStyle(AppColor.secondaryText)
                }
            }
            Text(description).font(AppTypography.caption).foregroundStyle(AppColor.secondaryText)
        }
    }

    /// Retention: read, unsaved stories older than the chosen age are deleted once a day after a refresh.
    private var retentionRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: AppSpacing.textStack) {
                Text("Delete Read Stories")
                    .font(AppTypography.sectionTitle)
                    .foregroundStyle(AppColor.primaryText)
                Text("Saved stories, unread stories and sources cited by an event overview are kept.")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColor.secondaryText)
            }
            Spacer()
            Picker(
                "Delete read stories after",
                selection: Binding(
                    get: { appSettings.articleRetentionDays },
                    set: { appSettings.setArticleRetentionDays($0) }
                )
            ) {
                Text("Never").tag(0)
                Text("After 30 days").tag(30)
                Text("After 90 days").tag(90)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
        }
    }

    /// The latest action result in Subscriptions and Storage: status colour marks the symbol only, the text stays a
    /// label colour (DESIGN.md 11).
    @ViewBuilder
    private var actionStatus: some View {
        if let message = cacheActionMessage {
            Label {
                Text(message).foregroundStyle(AppColor.primaryText)
            } icon: {
                Image(systemName: cacheActionFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(cacheActionFailed ? AppColor.danger : AppColor.success)
            }
            .font(AppTypography.label)
            .padding(.horizontal, AppSpacing.xs)
            .padding(.vertical, AppSpacing.xxs)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous).fill(
                    AppColor.badgeBackground)
            )
            .transition(.opacity)
        }
    }

    // MARK: - 8. Updates Tab

    @ViewBuilder
    private var updateNoticeBanner: some View {
        NoticeView(tint: AppColor.accent) {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .foregroundStyle(AppColor.accentText)
                    .imageScale(.large)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: AppSpacing.textStack) {
                    Text("Update Available")
                        .font(AppTypography.headline)
                        .foregroundStyle(AppColor.primaryText)

                    if let latest = updateChecker.latestVersionString {
                        let formatted = latest.hasPrefix("v") || latest.hasPrefix("V") ? latest : "v\(latest)"
                        Text("Version \(formatted) is available on GitHub.")
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColor.secondaryText)
                    } else {
                        Text("A new version of News is available on GitHub.")
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColor.secondaryText)
                    }
                }

                Spacer()

                Button("View Release on GitHub") {
                    updateChecker.openReleasePage()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private var updatesTab: some View {
        Form {
            Section(header: sectionHeader("News for macOS")) {
                LabeledContent("Installed Version", value: updateChecker.currentAppVersion)
                LabeledContent("Release Channel", value: "GitHub Releases")
                if let checked = updateChecker.lastCheckDate {
                    LabeledContent("Last Checked", value: checked.formatted(date: .abbreviated, time: .shortened))
                }
            }
            Section {
                if updateChecker.updateAvailable {
                    updateNoticeBanner
                }

                if let status = updateChecker.statusMessage {
                    Text(status)
                        .font(AppTypography.callout)
                        .foregroundStyle(AppColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                HStack {
                    if updateChecker.isChecking {
                        ProgressView().controlSize(.small)
                        Text("Checking for updates…")
                    } else {
                        Button("Check for Updates") {
                            Task { await updateChecker.checkForUpdates(userInitiated: true) }
                        }
                    }
                }
            } header: {
                Text("Software Updates")
            } footer: {
                Text(
                    "Checks published releases. Opening a release shows its download page; News never replaces itself automatically."
                )
            }
        }
        .formStyle(.grouped)
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
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return 0
        }
        let dbDir = appSupport.appendingPathComponent("com.marspater.news", isDirectory: true)
        let files = ["news.sqlite3", "news.sqlite3-wal", "news.sqlite3-shm"]
        var total: Int64 = 0
        for file in files {
            let path = dbDir.appendingPathComponent(file).path
            if let attrs = try? fileManager.attributesOfItem(atPath: path),
                let size = attrs[.size] as? Int64
            {
                total += size
            }
        }
        return total
    }

    private nonisolated static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func clearWebCache() {
        CacheManager.shared.clearWebCache()
        DecodedImageCache.clear()
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
                showActionMessage("Cache cleanup failed: \(error.localizedDescription)", failed: true)
            }
        }
    }

    private func clearArticleData() {
        Task {
            do {
                try await articleStore.clearArticleCache()
                calculateStorageSizes()
                showActionMessage("Story body cache cleared.")
            } catch {
                showActionMessage("Cache cleanup failed: \(error.localizedDescription)", failed: true)
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
                showActionMessage("Cache cleanup failed: \(error.localizedDescription)", failed: true)
            }
        }
    }

    private func subscribeFromField() {
        let trimmed = newFeedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if feedManager.addFeed(url: trimmed) {
            newFeedURL = ""
        } else {
            showActionMessage(AppSettings.addFeedFailureMessage(for: trimmed), failed: true)
        }
    }

    private func showActionMessage(_ msg: String, failed: Bool = false) {
        withAnimation(reduceMotion ? nil : AppMotion.state) {
            cacheActionFailed = failed
            cacheActionMessage = msg
        }
        // The same five seconds as the masthead notice.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            withAnimation(reduceMotion ? nil : AppMotion.state) {
                if cacheActionMessage == msg {
                    cacheActionMessage = nil
                }
            }
        }
    }
}

/// Storage clean-ups that remove stored work the reader would have to wait for again.
private enum StorageClear: Identifiable {
    case stories, analysis, all

    var id: Self { self }

    var question: String {
        switch self {
        case .stories: return "Clear cached story text?"
        case .analysis: return "Clear AI analysis data?"
        case .all: return "Clear all caches?"
        }
    }

    var action: String {
        switch self {
        case .stories: return "Clear Story Text"
        case .analysis: return "Clear Analysis"
        case .all: return "Clear All"
        }
    }

    var consequence: String {
        switch self {
        case .stories: return "Stories download their text again when opened. Subscriptions and saved stories are kept."
        case .analysis:
            return
                "Summaries, key points, entities, event overviews and story embeddings are generated again on request."
        case .all:
            return
                "Web cache, story text and AI analysis are removed. Subscriptions, saved stories and read history are kept."
        }
    }
}
