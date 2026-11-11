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

/// How the hero carousel draws Today's Lead (docs/design/today.md, #935): full-bleed, sized by the window, with the
/// card metadata of #1174. Rotation, pauses and Reduce Motion are the carousel's own (DESIGN.md 13.1).
struct LeadPresentation: Equatable {
    /// `AppLayout.leadHeight(windowHeight:)`.
    var height: CGFloat
    /// The window's width, which scales the headline.
    var windowWidth: CGFloat
    /// Metadata by story id; a story without any shows its publisher, headline, summary and time only.
    var metadata: [String: StoryCardMetadata] = [:]
    /// Stories whose event gained a report in the last hour.
    var developingIDs: Set<String> = []
    /// The slide holding keyboard focus in the Today list; the carousel shows it and holds still.
    var focusedID: String?
}

extension BriefingHeroCarouselView {
    /// The magazine-cover slide: the image edge to edge, fading into the page, with the text layered on it and no
    /// panel behind it.
    func leadSlide(_ entry: FeedEntry, lead: LeadPresentation, isRead: Bool) -> some View {
        let story = entry.representative
        let metadata = lead.metadata[entry.id] ?? StoryCardMetadata()
        return ZStack(alignment: .topLeading) {
            leadImage(for: entry)
            AppColor.leadTextScrim
            AppColor.leadFootScrim
            AppColor.leadPageFade
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                leadTopLine(entry, lead: lead, metadata: metadata, isRead: isRead)
                Spacer(minLength: 0)
                Text(story.title)
                    .font(AppTypography.leadHeadline(windowWidth: lead.windowWidth))
                    .foregroundStyle(isRead ? AppColor.leadSecondaryText : AppColor.leadText)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .layoutPriority(1)
                let dek = CardText.cleaned(story.description)
                if !dek.isEmpty {
                    Text(dek)
                        .font(AppTypography.lede)
                        .foregroundStyle(AppColor.leadSecondaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                leadFoot(story, metadata: metadata)
            }
            .frame(maxWidth: AppLayout.leadTextMaxWidth, alignment: .leading)
            .padding(.horizontal, AppLayout.pageInset)
            .padding(.top, AppSpacing.md)
            // Clear of the fade into the page along the image's lower edge.
            .padding(.bottom, AppSpacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
    }

    /// The image carries under the floating sidebar on macOS 26 and later; macOS 15 shows it at the column's width.
    @ViewBuilder
    private func leadImage(for entry: FeedEntry) -> some View {
        if #available(macOS 26, *) {
            image(for: entry).backgroundExtensionEffect()
        } else {
            image(for: entry)
        }
    }

    /// The breathing dot while unread, "PUBLISHER · 1 OF N", the status pill and the reading time.
    private func leadTopLine(_ entry: FeedEntry, lead: LeadPresentation, metadata: StoryCardMetadata, isRead: Bool)
        -> some View
    {
        HStack(spacing: AppSpacing.xs) {
            if !isRead { BreathingDot() }
            EyebrowText(
                entries.count > 1
                    ? "\(entry.representative.publisherName) · \(currentIndex + 1) of \(entries.count)"
                    : entry.representative.publisherName,
                color: AppColor.leadText
            )
            .monospacedDigit()
            if lead.developingIDs.contains(entry.id) {
                HStack(spacing: AppSpacing.xxs) {
                    Circle().fill(AppColor.leadStatus)
                        .frame(width: AppLayout.unreadDotSize, height: AppLayout.unreadDotSize)
                    Text("Developing")
                }
                .font(AppTypography.eyebrow)
                .foregroundStyle(AppColor.leadStatus)
                .padding(.horizontal, AppSpacing.xs)
                .padding(.vertical, AppSpacing.xxs)
                .background(AppColor.leadStatusFill, in: Capsule())
                .overlay { Capsule().strokeBorder(AppColor.leadStatus, lineWidth: AppLayout.hairline) }
            }
            if let time = metadata.readingTimeText {
                Text(time)
                    .font(AppTypography.eyebrow)
                    .monospacedDigit()
                    .foregroundStyle(AppColor.leadText)
                    .padding(.horizontal, AppSpacing.xs)
                    .padding(.vertical, AppSpacing.xxs)
                    .background(AppColor.leadPill, in: Capsule())
                    .overlay { Capsule().strokeBorder(AppColor.leadPillBorder, lineWidth: AppLayout.hairline) }
            }
        }
    }

    /// Time, publisher marks, the publisher count and the original reports in teal's dark value: the foot sits on a
    /// dark image in both appearances.
    private func leadFoot(_ story: FeedArticle, metadata: StoryCardMetadata) -> some View {
        HStack(spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.xxs) {
                Image(systemName: "clock").accessibilityHidden(true)
                if let updatedAt = metadata.updatedAt, (metadata.publisherCount ?? 1) > 1 {
                    TimelineView(.everyMinute) { context in
                        Text(
                            "Updated "
                                + FeedArticle.relativeUpdateText(for: updatedAt, now: context.date, abbreviated: true))
                    }
                } else {
                    CardDateText(article: story)
                }
            }
            .foregroundStyle(AppColor.leadSecondaryText)
            if let count = metadata.publisherCount, count > 1 {
                HStack(spacing: AppSpacing.xxs) {
                    PublisherMonograms(
                        publishers: metadata.publishers, ring: AppColor.leadPlaceholder, tinted: false)
                    Text("\(count) publishers").foregroundStyle(AppColor.leadText)
                }
            }
            if let original = metadata.originalReportsText {
                Label(original, systemImage: "checkmark.seal")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(AppColor.originalReportsOnImage)
            }
        }
        .font(AppTypography.caption)
        .monospacedDigit()
        .lineLimit(1)
    }

    /// Page dots and the previous and next arrows at the trailing foot, on glass, always visible.
    var leadControls: some View {
        FloatingGlassGroup {
            HStack(spacing: AppSpacing.xxs) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in dot(index, entry) }
            }
            .padding(.horizontal, AppSpacing.xs)
            .frame(height: AppLayout.carouselControlSize)
            .modifier(PhotoControlSurface(shape: Capsule()))
            leadArrow("chevron.left", label: "Previous story") { step(-1) }
            leadArrow("chevron.right", label: "Next story") { step(1) }
        }
        .padding(.trailing, AppLayout.pageInset)
        .padding(.bottom, AppSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    private func leadArrow(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(AppTypography.headline)
                .foregroundStyle(AppColor.leadText)
                .frame(width: AppLayout.carouselControlSize, height: AppLayout.carouselControlSize)
                .modifier(PhotoControlSurface(shape: Circle()))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    func leadAccessibilityLabel(_ entry: FeedEntry, lead: LeadPresentation, isRead: Bool) -> String {
        let story = entry.representative
        let metadata = lead.metadata[entry.id] ?? StoryCardMetadata()
        var parts = ["\(story.title), from \(story.publisherName), \(story.cardDateText())"]
        if entries.count > 1 { parts.append("\(currentIndex + 1) of \(entries.count)") }
        if lead.developingIDs.contains(entry.id) { parts.append("Developing") }
        if let time = metadata.readingTimeText { parts.append(time) }
        if let count = metadata.publisherCount, count > 1 { parts.append("\(count) publishers") }
        if let original = metadata.originalReportsText { parts.append(original) }
        return parts.joined(separator: ", ") + (isRead ? ". Read" : ". Unread")
    }
}

/// The Lead's unread mark: the accent dot, breathing on a 2.6 s cycle and still under Reduce Motion.
struct BreathingDot: View {
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @State private var isDimmed = false

    var body: some View {
        Circle()
            .fill(AppColor.unreadDot)
            .frame(width: AppLayout.breathingDotSize, height: AppLayout.breathingDotSize)
            .opacity(isDimmed ? AppMotion.breatheDimmed : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(AppMotion.breathe) { isDimmed = true }
            }
            .onChange(of: reduceMotion) { _, reduced in
                withAnimation(reduced ? nil : AppMotion.breathe) { isDimmed = !reduced }
            }
            .accessibilityLabel("Unread")
    }
}
