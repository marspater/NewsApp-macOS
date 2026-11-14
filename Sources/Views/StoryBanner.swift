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
import os

/// A notification as the app draws it (DESIGN.md 8.7): the app's own panel is the only delivery path, so every
/// banner is this value, from a story's own banner to the summary and the private one.
struct StoryBanner: Sendable, Equatable {
    /// Identifies the banner; the photo it loads is applied only while this banner is still on screen.
    var id: String
    /// The banner's first line: the story's publisher, a grouped banner's title, or "News Update" for summary and
    /// private banners.
    var title: String
    /// The story's headline; empty for grouped, summary and private banners.
    var headline = ""
    var body = ""
    /// The story a click opens; nil for grouped, summary and private banners.
    var articleID: String?
    /// The story's link; the router finds the story by it only when `articleID` is nil.
    var articleLink: String?
    /// The story photos to try in order; empty for grouped, summary and private banners.
    var imageURLs: [URL] = []
    /// Reports of one story share a thread; a banner replaces the one on screen either way.
    var thread = ""
    /// Whether the banner asks for the reader's alert sound.
    var sound = false
    /// Only a story's own banner carries Save, Mark as Read and Open (#560).
    var actions = false

    /// What the router reads, as a click on a system banner handed it over.
    var userInfo: [String: String] {
        var info: [String: String] = [:]
        info["articleID"] = articleID
        info["articleLink"] = articleLink
        return info
    }

    /// The banner as hidden previews show it: no publisher, headline, summary, photo or actions. A click still opens
    /// the story, as it does on a system banner with hidden previews.
    var redacted: StoryBanner {
        StoryBanner(
            id: id, title: "News Update", body: "You have new articles available. Open to read.",
            articleID: articleID, articleLink: articleLink, thread: thread, sound: sound)
    }
}

/// App icon, publisher, headline and summary on the glass, and the story photo filling the trailing side to the
/// banner's own corners, dissolving toward the text.
struct StoryBannerView: View {
    /// The banner to draw.
    let banner: StoryBanner
    /// The cropped story photo; nil draws no photo.
    let photo: CGImage?
    /// Set by the panel's own tracking area, which follows the pointer while News is not the active app as well.
    var hovering = false
    /// An Alert-style banner stays until closed, so its close button and actions show without a pointer.
    var persistent = false
    // The presenter supplies these; an offscreen render has nothing to open, close or act on.
    /// Opens the banner's story.
    var open: () -> Void = {
        // Nothing to open offscreen.
    }
    /// Closes the banner.
    var close: () -> Void = {
        // Nothing to close offscreen.
    }
    /// Save, Mark as Read or Open, by `NotificationActionIdentifier`.
    var act: (String) -> Void = { _ in
        // Nothing to act on offscreen.
    }
    @Environment(\.effectiveReduceMotion) private var reduceMotion

    /// Whether the pointer is over the banner or it waits for the reader: the close button and actions show.
    private var revealed: Bool { hovering || persistent }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous) }

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable()
                .frame(width: AppLayout.bannerIconSize, height: AppLayout.bannerIconSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(banner.title).foregroundStyle(AppColor.secondaryText)
                if !banner.headline.isEmpty { Text(banner.headline) }
                if !banner.body.isEmpty {
                    Text(banner.body).font(.body).lineLimit(3)
                }
                if banner.actions, revealed { actionRow }
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
            if revealed {
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
        // A touch has no hover: a swipe sideways closes the banner, as it does a system banner.
        .gesture(
            DragGesture(minimumDistance: AppSpacing.md).onEnded { drag in
                if abs(drag.translation.width) > AppLayout.bannerSwipeDistance { close() }
            }
        )
        .animation(reduceMotion ? nil : AppMotion.hover, value: revealed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [banner.title, banner.headline, banner.body].filter { !$0.isEmpty }.joined(separator: ", ")
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
        .accessibilityAction(named: "Close", close)
        // Only a story's own banner carries these, so only it offers them to VoiceOver.
        .accessibilityActions {
            if banner.actions {
                Button("Save") { act(NotificationActionIdentifier.save) }
                Button("Mark as Read") { act(NotificationActionIdentifier.markRead) }
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: AppSpacing.md) {
            actionButton("Save", NotificationActionIdentifier.save)
            actionButton("Mark as Read", NotificationActionIdentifier.markRead)
            actionButton("Open", NotificationActionIdentifier.open)
        }
        .padding(.top, AppSpacing.xs)
    }

    private func actionButton(_ title: String, _ identifier: String) -> some View {
        Button(title) { act(identifier) }
            .buttonStyle(.plain)
            .font(.subheadline)
            .foregroundStyle(AppColor.accentText)
    }
}

/// Shows every banner in a floating panel, whatever state the app is in: active, behind another app, hidden,
/// minimized or without a window (DESIGN.md 8.7). The panel never hides with the app and outlives its windows.
@MainActor
final class StoryBannerPresenter {
    /// The one presenter of the app.
    static let shared = StoryBannerPresenter()
    /// Every decision on the way to a banner, at notice level so `log show` keeps it (#926). No story text is logged.
    nonisolated static let log = Logger(subsystem: "com.marspater.news", category: "StoryBanner")
    /// How long a banner stays while the pointer is not over it.
    static let lifetime: Duration = .seconds(6)

    /// Tests set this so the presenter's logic runs with nothing ordered on screen: the panel is laid out but never
    /// ordered front (#991).
    var isHeadless = false

    private var panel: NSPanel?
    private var host: FirstClickHostingView<StoryBannerView>?
    /// The banner on screen, its photo once loaded, and whether the pointer is over it.
    private struct Shown {
        var banner: StoryBanner
        var photo: CGImage?
        var hovering = false
        /// Stays until closed (the Alert alert style).
        var persistent = false
        var screen: NSScreen
    }
    private var shown: Shown?
    /// Read-only banner state for headless regression assertions.
    var hasPresentedPhoto: Bool { shown?.photo != nil }
    /// Whether a banner is on screen.
    var isShowing: Bool { shown != nil }
    /// The panel, for tests.
    var panelForTesting: NSPanel? { panel }
    /// Whether the banner on screen will leave by itself.
    var hasDismissalTimer: Bool { dismissal.map { !$0.isCancelled } ?? false }
    /// In-flight photo task for headless regression synchronization.
    var photoTaskForTesting: Task<Void, Never>? { photoTask }
    private var dismissal: Task<Void, Never>?
    /// Current banner owns its image request; replacing or closing it cancels obsolete work.
    private var photoTask: Task<Void, Never>?
    private let photoLoader: @MainActor @Sendable (URL?, CGFloat) async -> CGImage?

    /// Creates a presenter; tests pass a photo loader that needs no network.
    init(
        photoLoader: @escaping @MainActor @Sendable (URL?, CGFloat) async -> CGImage? = { url, scale in
            await StoryBannerPresenter.photo(at: url, scale: scale)
        }
    ) {
        self.photoLoader = photoLoader
    }

    /// The News window on screen: visible and not minimized, with the app not hidden. It need not be the active app.
    static func openWindow() -> NSWindow? {
        guard let app = NSApp, !app.isHidden else { return nil }
        return app.windows.first { $0.isVisible && !$0.isMiniaturized && $0.canBecomeMain }
    }

    /// The News window, set by `MainWindowMarker`; weak, so a closed window is gone.
    static weak var mainWindow: NSWindow?

    /// Brings the News window forward for a click on a banner: unhides, restores it when minimized and, when it is
    /// closed, asks the app to reopen as a click on its Dock icon does, which creates it again, whatever other
    /// windows (Keyboard Shortcuts, Log) are open. The story a click names waits in `ArticleStore.pendingNavigation`
    /// until that window loads it.
    static func showMainWindow() {
        guard let app = NSApp else { return }
        if app.isHidden { app.unhide(nil) }
        if let window = mainWindow, window.isMiniaturized {
            window.deminiaturize(nil)
        } else if let window = mainWindow, window.isVisible {
            // Open but behind other windows, or on another Space: in front of them, so the story is seen.
            if window.canBecomeKey {
                window.makeKeyAndOrderFront(nil)
            } else {
                window.orderFront(nil)
            }
        } else {
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: .init())
        }
        app.activate()
    }

    /// Shows the banner and says whether it did: no screen, or a banner that measures empty, shows nothing. The text
    /// shows at once and the photo joins when it loads. `persistent` keeps it until the reader closes it.
    func present(_ banner: StoryBanner, persistent: Bool = false) -> Bool {
        let window = isHeadless ? NSApp?.windows.first { $0.canBecomeMain } : Self.openWindow()
        Self.log.notice(
            "present \(banner.id, privacy: .private(mask: .hash)): active=\(NSApp?.isActive ?? false, privacy: .public) window=\(window != nil, privacy: .public) persistent=\(persistent, privacy: .public)"
        )
        guard let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens.first else { return false }
        photoTask?.cancel()
        photoTask = nil
        shown = Shown(banner: banner, persistent: persistent, screen: screen)
        guard show(banner, on: screen) else {
            dismiss()
            return false
        }
        if !banner.imageURLs.isEmpty {
            let bannerID = banner.id
            let scale = screen.backingScaleFactor
            let loader = photoLoader
            let urls = banner.imageURLs
            photoTask = Task { [weak self] in
                // The first candidate that loads: a lead that is a page, or a logo the reader rejects, is not the photo.
                for url in urls {
                    let photo = await loader(url, scale)
                    guard !Task.isCancelled, let self, self.shown?.banner.id == bannerID else { return }
                    guard let photo else { continue }
                    self.shown?.photo = photo
                    self.render()
                    return
                }
            }
        }
        return true
    }

    /// Closes the banner on screen, cancels its timer and photo load, and fades the panel out.
    func dismiss() {
        dismissal?.cancel()
        photoTask?.cancel()
        photoTask = nil
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
    static func photo(at url: URL?, scale: CGFloat) async -> CGImage? {
        guard let url else { return nil }
        let image: CGImage
        do {
            image = try await DecodedImageCache.load(
                url, using: { try await SecureHTTPClient.shared.fetchReaderImage(from: $0, maxPixelSize: $1) })
        } catch {
            // A dismissed banner cancels its photo; anything else names the stage, type and bytes, never the URL.
            if !ImageLoadFailure.isCancellation(error) {
                log.error("banner photo failed: \(ImageLoadFailure.describe(error), privacy: .public)")
            }
            return nil
        }
        guard !Task.isCancelled else { return nil }
        let cropTask = Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard !Task.isCancelled else { return nil }
            return bannerPhoto(image, scale: scale)
        }
        let photo = await withTaskCancellationHandler {
            await cropTask.value
        } onCancel: {
            cropTask.cancel()
        }
        guard !Task.isCancelled else { return nil }
        if photo == nil {
            log.error(
                "banner photo failed: stage=crop size=\(image.width, privacy: .public)x\(image.height, privacy: .public)"
            )
        }
        return photo
    }

    /// The photo cropped to the banner's aspect at the screen scale, dissolving toward the text.
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

    private func view(for banner: StoryBanner, photo: CGImage?, hovering: Bool, persistent: Bool) -> StoryBannerView {
        StoryBannerView(
            banner: banner, photo: photo, hovering: hovering, persistent: persistent,
            open: { [weak self] in self?.open(banner) },
            close: { [weak self] in self?.dismiss() },
            act: { [weak self] in self?.act($0, on: banner) })
    }

    /// Redraws the banner on screen after its photo or hover state changed. Revealing the actions makes it taller, so
    /// the panel follows its content and stays at the top right.
    private func render() {
        guard let shown, let host else { return }
        host.rootView = view(
            for: shown.banner, photo: shown.photo, hovering: shown.hovering, persistent: shown.persistent)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        // A photo that arrives during the slide-in leaves the size alone, so the animation runs on.
        guard size.width > 1, size.height > 1, let panel, size != panel.frame.size else { return }
        panel.setFrame(Self.frame(for: size, in: shown.screen.visibleFrame), display: true)
    }

    /// Puts the banner on screen, or says it could not, so the caller falls back to the system banner instead of an
    /// invisible one.
    private func show(_ banner: StoryBanner, on screen: NSScreen) -> Bool {
        let panel = panel ?? makePanel()
        self.panel = panel
        // The photo is the banner's background, so adding it later leaves the size measured here unchanged.
        let host = FirstClickHostingView(
            rootView: view(for: banner, photo: nil, hovering: false, persistent: shown?.persistent ?? false))
        host.hover = { [weak self] inside in self?.hold(inside) }
        // Measured before the panel lays it out, which on a deferred, empty panel can come back empty.
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        guard size.width > 1, size.height > 1 else {
            Self.log.error(
                "banner measured \(size.width, privacy: .public)x\(size.height, privacy: .public); system banner instead"
            )
            return false
        }
        self.host = host
        panel.contentView = host
        let frame = Self.frame(for: size, in: screen.visibleFrame)
        // Slides in from the trailing edge like the system banner; only fades under Reduce Motion.
        let slide = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : AppLayout.bannerMargin * 2
        panel.setFrame(frame.offsetBy(dx: slide, dy: 0), display: false)
        panel.alphaValue = 0
        if !isHeadless { panel.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            panel.animator().setFrame(frame, display: false)
            panel.animator().alphaValue = 1
        }
        // The panel never takes focus, so VoiceOver hears the banner as an announcement.
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [
                .announcement: [banner.title, banner.headline].joined(separator: ": "),
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        // A banner that replaces another under a resting pointer gets no mouseEntered, so it starts from the pointer.
        hold(isHeadless ? false : frame.contains(NSEvent.mouseLocation))
        Self.log.notice(
            "shown \(banner.id, privacy: .private(mask: .hash)): frame=\(NSStringFromRect(frame), privacy: .public) visible=\(panel.isVisible, privacy: .public) screen=\(NSStringFromRect(screen.visibleFrame), privacy: .public)"
        )
        return true
    }

    /// Pauses the dismissal while the pointer is over the banner and restarts it when the pointer leaves.
    private func hold(_ inside: Bool) {
        if shown != nil, shown?.hovering != inside {
            shown?.hovering = inside
            render()
        }
        dismissal?.cancel()
        guard !inside, shown?.persistent != true else { return }
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

    /// A click: the story opens, and a banner without a story brings the app's window forward.
    private func open(_ banner: StoryBanner) {
        dismiss()
        guard !banner.userInfo.isEmpty else { return Self.showMainWindow() }
        route(NotificationActionIdentifier.open, banner)
    }

    private func act(_ identifier: String, on banner: StoryBanner) {
        dismiss()
        route(identifier, banner)
    }

    private func route(_ identifier: String, _ banner: StoryBanner) {
        Task {
            await NotificationActionRouter.route(
                actionIdentifier: identifier, userInfo: banner.userInfo, articleStore: ArticleStore.shared,
                readManager: AppContainer.shared.readManager, savedStories: AppContainer.shared.savedStories)
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
        // Hiding the app, closing or minimizing its windows must not take a banner down with them.
        panel.canHide = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        return panel
    }
}

/// Takes the first click although the panel never becomes key, so one click opens the story, and reports the pointer
/// entering and leaving even while News is not the active app, where SwiftUI's hover tracking stays silent.
@MainActor
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    /// Called with true when the pointer enters the view and false when it leaves.
    var hover: ((Bool) -> Void)?

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["banner"] != nil {
            removeTrackingArea(area)
        }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self,
                userInfo: ["banner": true]))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        hover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hover?(false)
    }
}

/// Tells the banner which window is News, so a click can bring that one forward or create it again.
struct MainWindowMarker: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView { Marker() }
    func updateNSView(_: NSView, context _: Context) {
        // Nothing changes after the window is known.
    }

    private final class Marker: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window, window.canBecomeKey || window.canBecomeMain {
                StoryBannerPresenter.mainWindow = window
            }
        }
    }
}
