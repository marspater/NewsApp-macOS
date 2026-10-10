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
@MainActor private enum DecodedImageCache {
    static let images: NSCache<NSURL, CGImage> = {
        let cache = NSCache<NSURL, CGImage>()
        cache.totalCostLimit = 192 * 1024 * 1024
        return cache
    }()
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
        Image(image, scale: 1, label: Text("Article image"))
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
                    let image = try await loadImage(ReaderImageCandidate.preferredRendition(of: url))
                    try Task.checkCancellation()
                    DecodedImageCache.images.setObject(
                        image, forKey: url as NSURL, cost: image.bytesPerRow * image.height)
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
