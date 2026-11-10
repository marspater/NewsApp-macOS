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

import Foundation
import SwiftUI

/// The top stories of the edition, one at a time over their best image (DESIGN.md 8.4). The app's only auto-advancing
/// motion: every 10 s a slow cross-fade, paused on hover, keyboard focus and while a story or sheet is open, and never
/// under Reduce Motion, where the first story stays. Arrows and dots always work.
struct BriefingHeroCarouselView: View {
    let entries: [FeedEntry]
    /// The best image across each event's reports, by entry ID; the story's own image otherwise.
    var images: [String: URL] = [:]
    var readIDs: Set<String> = []
    let clock: any CarouselClock
    var isReaderOpen: Bool = false
    let onOpen: (FeedEntry) -> Void

    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @Environment(\.effectiveContrast) private var contrast
    @State private var activeIndex: Int = 0
    @State private var isHovered: Bool = false
    @FocusState private var isCarouselFocused: Bool
    @State private var timerResetToken: Int = 0

    static let autoAdvanceInterval: Double = 10.0
    private static let crossFade = Animation.easeInOut(duration: 0.6)

    private var shouldTimerRun: Bool {
        !reduceMotion && !isHovered && !isCarouselFocused && !isReaderOpen && entries.count > 1
    }

    private var timerReloadKey: String {
        "\(shouldTimerRun)-\(timerResetToken)-\(entries.map(\.id))"
    }

    private var currentIndex: Int { max(0, min(activeIndex, entries.count - 1)) }

    var body: some View {
        ZStack {
            if entries.indices.contains(currentIndex) {
                slide(entries[currentIndex])
                    .id(entries[currentIndex].id)
                    .transition(.opacity)
            }
            if entries.count > 1 { controls }
        }
        .frame(height: AppLayout.leadStoryHeight)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .fill(AppColor.leadPlaceholder)
                .shadow(
                    color: isCarouselFocused ? AppShadow.cardFocusRingColor : AppShadow.cardRestingColor,
                    radius: isCarouselFocused ? AppShadow.cardFocusRingRadius : AppShadow.cardRestingRadius, x: 0,
                    y: isCarouselFocused ? AppShadow.cardFocusRingY : AppShadow.cardRestingY
                )
        }
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .strokeBorder(
                    isCarouselFocused ? AppColor.accent : AppColor.border(for: contrast),
                    lineWidth: isCarouselFocused ? AppLayout.focusStroke : AppLayout.hairline)
        )
        .onHover { isHovered = $0 }
        // Focusable, so keyboard focus pauses the rotation and the arrow keys move between stories.
        .focusable()
        .focused($isCarouselFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) {
            step(-1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            step(1)
            return .handled
        }
        .onKeyPress(.return) {
            open()
            return .handled
        }
        .onKeyPress(.space) {
            open()
            return .handled
        }
        .onChange(of: reduceMotion) { _, newValue in
            if newValue { activeIndex = 0 }
        }
        .onChange(of: entries.map(\.id)) { _, _ in activeIndex = 0 }
        .task(id: timerReloadKey) {
            guard shouldTimerRun else { return }
            while !Task.isCancelled {
                do {
                    try await clock.sleep(seconds: Self.autoAdvanceInterval)
                    guard !Task.isCancelled, shouldTimerRun else { break }
                    withAnimation(Self.crossFade) {
                        activeIndex = (currentIndex + 1) % max(1, entries.count)
                    }
                } catch {
                    break
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Top stories")
    }

    /// A manual move: instant under Reduce Motion, and the countdown starts again.
    private func step(_ offset: Int) {
        guard entries.count > 1 else { return }
        withAnimation(reduceMotion ? nil : Self.crossFade) {
            activeIndex = (currentIndex + offset + entries.count) % entries.count
        }
        timerResetToken += 1
    }

    private func open() {
        guard entries.indices.contains(currentIndex) else { return }
        onOpen(entries[currentIndex])
    }

    /// One story: its image, the scrim and the caption, a single click target (DESIGN.md 8.2).
    private func slide(_ entry: FeedEntry) -> some View {
        let story = entry.representative
        let isRead = readIDs.contains(story.id)
        return Button {
            onOpen(entry)
        } label: {
            ZStack(alignment: .bottomLeading) {
                image(for: entry)
                AppColor.leadScrimFade
                caption(story, publishers: entry.publisherCount, isRead: isRead)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(story.title), from \(story.publisherName), \(story.cardDateText())"
                + (entry.publisherCount > 1 ? ", \(entry.publisherCount) publishers" : "")
                + (isRead ? ". Read" : ". Unread")
        )
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func image(for entry: FeedEntry) -> some View {
        if let url = images[entry.id] ?? FeedArticle.bestCardImage(in: entry.visibleArticles) {
            ArticleRemoteImage(url: url) { phase in
                if let image = phase.image {
                    LeadImageFill(image: image, aspectRatio: DecodedImageCache.aspectRatio(for: url))
                } else {
                    AppColor.leadPlaceholder
                }
            }
            .accessibilityHidden(true)
        } else {
            AppColor.leadPlaceholder
        }
    }

    private func caption(_ story: FeedArticle, publishers: Int, isRead: Bool) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack(spacing: AppSpacing.eyebrowGap) {
                EyebrowText(story.publisherName, color: AppColor.leadSecondaryText)
                Text("·").font(AppTypography.caption).foregroundStyle(AppColor.leadSecondaryText)
                Text(story.cardDateText()).font(AppTypography.caption).monospacedDigit()
                    .foregroundStyle(AppColor.leadSecondaryText)
                if !isRead { UnreadDot() }
            }
            Text(story.title)
                .font(AppTypography.leadStoryHeadline)
                .foregroundStyle(isRead ? AppColor.leadSecondaryText : AppColor.leadText)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if publishers > 1 {
                TagView(
                    title: "\(publishers) publishers", systemImage: "square.stack.3d.up", tint: AppColor.leadText,
                    foreground: AppColor.leadText)
            }
        }
        .padding(.horizontal, AppSpacing.lg + AppLayout.carouselControlSize)
        .padding(.top, AppSpacing.lg)
        // Room for the dots below the caption.
        .padding(.bottom, AppSpacing.lg + (entries.count > 1 ? AppLayout.carouselDotSize : 0))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Previous and next arrows at the edges and the page dots at the foot; each is its own click target.
    private var controls: some View {
        ZStack {
            HStack {
                arrow("chevron.left", label: "Previous story") { step(-1) }
                Spacer()
                arrow("chevron.right", label: "Next story") { step(1) }
            }
            .padding(.horizontal, AppSpacing.md)
            VStack {
                Spacer()
                HStack(spacing: AppSpacing.xs) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        dot(index, entry)
                    }
                }
                .padding(.bottom, AppSpacing.md)
            }
        }
    }

    private func arrow(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(AppTypography.headline)
                .foregroundStyle(AppColor.leadText)
                .frame(width: AppLayout.carouselControlSize, height: AppLayout.carouselControlSize)
                .background(AppColor.carouselControl, in: Circle())
                .frame(width: AppLayout.minimumHitTarget, height: AppLayout.minimumHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func dot(_ index: Int, _ entry: FeedEntry) -> some View {
        let active = index == currentIndex
        return Button {
            guard index != currentIndex else { return }
            withAnimation(reduceMotion ? nil : Self.crossFade) { activeIndex = index }
            timerResetToken += 1
        } label: {
            Capsule()
                .fill(active ? AppColor.leadText : AppColor.carouselInactiveDot)
                .frame(
                    width: active ? AppLayout.carouselActiveDotWidth : AppLayout.carouselDotSize,
                    height: AppLayout.carouselDotSize
                )
                .padding(AppSpacing.xxs)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Story \(index + 1) of \(entries.count): \(entry.representative.title)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
