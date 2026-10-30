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

/// The first-launch sheet (#562): feeds from the catalog, sidebar sections and what on-device analysis does. It shows
/// once; settings from an earlier version count as onboarded (`AppSettings.firstLaunchCompleted`).
struct OnboardingView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @EnvironmentObject private var feedManager: FeedManager
    @Environment(\.dismiss) private var dismiss
    @State private var showsCatalog = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text("Welcome to News")
                    .font(AppTypography.title)
                    .foregroundStyle(AppColor.primaryText)
                    .accessibilityAddTraits(.isHeader)
                Text("Choose what to read. You can change all of this later in Settings.")
                    .font(AppTypography.callout)
                    .foregroundStyle(AppColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppLayout.pageInset)
            .padding(.top, AppLayout.pageInset)
            .padding(.bottom, AppSpacing.xs)

            Form {
                Section("Feeds") {
                    LabeledContent("Subscribed Feeds", value: "\(appSettings.feedURLs.count)")
                    Button("Browse Feed Catalog…") { showsCatalog = true }
                    Text("Add publications by topic.")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColor.secondaryText)
                }
                Section("Sections") {
                    ForEach(NewsCategory.allCases, id: \.self) { category in
                        Toggle(category.rawValue, isOn: sectionBinding(category))
                    }
                    Text("Choose the categories shown in the sidebar.")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColor.secondaryText)
                }
                Section("On-Device Intelligence") {
                    Toggle(
                        "Enable AI Story Analysis",
                        isOn: Binding(get: { appSettings.aiEnabled }, set: { appSettings.setAIEnabled($0) }))
                    Text(
                        "Summaries, key points, entities and tone for each story, generated on this Mac with Apple's models. Story text is not sent anywhere."
                    )
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Section("Notifications") {
                    Text("Once the first stories arrive, News asks whether it may notify you about major news.")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: AppLayout.catalogSheetWidth)
        .frame(minHeight: AppLayout.catalogSheetMinHeight)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Start Reading") {
                    appSettings.completeFirstLaunch()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .sheet(isPresented: $showsCatalog) {
            FeedCatalogView()
        }
    }

    /// The same rule as Settings › General: a category is on while any section maps to it.
    private func sectionBinding(_ category: NewsCategory) -> Binding<Bool> {
        Binding(
            get: { feedManager.userSections.contains { SettingsView.predefinedCategory(for: $0) == category } },
            set: { enabled in
                if enabled {
                    feedManager.addSection(category.rawValue)
                } else {
                    let matching = feedManager.userSections.filter {
                        SettingsView.predefinedCategory(for: $0) == category
                    }
                    for section in matching { feedManager.removeSection(section) }
                }
            })
    }
}
