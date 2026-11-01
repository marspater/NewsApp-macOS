// ArticleRemoteImage.swift
// Remote images loaded through the protected reader image path

import SwiftUI

extension Notification.Name {
    /// Posted with the image URL as object and `["success": Bool]` when a reader image finishes decoding or fails;
    /// never on cancellation. Lets performance harnesses wait for what the reader actually rendered.
    static let readerImageFinished = Notification.Name("readerImageFinished")
}

// The default loader retains the protected network path; native harnesses can supply an offline image.
private struct ReaderImageLoaderKey: EnvironmentKey {
    static let defaultValue: @Sendable (URL) async throws -> CGImage = {
        try await SecureHTTPClient.shared.fetchReaderImage(from: $0)
    }
}

extension EnvironmentValues {
    var readerImageLoader: @Sendable (URL) async throws -> CGImage {
        get { self[ReaderImageLoaderKey.self] }
        set { self[ReaderImageLoaderKey.self] = newValue }
    }
}

/// Decoded images by source URL, so a card scrolled back into view shows its image at once instead of fetching and
/// decoding it again. NSCache evicts under memory pressure.
@MainActor enum DecodedImageCache {
    static let images: NSCache<NSURL, CGImage> = {
        let cache = NSCache<NSURL, CGImage>()
        cache.totalCostLimit = 192 * 1024 * 1024
        cache.countLimit = 500
        return cache
    }()
    /// One download shared by every waiter on a URL. It is cancelled once all waiters that joined have cancelled.
    @MainActor final class SharedLoad {
        let task: Task<CGImage, Error>
        private(set) var waiters = 0
        private(set) var cancelledWaiters = 0
        init(task: Task<CGImage, Error>) { self.task = task }

        func join() { waiters += 1 }

        /// Records one waiter cancelling; true when no waiter is left and the download should stop.
        func leave() -> Bool {
            cancelledWaiters += 1
            return cancelledWaiters >= waiters
        }
    }
    private static var pending: [URL: SharedLoad] = [:]

    /// The download currently shared for a URL, so tests can observe who has joined it.
    static func sharedLoad(for url: URL) -> SharedLoad? { pending[url] }

    static func clear() {
        for (_, load) in pending {
            load.task.cancel()
        }
        pending.removeAll()
        images.removeAllObjects()
    }

    /// Width over height of a decoded image, so layouts can frame square and portrait photos differently.
    static func aspectRatio(for url: URL) -> CGFloat? {
        guard let image = images.object(forKey: url as NSURL), image.height > 0 else { return nil }
        return CGFloat(image.width) / CGFloat(image.height)
    }

    static func load(_ url: URL, using loader: @escaping @Sendable (URL) async throws -> CGImage) async throws
        -> CGImage
    {
        if let image = images.object(forKey: url as NSURL) { return image }
        // Shared loads survive one card disappearing; the last waiter to cancel stops the download.
        let shared =
            pending[url]
            ?? SharedLoad(task: Task { try await loader(ReaderImageCandidate.preferredRendition(of: url)) })
        let task = shared.task
        pending[url] = shared
        shared.join()
        // After clear() a newer load may own the key; only remove this load's own entry.
        defer { if pending[url] === shared { pending[url] = nil } }
        let image = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            Task { @MainActor in
                if shared.leave() {
                    task.cancel()
                    if pending[url] === shared { pending[url] = nil }
                }
            }
        }
        if !task.isCancelled && !Task.isCancelled {
            images.setObject(image, forKey: url as NSURL, cost: image.bytesPerRow * image.height)
        }
        return image
    }

    static func prefetch(_ urls: [URL], using loader: @escaping @Sendable (URL) async throws -> CGImage) async {
        var seen = Set<URL>()
        var iterator = urls.filter { seen.insert($0).inserted }.makeIterator()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                if let url = iterator.next() { group.addTask { _ = try? await load(url, using: loader) } }
            }
            while await group.next() != nil {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                if let url = iterator.next() { group.addTask { _ = try? await load(url, using: loader) } }
            }
        }
    }
}

/// A lead photo filling its frame as the lead story card and the Briefing hero show it: wide photos fill, anchored to
/// the top where subjects usually sit above the caption; square and portrait photos are shown whole over a blurred copy
/// of themselves, so faces are never cropped. Clipped, and it takes no clicks outside its frame.
struct LeadImageFill: View {
    let image: Image
    let aspectRatio: CGFloat?

    /// Below this width-to-height ratio a lead image is framed whole rather than cropped to fill.
    static let wideRatio: CGFloat = 1.25

    /// Square and portrait lead images (and wide ones only once their size is known) are framed whole.
    static func framesWhole(aspectRatio: CGFloat?) -> Bool {
        aspectRatio.map { $0 < wideRatio } ?? false
    }

    var body: some View {
        Color.clear
            .overlay(alignment: .top) {
                if Self.framesWhole(aspectRatio: aspectRatio) {
                    ZStack(alignment: .top) {
                        image.resizable().aspectRatio(contentMode: .fill)
                            .blur(radius: AppLayout.leadBackdropBlur)
                            .overlay(AppColor.leadBackdropDim)
                        image.resizable().aspectRatio(contentMode: .fit)
                    }
                } else {
                    image.resizable().aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .clipped()
            .contentShape(Rectangle())
    }
}

// Feed image URLs use the same bounded, validated network path as article content.
struct ArticleRemoteImage<Content: View>: View {
    let url: URL
    @ViewBuilder var content: (AsyncImagePhase) -> Content
    @State private var phase: AsyncImagePhase
    @State private var phaseURL: URL
    @Environment(\.readerImageLoader) private var loadImage

    init(url: URL, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.content = content
        _phase = State(
            initialValue: DecodedImageCache.images.object(forKey: url as NSURL).map { .success(Self.image($0)) }
                ?? .empty)
        _phaseURL = State(initialValue: url)
    }

    private static func image(_ image: CGImage) -> Image {
        Image(image, scale: 1, label: Text("Story image"))
    }

    var body: some View {
        content(phaseURL == url ? phase : .empty)
            .task(id: url) {
                if phaseURL == url, phase.image != nil {
                    NotificationCenter.default.post(
                        name: .readerImageFinished, object: url, userInfo: ["success": true])
                    return
                }
                phaseURL = url
                if let cached = DecodedImageCache.images.object(forKey: url as NSURL) {
                    phase = .success(Self.image(cached))
                    NotificationCenter.default.post(
                        name: .readerImageFinished, object: url, userInfo: ["success": true])
                    return
                }
                phase = .empty
                do {
                    let image = try await DecodedImageCache.load(url, using: loadImage)
                    try Task.checkCancellation()
                    phase = .success(Self.image(image))
                    NotificationCenter.default.post(
                        name: .readerImageFinished, object: url, userInfo: ["success": true])
                } catch {
                    guard !Task.isCancelled else { return }
                    phase = .failure(error)
                    NotificationCenter.default.post(
                        name: .readerImageFinished, object: url, userInfo: ["success": false])
                }
            }
    }
}
