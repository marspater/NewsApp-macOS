// Copyright 2026 Mars Pater
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import SwiftUI

/// The first-launch flow (#562): one step per screen (`OnboardingStep`), with Back and Continue. It shows once;
/// settings from an earlier version count as onboarded (`AppSettings.firstLaunchCompleted`), and the presenter marks
/// it complete when the sheet closes.
struct OnboardingView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @EnvironmentObject private var feedManager: FeedManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @Environment(\.effectiveContrast) private var contrast
    @State private var step: OnboardingStep
    /// Which way the last move went, so the outgoing step leaves on the side it came from.
    @State private var movingForward = true
    @State private var topic: CatalogSet = CatalogSet.offered.first ?? .world
    @State private var showsCatalog = false
    @Namespace private var indicator

    init(step: OnboardingStep = .welcome) {
        _step = State(initialValue: step)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                stepPage(step)
                    .id(step)
                    .transition(pageTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            Divider()
            footer
        }
        // One fixed size for every step (the tall sheet size the tension sheet uses), so the sheet never resizes
        // while a step slides in.
        .frame(width: AppLayout.catalogSheetWidth, height: AppLayout.tensionSheetHeight)
        .background(AppColor.background)
        // Escape steps back; on the first step it closes the flow, which counts as completing it.
        .onExitCommand { if let previous = step.previous { move(to: previous) } else { dismiss() } }
        .sheet(isPresented: $showsCatalog) {
            FeedCatalogView()
        }
    }

    // MARK: - Navigation

    /// The page slides in the direction of travel with the navigation spring; with Reduce Motion it is replaced
    /// without animation (DESIGN.md 13).
    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        let edge: Edge = movingForward ? .trailing : .leading
        return .asymmetric(
            insertion: .move(edge: edge).combined(with: .opacity),
            removal: .move(edge: edge == .trailing ? .leading : .trailing).combined(with: .opacity))
    }

    private func move(to target: OnboardingStep) {
        movingForward = target.rawValue > step.rawValue
        withAnimation(reduceMotion ? nil : AppMotion.navigation) { step = target }
    }

    private var footer: some View {
        HStack(spacing: AppSpacing.sm) {
            Button("Back") { step.previous.map { move(to: $0) } }
                .disabled(step.previous == nil)
                .opacity(step.previous == nil ? 0 : 1)
                .accessibilityHidden(step.previous == nil)
            Spacer()
            pageIndicator
            Spacer()
            Button(step.continueTitle) {
                if let next = step.next { move(to: next) } else { dismiss() }
            }
            .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
        .padding(.horizontal, AppLayout.pageInset)
        .padding(.vertical, AppSpacing.md)
    }

    /// One dot per step; the accent dot glides to the current one. VoiceOver reads it as "Step 2 of 6".
    private var pageIndicator: some View {
        HStack(spacing: AppSpacing.xs) {
            ForEach(OnboardingStep.allCases, id: \.self) { item in
                Image(systemName: "circle.fill")
                    .font(AppTypography.eyebrow)
                    .foregroundStyle(AppColor.quaternaryLabel)
                    .overlay {
                        if item == step {
                            Image(systemName: "circle.fill")
                                .font(AppTypography.eyebrow)
                                .foregroundStyle(AppColor.accent)
                                .matchedGeometryEffect(id: "current", in: indicator)
                        }
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(step.position)
    }

    // MARK: - Steps

    private func stepPage(_ step: OnboardingStep) -> some View {
        let heading = VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(step.title)
                .font(AppTypography.title)
                .foregroundStyle(AppColor.primaryText)
                .accessibilityAddTraits(.isHeader)
            Text(summary(step))
                .font(AppTypography.lede)
                .foregroundStyle(AppColor.secondaryText(for: contrast))
                .fixedSize(horizontal: false, vertical: true)
        }
        return VStack(alignment: .leading, spacing: AppSpacing.lg) {
            // Steps with many choices put the art beside the heading, so every choice fits without scrolling.
            if OnboardingArt.isCompact(step) {
                HStack(spacing: AppSpacing.lg) {
                    OnboardingArt(step: step)
                    heading
                }
            } else {
                OnboardingArt(step: step)
                    .frame(maxWidth: .infinity)
                heading
            }
            stepContent(step)
            Spacer(minLength: 0)
            OnboardingTip(text: step.tip)
        }
        .padding(AppLayout.pageInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(step.position): \(step.title)")
    }

    private func summary(_ step: OnboardingStep) -> String {
        switch step {
        case .welcome:
            return
                "Good to have you here. News gathers stories from the publications you choose and groups each event into one story. Setting up takes a minute."
        case .feeds:
            return "Pick a topic, then turn on the publications you want. You follow \(feedCountText) now."
        case .sections:
            return "Choose the categories shown in the sidebar."
        case .intelligence:
            return
                "Summaries, key points, entities and tone for each story, generated on this Mac with Apple's models. Story text is not sent anywhere."
        case .notifications:
            return
                "Once the first stories arrive, News asks whether it may notify you about major news. You can change this in Settings at any time."
        case .done:
            return "You can change all of this later in Settings."
        }
    }

    @ViewBuilder private func stepContent(_ step: OnboardingStep) -> some View {
        switch step {
        case .welcome, .notifications:
            EmptyView()
        case .feeds:
            feedsStep
        case .sections:
            chipGrid(NewsCategory.allCases.map { $0 }) { category in
                OnboardingChip(
                    title: category.rawValue,
                    isOn: SettingsView.sectionBinding(category, feedManager: feedManager))
            }
        case .intelligence:
            Toggle(isOn: Binding(get: { appSettings.aiEnabled }, set: { appSettings.setAIEnabled($0) })) {
                HStack {
                    Text("Enable AI Story Analysis").font(AppTypography.headline)
                    Spacer(minLength: AppSpacing.sm)
                }
            }
            .toggleStyle(.switch)
            .padding(AppSpacing.sm)
            .background(AppColor.badgeBackground, in: RoundedRectangle(cornerRadius: AppRadius.card))
        case .done:
            doneSummary
        }
    }

    private var feedCountText: String {
        let count = appSettings.feedURLs.count
        return count == 1 ? "1 feed" : "\(count) feeds"
    }

    private var feedsStep: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            chipGrid(CatalogSet.offered) { item in
                OnboardingChip(
                    title: item.title, isOn: Binding(get: { topic == item }, set: { if $0 { topic = item } }),
                    selectsOne: true)
            }
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                ForEach(FeedCatalog.feeds(in: topic).prefix(3)) { feed in
                    if feed.id != FeedCatalog.feeds(in: topic).first?.id { Divider() }
                    Toggle(isOn: subscription(feed)) {
                        HStack {
                            VStack(alignment: .leading, spacing: AppSpacing.textStack) {
                                Text(feed.title).font(AppTypography.body)
                                Text(feed.publisher)
                                    .font(AppTypography.caption)
                                    .foregroundStyle(AppColor.secondaryText(for: contrast))
                            }
                            Spacer(minLength: AppSpacing.sm)
                        }
                    }
                    .toggleStyle(.switch)
                }
            }
            .padding(AppSpacing.sm)
            .background(AppColor.badgeBackground, in: RoundedRectangle(cornerRadius: AppRadius.card))
            .animation(reduceMotion ? nil : AppMotion.state, value: topic)
            Button("Browse Full Catalog…") { showsCatalog = true }
        }
    }

    private func subscription(_ feed: CatalogFeed) -> Binding<Bool> {
        Binding(
            get: { appSettings.isSubscribed(feed) },
            set: { subscribe in
                if subscribe {
                    _ = feedManager.addCatalogFeeds([feed])
                } else {
                    feedManager.removeFeed(url: feed.url)
                }
            })
    }

    private var doneSummary: some View {
        let sections = feedManager.userSections.count
        return VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Label(feedCountText, systemImage: "antenna.radiowaves.left.and.right")
            Label(sections == 1 ? "1 section" : "\(sections) sections", systemImage: "square.grid.2x2")
            Label(
                appSettings.aiEnabled ? "Story analysis on this Mac" : "Story analysis off",
                systemImage: appSettings.aiEnabled ? "checkmark.circle" : "xmark.circle")
        }
        .font(AppTypography.body)
        .foregroundStyle(AppColor.primaryText)
    }

    private func chipGrid<Item: Hashable, Chip: View>(_ items: [Item], chip: @escaping (Item) -> Chip) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: AppSpacing.xs), count: 3),
            alignment: .leading, spacing: AppSpacing.xs
        ) {
            ForEach(items, id: \.self) { item in chip(item) }
        }
    }
}

/// A selectable choice in the first-launch flow. Selection shows a checkmark and an accent outline, never colour
/// alone; the change animates as confirmation of the click, and not at all with Reduce Motion.
private struct OnboardingChip: View {
    let title: String
    @Binding var isOn: Bool
    /// One of a set (a radio dot) rather than any number (a checkmark).
    var selectsOne = false
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @Environment(\.effectiveContrast) private var contrast

    private var symbol: String {
        guard isOn else { return "circle" }
        return selectsOne ? "largecircle.fill.circle" : "checkmark.circle.fill"
    }

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : AppMotion.state) { isOn.toggle() }
        } label: {
            HStack(spacing: AppSpacing.xs) {
                Image(systemName: symbol)
                    .foregroundStyle(isOn ? AppColor.accent : AppColor.secondaryText(for: contrast))
                    .contentTransition(.symbolEffect(.replace))
                Text(title)
                    .font(AppTypography.label)
                    .foregroundStyle(AppColor.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, AppSpacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isOn ? AppColor.passageHighlight : AppColor.badgeBackground,
                in: RoundedRectangle(cornerRadius: AppRadius.control)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.control)
                    .strokeBorder(isOn ? AppColor.accent : AppColor.border(for: contrast))
            )
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.control))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "Selected" : "Not selected")
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

/// Each step's art, drawn from SF Symbols and the colour tokens: the step's symbol in a soft disc, with companion
/// symbols around it. The main symbol bounces once as the step arrives, because the person moved there; with Reduce
/// Motion nothing moves. Steps with many choices get a smaller version so the choices stay in view.
private struct OnboardingArt: View {
    let step: OnboardingStep
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @State private var arrived = false

    static func isCompact(_ step: OnboardingStep) -> Bool { step == .feeds || step == .sections }
    private var compact: Bool { Self.isCompact(step) }

    private var tint: Color {
        switch step {
        case .intelligence: return AppColor.intelligence
        case .done: return AppColor.success
        default: return AppColor.accent
        }
    }

    var body: some View {
        Image(systemName: step.symbol)
            .font(compact ? AppTypography.masthead : AppTypography.tensionReading)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .symbolEffect(.bounce, value: arrived)
            .padding(compact ? AppSpacing.md : AppSpacing.xl)
            .background(Circle().fill(AppColor.badgeBackground))
            .overlay(Circle().strokeBorder(AppColor.borderSubtle))
            .padding(compact ? AppSpacing.sm : AppSpacing.lg)
            .overlay(alignment: .topLeading) { companion(0) }
            .overlay(alignment: .topTrailing) { companion(1) }
            .overlay(alignment: .bottomTrailing) { companion(2) }
            .accessibilityHidden(true)
            .onAppear { if !reduceMotion { arrived = true } }
    }

    @ViewBuilder private func companion(_ index: Int) -> some View {
        if step.companions.indices.contains(index) {
            Image(systemName: step.companions[index])
                .font(compact ? AppTypography.callout : AppTypography.sectionTitle)
                .foregroundStyle(AppColor.secondaryText)
                .padding(AppSpacing.xs)
                .background(Circle().fill(AppColor.background))
                .overlay(Circle().strokeBorder(AppColor.borderSubtle))
        }
    }
}

/// A short tip under each step, naming a real feature and where it lives.
private struct OnboardingTip: View {
    let text: String
    @Environment(\.effectiveContrast) private var contrast

    var body: some View {
        Label {
            Text(text)
                .font(AppTypography.caption)
                .foregroundStyle(AppColor.secondaryText(for: contrast))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lightbulb")
                .foregroundStyle(AppColor.accent)
        }
        .padding(AppSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.badgeBackground, in: RoundedRectangle(cornerRadius: AppRadius.card))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tip: \(text)")
    }
}
