// Copyright 2026 NewsApp Contributors
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

/// Modal sheet for creating and editing user-defined Smart Binders (DESIGN.md §4, §8.6).
struct SmartBinderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appSettings: AppSettings

    /// If editing an existing binder, this is provided; nil indicates creation mode.
    var binder: SmartBinder?

    @State private var name: String = ""
    @State private var selectedIcon: String = "folder"
    @State private var selectedCategories: Set<String> = []
    @State private var includeKeywordsText: String = ""
    @State private var matchAllKeywords: Bool = false
    @State private var excludeKeywordsText: String = ""
    @State private var publishersText: String = ""

    private static let availableIcons = [
        "folder", "tag", "bookmark", "tray", "cube", "flame",
        "newspaper", "cpu", "globe", "bolt", "briefcase", "archivebox",
    ]

    private static let standardCategories = [
        "Tech", "Business", "Science", "Entertainment",
        "Politics", "U.S. Politics", "World", "Lifestyle",
        "Sports", "Health & Wellness", "Food", "Travel", "Fashion",
    ]

    init(binder: SmartBinder? = nil) {
        self.binder = binder
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    identityGroup
                    categoriesGroup
                    keywordsGroup
                    publishersGroup
                }
                .padding(AppLayout.pageInset)
            }

            Divider()
            footer
        }
        .frame(width: AppLayout.smartBinderSheetWidth, height: AppLayout.smartBinderSheetHeight)
        .onAppear(perform: populateFromBinder)
    }

    // MARK: - Header & Footer

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            Text(binder == nil ? "New Smart Binder" : "Edit Smart Binder")
                .font(AppTypography.title)
                .foregroundStyle(AppColor.primaryText)
                .accessibilityAddTraits(.isHeader)

            Text("Compound topic rules are evaluated dynamically without duplicating stories.")
                .font(AppTypography.callout)
                .foregroundStyle(AppColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppLayout.pageInset)
        .padding(.vertical, AppSpacing.md)
    }

    private var footer: some View {
        HStack {
            Button("Cancel", role: .cancel) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button("Save") {
                saveBinder()
            }
            .buttonStyle(.borderedProminent)
            .disabled(trimmedName.isEmpty)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, AppLayout.pageInset)
        .padding(.vertical, AppSpacing.sm)
    }

    // MARK: - Groups (DESIGN.md §8.6)

    private var identityGroup: some View {
        group("Identity") {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                TextField("Binder Name", text: $name)
                    .textFieldStyle(.roundedBorder)

                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    Text("Icon")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColor.secondaryText)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: AppSpacing.xs) {
                            ForEach(Self.availableIcons, id: \.self) { icon in
                                Button {
                                    selectedIcon = icon
                                } label: {
                                    Image(systemName: icon)
                                        .frame(width: AppLayout.iconButtonSize, height: AppLayout.iconButtonSize)
                                        .background(selectedIcon == icon ? AppColor.passageHighlight : Color.clear)
                                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.control))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: AppRadius.control)
                                                .stroke(
                                                    selectedIcon == icon ? AppColor.accent : Color.clear,
                                                    lineWidth: AppLayout.timelineRailStroke
                                                )
                                        )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Symbol \(icon)")
                                .accessibilityAddTraits(selectedIcon == icon ? .isSelected : [])
                                .accessibilityValue(selectedIcon == icon ? "Selected" : "Unselected")
                            }
                        }
                        .padding(.vertical, AppSpacing.xxs)
                    }
                }
            }
        }
    }

    private var categoriesGroup: some View {
        group("Categories") {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("Stories matching any of the selected categories will be included.")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColor.secondaryText)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: AppSpacing.xs)], spacing: AppSpacing.xs)
                {
                    ForEach(Self.standardCategories, id: \.self) { cat in
                        let isSelected = selectedCategories.contains(cat)
                        Button {
                            if isSelected {
                                selectedCategories.remove(cat)
                            } else {
                                selectedCategories.insert(cat)
                            }
                        } label: {
                            HStack(spacing: AppSpacing.xxs) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isSelected ? AppColor.accent : AppColor.secondaryText)
                                Text(cat)
                                    .font(AppTypography.label)
                                    .foregroundStyle(AppColor.primaryText)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, AppSpacing.xs)
                            .padding(.vertical, AppSpacing.xxs)
                            .background(isSelected ? AppColor.passageHighlight : AppColor.badgeBackground)
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.control))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .accessibilityValue(isSelected ? "Selected" : "Unselected")
                    }
                }
            }
        }
    }

    private var keywordsGroup: some View {
        group("Keywords") {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    Text("Include Keywords")
                        .font(AppTypography.headline)
                    TextField("e.g. apple, silicon, m4", text: $includeKeywordsText)
                        .textFieldStyle(.roundedBorder)
                    Picker("Keyword Matching", selection: $matchAllKeywords) {
                        Text("Any Keyword").tag(false)
                        Text("All Keywords").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text("Separate multiple keywords with commas.")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColor.secondaryText)
                }

                Divider()

                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    Text("Exclude Keywords")
                        .font(AppTypography.headline)
                    TextField("e.g. rumor, leak", text: $excludeKeywordsText)
                        .textFieldStyle(.roundedBorder)
                    Text("Stories containing these words will be omitted.")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColor.secondaryText)
                }
            }
        }
    }

    private var publishersGroup: some View {
        group("Publishers") {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                TextField("e.g. Ars Technica, BBC, The Verge", text: $publishersText)
                    .textFieldStyle(.roundedBorder)
                Text("Separate multiple publisher names with commas. Leave blank to allow any publisher.")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColor.secondaryText)
            }
        }
    }

    // MARK: - Helpers

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(title)
                .font(AppTypography.sectionTitle)
                .foregroundStyle(AppColor.primaryText)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(ContentPanel())
    }

    private func populateFromBinder() {
        guard let binder else { return }
        name = binder.name
        selectedIcon = binder.icon
        selectedCategories = Set(binder.categories)
        includeKeywordsText = binder.includeKeywords.joined(separator: ", ")
        matchAllKeywords = binder.matchAllKeywords
        excludeKeywordsText = binder.excludeKeywords.joined(separator: ", ")
        publishersText = binder.publishers.joined(separator: ", ")
    }

    private func parseCommaSeparated(_ text: String) -> [String] {
        text.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func saveBinder() {
        let includes = parseCommaSeparated(includeKeywordsText)
        let excludes = parseCommaSeparated(excludeKeywordsText)
        let pubs = parseCommaSeparated(publishersText)
        let cats = Array(selectedCategories).sorted()

        if let existing = binder {
            var updated = existing
            updated.name = trimmedName
            updated.icon = selectedIcon
            updated.categories = cats
            updated.includeKeywords = includes
            updated.excludeKeywords = excludes
            updated.publishers = pubs
            updated.matchAllKeywords = matchAllKeywords
            appSettings.updateSmartBinder(updated)
        } else {
            let newBinder = SmartBinder(
                name: trimmedName,
                icon: selectedIcon,
                categories: cats,
                includeKeywords: includes,
                excludeKeywords: excludes,
                publishers: pubs,
                matchAllKeywords: matchAllKeywords
            )
            appSettings.addSmartBinder(newBinder)
        }
        dismiss()
    }
}
