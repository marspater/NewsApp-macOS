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
    private static var pending: [URL: Task<CGImage, Error>] = [:]

    static func clear() {
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
        if let task = pending[url] { return try await task.value }
        // Shared loads survive one card disappearing; NSCache bounds retained decoded images.
        let task = Task { try await loader(ReaderImageCandidate.preferredRendition(of: url)) }
        pending[url] = task
        defer { pending[url] = nil }
        let image = try await task.value
        images.setObject(image, forKey: url as NSURL, cost: image.bytesPerRow * image.height)
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
