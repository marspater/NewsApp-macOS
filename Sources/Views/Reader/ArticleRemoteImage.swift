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

// ArticleRemoteImage.swift
// Remote images loaded through the protected reader image path

import SwiftUI

extension Notification.Name {
    /// Posted with the image URL as object and `["success": Bool]` when a reader image finishes decoding or fails;
    /// never on cancellation. Lets performance harnesses wait for what the reader actually rendered.
    static let readerImageFinished = Notification.Name("readerImageFinished")
}

// The default loader retains the protected network path; native harnesses can supply an offline image. The second
// argument bounds the decoded image's longer side in pixels.
private struct ReaderImageLoaderKey: EnvironmentKey {
    static let defaultValue: @Sendable (URL, Int) async throws -> CGImage = {
        try await SecureHTTPClient.shared.fetchReaderImage(from: $0, maxPixelSize: $1)
    }
}

extension EnvironmentValues {
    var readerImageLoader: @Sendable (URL, Int) async throws -> CGImage {
        get { self[ReaderImageLoaderKey.self] }
        set { self[ReaderImageLoaderKey.self] = newValue }
    }
}

/// Decoded images by source URL, so a card scrolled back into view shows its image at once instead of fetching and
/// decoding it again. NSCache evicts under memory pressure.
@MainActor enum DecodedImageCache {
    /// Cards decode at card size; the reader, the lead card, the Briefing hero and banners at full size (#591).
    enum Size: Hashable, Sendable {
        case card, full

        /// The longest side in pixels: a grid card at its widest on a 2x display, or the reader's bound.
        var maxPixels: Int {
            switch self {
            case .card: Int(AppLayout.gridColumnMaximum * 2)
            case .full: 1600
            }
        }
    }

    /// Full-size decodes, which also serve a card asking for the same URL.
    static let images: NSCache<NSURL, CGImage> = {
        let cache = NSCache<NSURL, CGImage>()
        cache.totalCostLimit = 192 * 1024 * 1024
        cache.countLimit = 500
        return cache
    }()
    /// Card-size decodes.
    static let cardImages: NSCache<NSURL, CGImage> = {
        let cache = NSCache<NSURL, CGImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        cache.countLimit = 500
        return cache
    }()

    /// A decoded image at least as large as `size` asks for: a card takes a full-size decode too.
    static func cached(_ url: URL, size: Size = .full) -> CGImage? {
        (size == .card ? cardImages.object(forKey: url as NSURL) : nil) ?? images.object(forKey: url as NSURL)
    }

    private static func store(_ image: CGImage, for url: URL, size: Size) {
        (size == .card ? cardImages : images).setObject(
            image, forKey: url as NSURL, cost: image.bytesPerRow * image.height)
    }

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
    private struct Key: Hashable {
        let url: URL
        let size: Size
    }
    private static var generation: UInt64 = 0
    private static var pending: [Key: SharedLoad] = [:]

    /// The download currently shared for a URL, so tests can observe who has joined it.
    static func sharedLoad(for url: URL, size: Size = .full) -> SharedLoad? { pending[Key(url: url, size: size)] }

    static func clear() {
        generation &+= 1
        for (_, load) in pending {
            load.task.cancel()
        }
        pending.removeAll()
        images.removeAllObjects()
        cardImages.removeAllObjects()
    }

    /// Width over height of a decoded image, so layouts can frame square and portrait photos differently.
    static func aspectRatio(for url: URL) -> CGFloat? {
        guard let image = cached(url, size: .card), image.height > 0 else { return nil }
        return CGFloat(image.width) / CGFloat(image.height)
    }

    static func load(
        _ url: URL, size: Size = .full, using loader: @escaping @Sendable (URL, Int) async throws -> CGImage
    ) async throws -> CGImage {
        if let image = cached(url, size: size) { return image }
        let currentGeneration = generation
        let key = Key(url: url, size: size)
        // Shared loads survive one card disappearing; the last waiter to cancel stops the download.
        let shared: SharedLoad
        if let existing = pending[key], !existing.task.isCancelled {
            shared = existing
        } else {
            let maxPixels = size.maxPixels
            shared = SharedLoad(
                task: Task { try await loader(ReaderImageCandidate.preferredRendition(of: url), maxPixels) })
            pending[key] = shared
        }
        let task = shared.task
        shared.join()
        // After clear() a newer load may own the key; only remove this load's own entry.
        defer { if pending[key] === shared { pending[key] = nil } }
        let image = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            Task { @MainActor in
                if shared.leave() {
                    task.cancel()
                    if pending[key] === shared { pending[key] = nil }
                }
            }
        }
        if !task.isCancelled && !Task.isCancelled && generation == currentGeneration {
            store(image, for: url, size: size)
        }
        return image
    }

    static func prefetch(
        _ urls: [URL], size: Size = .full, using loader: @escaping @Sendable (URL, Int) async throws -> CGImage
    ) async {
        var seen = Set<URL>()
        var iterator = urls.filter { seen.insert($0).inserted }.makeIterator()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                if let url = iterator.next() { group.addTask { _ = try? await load(url, size: size, using: loader) } }
            }
            while await group.next() != nil {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                if let url = iterator.next() { group.addTask { _ = try? await load(url, size: size, using: loader) } }
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
    let size: DecodedImageCache.Size
    @ViewBuilder var content: (AsyncImagePhase) -> Content
    @State private var phase: AsyncImagePhase
    @State private var phaseURL: URL
    @Environment(\.readerImageLoader) private var loadImage

    init(
        url: URL, size: DecodedImageCache.Size = .full, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content
    ) {
        self.url = url
        self.size = size
        self.content = content
        _phase = State(
            initialValue: DecodedImageCache.cached(url, size: size).map { .success(Self.image($0)) } ?? .empty)
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
                if let cached = DecodedImageCache.cached(url, size: size) {
                    phase = .success(Self.image(cached))
                    NotificationCenter.default.post(
                        name: .readerImageFinished, object: url, userInfo: ["success": true])
                    return
                }
                phase = .empty
                for attempt in 0..<3 {
                    do {
                        let image = try await DecodedImageCache.load(url, size: size, using: loadImage)
                        try Task.checkCancellation()
                        phase = .success(Self.image(image))
                        NotificationCenter.default.post(
                            name: .readerImageFinished, object: url, userInfo: ["success": true])
                        return
                    } catch {
                        // Our own cancellation exits silently. A shared load cancelled under us (a cache clear) is
                        // retried, and reported as a failure once the retries run out, never left on the placeholder.
                        guard !Task.isCancelled else { return }
                        let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                        if cancelled, attempt < 2 { continue }
                        phase = .failure(error)
                        NotificationCenter.default.post(
                            name: .readerImageFinished, object: url, userInfo: ["success": false])
                        return
                    }
                }
            }
    }
}
