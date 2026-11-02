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

import AppKit
import SwiftUI
import UserNotifications

/// A story notification as the app draws it while it is in front (DESIGN.md 8.7). The system banner cannot show the
/// photo edge to edge, so the notification is filed in Notification Center without a system banner and this one shows.
struct StoryBanner: Sendable, Equatable {
    var id: String
    var title: String
    var headline: String
    var body: String
    var articleID: String?
    var articleLink: String?
    var imageURL: URL?

    /// Only a story's own banner (the one carrying Save, Mark as Read and Open) is redrawn; grouped and summary banners
    /// have no photo and stay with the system.
    init?(_ request: UNNotificationRequest) {
        let content = request.content
        guard content.categoryIdentifier == NotificationActionIdentifier.category else { return nil }
        id = request.identifier
        title = content.title
        headline = content.subtitle
        body = content.body
        articleID = content.userInfo["articleID"] as? String
        articleLink = content.userInfo["articleLink"] as? String
        imageURL = (content.userInfo["imageURL"] as? String).flatMap { URL(string: $0) }
    }

    /// What the notification router reads, as a click on the system banner hands it over.
    var userInfo: [String: String] {
        var info: [String: String] = [:]
        info["articleID"] = articleID
        info["articleLink"] = articleLink
        return info
    }
}

/// App icon, publisher, headline and summary on the glass, and the story photo filling the trailing side to the
/// banner's own corners, dissolving toward the text.
struct StoryBannerView: View {
    let banner: StoryBanner
    let photo: CGImage?
    // The presenter supplies all three; an offscreen render has nothing to open, close or hold.
    var open: () -> Void = {
        // Nothing to open offscreen.
    }
    var close: () -> Void = {
        // Nothing to close offscreen.
    }
    var hover: (Bool) -> Void = { _ in
        // No dismissal to hold offscreen.
    }
    @State private var hovering = false
    @Environment(\.effectiveReduceMotion) private var reduceMotion

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous) }

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable()
                .frame(width: AppLayout.bannerIconSize, height: AppLayout.bannerIconSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(banner.title).foregroundStyle(AppColor.secondaryText)
                Text(banner.headline)
                if !banner.body.isEmpty {
                    Text(banner.body).font(.body).lineLimit(3)
                }
            }
            .font(.headline)
            .foregroundStyle(AppColor.primaryText)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, AppSpacing.md)
        .padding(.trailing, AppLayout.bannerTextTrailingInset)
        .padding(.vertical, AppSpacing.sm)
        .frame(width: AppLayout.bannerWidth)
        .background(alignment: .trailing) {
            if let photo {
                Color.clear
                    .frame(width: AppLayout.bannerPhotoWidth)
                    .overlay { Image(decorative: photo, scale: 1).resizable().scaledToFill() }
                    .clipped()
            }
        }
        .clipShape(shape)
        .modifier(BannerSurface(shape: shape))
        .overlay(alignment: .topLeading) {
            if hovering {
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(AppColor.secondaryText)
                }
                .buttonStyle(.plain)
                .padding(AppSpacing.xs)
                .help("Close")
            }
        }
        .contentShape(shape)
        .onTapGesture(perform: open)
        .onHover { inside in
            withAnimation(reduceMotion ? nil : AppMotion.hover) { hovering = inside }
            hover(inside)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [banner.title, banner.headline, banner.body].filter { !$0.isEmpty }.joined(separator: ", ")
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
        .accessibilityAction(named: "Close", close)
    }
}

/// Shows story banners in a floating panel while the app is in front (DESIGN.md 8.7). Behind other apps, or with no
/// window on screen, the system draws the banner as before.
@MainActor
final class StoryBannerPresenter {
    static let shared = StoryBannerPresenter()
    /// How long a banner stays while the pointer is not over it.
    static let lifetime: Duration = .seconds(6)

    private var panel: NSPanel?
    private var shown: String?
    private var dismissal: Task<Void, Never>?

    /// Shows the banner when the app is frontmost with a window on screen, and says whether it will; the caller then
    /// files the notification without a system banner.
    func present(_ banner: StoryBanner) -> Bool {
        guard NSApp.isActive,
            NSApp.windows.contains(where: { $0.isVisible && !$0.isMiniaturized && $0.canBecomeMain })
        else { return false }
        shown = banner.id
        Task {
            let photo = await Self.photo(at: banner.imageURL)
            // A newer banner replaced this one, or it was closed, while its photo loaded.
            guard shown == banner.id else { return }
            show(banner, photo: photo)
        }
        return true
    }

    func dismiss() {
        dismissal?.cancel()
        shown = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in self?.finishDismissal() }
        }
    }

    /// The story photo through the reader's image cache, cropped to the banner's trailing side and dissolved toward
    /// the text at the screen's scale; nil without a photo or when it cannot load.
    static func photo(at url: URL?) async -> CGImage? {
        guard let url,
            let image = try? await DecodedImageCache.load(
                url, using: { try await SecureHTTPClient.shared.fetchReaderImage(from: $0) })
        else { return nil }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return await Task.detached(priority: .userInitiated) { bannerPhoto(image, scale: scale) }.value
    }

    nonisolated static func bannerPhoto(_ image: CGImage, scale: CGFloat) -> CGImage? {
        NotificationService.dissolvingCrop(
            image, aspect: AppLayout.bannerPhotoWidth / AppLayout.bannerPhotoHeight,
            maxWidth: Int(AppLayout.bannerPhotoWidth * scale))
    }

    /// Top right of the screen's visible frame, where the system banner would sit.
    static func frame(for size: CGSize, in visible: CGRect) -> CGRect {
        CGRect(
            x: visible.maxX - size.width - AppLayout.bannerMargin,
            y: visible.maxY - size.height - AppLayout.bannerMargin, width: size.width, height: size.height)
    }

    private func show(_ banner: StoryBanner, photo: CGImage?) {
        let view = StoryBannerView(
            banner: banner, photo: photo,
            open: { [weak self] in self?.open(banner) },
            close: { [weak self] in self?.dismiss() },
            hover: { [weak self] inside in self?.hold(inside) })
        let panel = panel ?? makePanel()
        self.panel = panel
        let host = FirstClickHostingView(rootView: view)
        panel.contentView = host
        guard let screen = NSApp.keyWindow?.screen ?? NSScreen.main else { return }
        let frame = Self.frame(for: host.fittingSize, in: screen.visibleFrame)
        // Slides in from the trailing edge like the system banner; only fades under Reduce Motion.
        let slide = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : AppLayout.bannerMargin * 2
        panel.setFrame(frame.offsetBy(dx: slide, dy: 0), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }
        // The panel never takes focus, so VoiceOver hears the banner as an announcement.
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [
                .announcement: [banner.title, banner.headline].joined(separator: ": "),
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        hold(false)
    }

    /// Pauses the dismissal while the pointer is over the banner and restarts it when the pointer leaves.
    private func hold(_ inside: Bool) {
        dismissal?.cancel()
        guard !inside else { return }
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: Self.lifetime)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func finishDismissal() {
        // A banner shown during the fade keeps the panel.
        if shown == nil { panel?.orderOut(nil) }
    }

    private func open(_ banner: StoryBanner) {
        dismiss()
        // A click on the system banner clears the notification from Notification Center; this one does the same.
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [banner.id])
        Task {
            await NotificationActionRouter.route(
                actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: banner.userInfo,
                articleStore: ArticleStore.shared, readManager: AppContainer.shared.readManager,
                savedStories: AppContainer.shared.savedStories)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        // Over full-screen windows too, the common case of a video playing in front.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }
}

/// Takes the first click although the panel never becomes key, so one click opens the story.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
}
