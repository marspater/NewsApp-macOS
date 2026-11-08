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
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// Offline loader with controlled completion, including a cancelled request that ignores cancellation.
private actor BannerPhotoLoadProbe {
    private var starts = 0
    private var cancellations = 0
    private var completions = 0
    private var releases: [Int: CheckedContinuation<CGImage?, Never>] = [:]

    func load() async -> CGImage? {
        let request = starts
        starts += 1
        let photo = await withTaskCancellationHandler {
            await hold(request)
        } onCancel: {
            Task { await self.recordCancellation() }
        }
        completions += 1
        return photo
    }

    private func hold(_ request: Int) async -> CGImage? {
        await withCheckedContinuation { continuation in
            releases[request] = continuation
        }
    }

    private func recordCancellation() { cancellations += 1 }

    func release(_ request: Int, photo: CGImage?) {
        releases.removeValue(forKey: request)?.resume(returning: photo)
    }

    func snapshot() -> (starts: Int, cancellations: Int, completions: Int) {
        (starts, cancellations, completions)
    }
}

enum NotificationAttachmentTests {
    static func run() {
        // A lead recorded as a page URL (#1010) is tried first, then the other reader candidates, then the feed image;
        // a candidate the reader rejects (a logo, an SVG) and a repeat of the lead are left out.
        do {
            let page = "https://news.example/story/675"
            let document = ReaderDocument(
                blocks: [ReaderBlock(kind: .paragraph, text: "Publisher prose")],
                images: [
                    ReaderImageCandidate(url: page, origin: .body, width: 1672, height: 941),
                    ReaderImageCandidate(url: "https://news.example/logo.png", origin: .body),
                    ReaderImageCandidate(url: "https://news.example/tiny.png", origin: .body, width: 1, height: 1),
                    ReaderImageCandidate(
                        url: "https://news.example/second.jpg", origin: .body, width: 800, height: 600),
                    ReaderImageCandidate(url: "https://news.example/photo.png?w=1672", origin: .feed),
                ], leadImageURL: page)
            let article = FeedArticle(
                title: "Story", link: "https://news.example/story", guid: "story", description: "", pubDate: Date(),
                source: "News", imageUrl: "https://news.example/photo.png?w=1672", fullContent: "Publisher prose",
                readerDocument: document)
            let urls = FeedArticle.attachmentImages(for: article).map(\.absoluteString)
            precondition(
                urls == [page, "https://news.example/second.jpg", "https://news.example/photo.png?w=1672"],
                "Attachment candidates must run lead, other usable candidates, feed image; got \(urls)")
            let tinyFeed = FeedArticle(
                title: "Story", link: "https://news.example/tiny", guid: "tiny", description: "", pubDate: Date(),
                source: "News", imageUrl: "https://news.example/tiny.png", readerDocument: document)
            precondition(
                !FeedArticle.attachmentImages(for: tinyFeed).contains { $0.absoluteString.hasSuffix("tiny.png") },
                "A feed image with known tiny dimensions must not become a fallback")
            let bare = FeedArticle(
                title: "Story", link: "https://news.example/bare", guid: "bare", description: "", pubDate: Date(),
                source: "News")
            precondition(FeedArticle.attachmentImages(for: bare).isEmpty, "No image means no candidates")
        }

        // Valid 1x1 WebP: accepted by ImageIO, rejected when attached directly as .webp (UNErrorDomain 101).
        let webp = Data(base64Encoded: "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA")!
        do {
            let attachment = try NotificationService.makeImageAttachment(data: webp)
            precondition(attachment.type == UTType.png.identifier, "Unsupported WebP must become a supported PNG")
            let png = try Data(contentsOf: attachment.url)
            let source = CGImageSourceCreateWithData(png as CFData, nil)
            precondition(source != nil, "The framework-owned attachment must remain readable")
            precondition(
                CGImageSourceGetType(source!) as String? == UTType.png.identifier, "Attachment bytes must be PNG")
            let second = try NotificationService.makeImageAttachment(data: png)
            precondition(second.type == UTType.png.identifier, "Existing PNG images remain supported")
        } catch { fatalError("Notification image conversion failed: \(error)") }
        do {
            _ = try NotificationService.makeImageAttachment(data: Data("not an image".utf8), contentType: "text/html")
            fatalError("Malformed images must not become notification attachments")
        } catch {
            // The log names the stage and what the host sent (#1010); a request error reads as the fetch stage.
            precondition(
                ImageLoadFailure.describe(error).hasPrefix("stage=decode type=text/html bytes=12"),
                "Decode failure names its stage, got \(error)")
            precondition(
                ImageLoadFailure.describe(URLError(.cannotDecodeContentData))
                    == "stage=fetch type=unknown bytes=unknown domain=NSURLErrorDomain code=-1016")
            precondition(
                ImageLoadFailure.isCancellation(CancellationError())
                    && ImageLoadFailure.isCancellation(URLError(.cancelled))
                    && !ImageLoadFailure.isCancellation(URLError(.timedOut)),
                "Cancelled loads stay out of the log; other request errors do not")
        }

        // An 8-bit colormap PNG (#1010) decodes for the reader and becomes the tall crop attachment.
        do {
            let palette = palettePNG(width: 962, height: 548)
            precondition(palette[25] == 3, "The fixture is a palette PNG (IHDR colour type 3), got \(palette[25])")
            let decoded = try SecureHTTPClient.decodeReaderImage(palette)
            precondition(decoded.width == 962 && decoded.height == 548, "Palette PNG decodes at its size")
            let attachment = try NotificationService.makeImageAttachment(data: palette, contentType: "image/png")
            let image = CGImageSourceCreateImageAtIndex(
                CGImageSourceCreateWithData(try Data(contentsOf: attachment.url) as CFData, nil)!, 0, nil)!
            precondition(
                image.width == 366 && image.height == 548,
                "Palette PNG becomes the 2:3 crop, got \(image.width) × \(image.height)")
            precondition(alpha(image, x: 360, y: 274) == 255, "Palette crop is opaque at the trailing edge")
            precondition(StoryBannerPresenter.bannerPhoto(decoded, scale: 2) != nil, "Palette banner photo renders")
            // The host serves the named PNG, not a `Vary: Accept` WebP or AVIF variant, to an image request (#1010).
            precondition(
                SecureHTTPClient.imageAccept.hasPrefix("image/png,")
                    && !SecureHTTPClient.imageAccept.contains("webp") && !SecureHTTPClient.imageAccept.contains("avif"),
                "Image requests do not invite WebP or AVIF variants")
        } catch { fatalError("Palette PNG notification image failed: \(error)") }

        // The tall fading crop (#589): a 1200 × 1200 source becomes a 600 × 900 portrait PNG with alpha,
        // transparent at the leading edge and opaque at the trailing edge; the same input renders the same bytes,
        // and a small source keeps its own size.
        do {
            let landscape = png(width: 1200, height: 1200)
            let tall = try NotificationService.makeImageAttachment(data: landscape)
            let bytes = try Data(contentsOf: tall.url)
            precondition(bytes.count <= 10_000_000, "Attachment stays within the notification size limit")
            let source = CGImageSourceCreateWithData(bytes as CFData, nil)!
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            precondition(
                image.width == 600 && image.height == 900,
                "Tall crop is 600 × 900, got \(image.width) × \(image.height)")
            precondition(
                image.alphaInfo != .none && image.alphaInfo != .noneSkipLast && image.alphaInfo != .noneSkipFirst,
                "Crop carries alpha")
            precondition(alpha(image, x: 1, y: 450) < 16, "Leading edge fades to transparent")
            precondition(alpha(image, x: 580, y: 450) == 255, "Trailing side is opaque")
            // x = 300 is past the fade (45%) but inside the blur ramp (60%), where an unclamped blur thins the edges.
            precondition(alpha(image, x: 300, y: 0) == 255, "Blur keeps the top edge opaque")
            precondition(alpha(image, x: 300, y: 899) == 255, "Blur keeps the bottom edge opaque")
            let again = try Data(contentsOf: try NotificationService.makeImageAttachment(data: landscape).url)
            precondition(again == bytes, "The same source renders the same bytes")
            let small = try NotificationService.makeImageAttachment(data: png(width: 200, height: 200))
            let smallSource = CGImageSourceCreateWithData(try Data(contentsOf: small.url) as CFData, nil)!
            let smallImage = CGImageSourceCreateImageAtIndex(smallSource, 0, nil)!
            precondition(smallImage.width == 200 && smallImage.height == 200, "Small sources keep their size")
        } catch { fatalError("Notification image crop failed: \(error)") }
        print("✅ Notification attachment format regressions passed")
    }

    /// The app-drawn story banner (DESIGN.md 8.7): only a story's request becomes one, its photo dissolves toward the
    /// text, and the rendered banner shows the photo to its trailing edge inside the banner's own corners. Set
    /// NEWS_BANNER_CAPTURES to a folder to keep the light and dark renders.
    @MainActor static func runBanner() async {
        let content = UNMutableNotificationContent()
        content.title = "Culture"
        content.subtitle = "Romeo + Juliet at 30: how Baz Luhrmann's film still burns"
        content.body =
            "The maximalist, heart over head adaptation of the romantic tragedy made stars of its leads and became "
            + "a defining film of its decade."
        content.categoryIdentifier = NotificationActionIdentifier.category
        content.userInfo = [
            "articleID": "story-1", "articleLink": "https://example.com/a", "imageURL": "https://example.com/a.jpg",
        ]
        guard
            let banner = StoryBanner(UNNotificationRequest(identifier: "news-story-1", content: content, trigger: nil))
        else { fatalError("A story request becomes an app-drawn banner") }
        precondition(banner.headline == content.subtitle && banner.title == "Culture", "Banner keeps the copy")
        precondition(banner.imageURL?.absoluteString == "https://example.com/a.jpg", "Banner finds the photo")
        precondition(banner.userInfo == ["articleID": "story-1", "articleLink": "https://example.com/a"])
        content.categoryIdentifier = ""
        precondition(
            StoryBanner(UNNotificationRequest(identifier: "grouped", content: content, trigger: nil)) == nil,
            "Grouped and summary banners stay with the system")

        let data = png(width: 1200, height: 800)
        let source = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil)!
        guard let photo = StoryBannerPresenter.bannerPhoto(source, scale: 2) else {
            fatalError("The banner photo must render")
        }
        precondition(
            photo.width == 336 && photo.height == 256, "Banner photo is 336 × 256, got \(photo.width) × \(photo.height)"
        )
        precondition(alpha(photo, x: 1, y: 128) < 16, "Banner photo fades out toward the text")
        precondition(alpha(photo, x: 334, y: 128) == 255, "Banner photo is opaque at the trailing edge")

        let frame = StoryBannerPresenter.frame(
            for: CGSize(width: 344, height: 104), in: CGRect(x: 0, y: 25, width: 1512, height: 919))
        precondition(frame == CGRect(x: 1152, y: 824, width: 344, height: 104), "Banner sits top right, got \(frame)")

        for scheme in [ColorScheme.light, .dark] {
            let renderer = ImageRenderer(
                content: StoryBannerView(banner: banner, photo: photo).environment(\.colorScheme, scheme))
            renderer.scale = 2
            guard let image = renderer.cgImage else { fatalError("The banner must render offscreen") }
            if let folder = ProcessInfo.processInfo.environment["NEWS_BANNER_CAPTURES"] {
                let url = URL(fileURLWithPath: folder).appendingPathComponent("story-banner-\(scheme).png")
                let destination = CGImageDestinationCreateWithURL(
                    url as CFURL, UTType.png.identifier as CFString, 1, nil)!
                CGImageDestinationAddImage(destination, image, nil)
                precondition(CGImageDestinationFinalize(destination), "Banner capture must write")
            }
            precondition(image.width == 688, "Banner is 344 pt wide, got \(image.width) px")
            precondition(
                alpha(image, x: image.width - 2, y: image.height / 2) == 255,
                "Photo reaches the trailing edge, alpha \(alpha(image, x: image.width - 2, y: image.height / 2)) "
                    + "of \(image.width) × \(image.height), \(image.alphaInfo.rawValue)")
            precondition(
                alpha(image, x: 0, y: 0) == 0 && alpha(image, x: image.width - 1, y: 0) == 0
                    && alpha(image, x: image.width - 1, y: image.height - 1) == 0,
                "Banner and photo share the rounded corners")
        }

        // Test StoryBannerPresenter presentation, openWindow, and dismissal
        _ = NSApplication.shared
        let initialWindow = StoryBannerPresenter.openWindow()
        class BannerTestWindow: NSWindow {
            override var canBecomeMain: Bool { true }
            override var canBecomeKey: Bool { true }
        }
        let testWindow = BannerTestWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        testWindow.isReleasedWhenClosed = false
        // Nothing is ordered on screen: the headless suite opens no window or banner panel on the desktop (#991).
        precondition(StoryBannerPresenter.openWindow() == initialWindow, "A window never ordered in is not open")
        let presenter = StoryBannerPresenter.shared
        if initialWindow == nil { precondition(!presenter.present(banner), "No window on screen, no app-drawn banner") }
        presenter.isHeadless = true
        defer { presenter.isHeadless = false }
        precondition(presenter.present(banner), "Banner presents when a window is open")
        precondition(!testWindow.isVisible, "Headless presentation orders no window on screen (#991)")

        // Replacing or dismissing a banner must cancel its in-flight image request (#1161).
        let probe = BannerPhotoLoadProbe()
        let isolated = StoryBannerPresenter(photoLoader: { _, _ in await probe.load() })
        isolated.isHeadless = true
        precondition(isolated.present(banner), "The injected banner presents offscreen")
        for _ in 0..<200 {
            if await probe.snapshot().starts == 1 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let first = await probe.snapshot()
        precondition(first.starts == 1, "The first banner starts one image request")
        let replacementContent = UNMutableNotificationContent()
        replacementContent.categoryIdentifier = NotificationActionIdentifier.category
        replacementContent.title = "Replacement"
        replacementContent.subtitle = "Without an image"
        guard
            let replacement = StoryBanner(
                UNNotificationRequest(identifier: "news-story-2", content: replacementContent, trigger: nil))
        else { fatalError("A second story request becomes a banner") }
        precondition(isolated.present(replacement), "Replacement banner presents offscreen")
        for _ in 0..<200 {
            if await probe.snapshot().cancellations == 1 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let replaced = await probe.snapshot()
        precondition(
            replaced.starts == 1 && replaced.cancellations == 1,
            "Replacing the banner cancels its old photo without starting a new one")
        precondition(isolated.present(banner), "The original banner can be presented again")
        for _ in 0..<200 {
            if await probe.snapshot().starts == 2 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let restarted = await probe.snapshot()
        precondition(restarted.starts == 2, "Reopening the banner starts a fresh image request")

        // The first cancelled request deliberately ignores cancellation and returns an image after the same ID
        // is shown again. It must never become the reopened banner's photo.
        await probe.release(0, photo: source)
        for _ in 0..<200 {
            if await probe.snapshot().completions == 1 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let completed = await probe.snapshot()
        precondition(completed.completions == 1, "The cancelled image loader completes")
        for _ in 0..<20 { await Task.yield() }
        precondition(!isolated.hasPresentedPhoto, "A cancelled image must not appear on the reopened banner")

        // A fresh request for that same banner is allowed to render its own photo.
        await probe.release(1, photo: source)
        for _ in 0..<200 {
            if isolated.hasPresentedPhoto { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        precondition(isolated.hasPresentedPhoto, "The reopened banner renders its fresh image")
        isolated.dismiss()
        precondition(!isolated.hasPresentedPhoto, "Dismissing the banner clears its image")

        // Notification handlers
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: NSWindow())
        NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: testWindow)
        NotificationCenter.default.post(name: NSApplication.didHideNotification, object: nil)

        StoryBannerPresenter.shared.dismiss()
        testWindow.close()
        precondition(initialWindow == nil || StoryBannerPresenter.openWindow() == initialWindow)

        // FirstClickHostingView
        let hostView = FirstClickHostingView(rootView: Text("Banner Test"))
        precondition(hostView.acceptsFirstMouse(for: nil), "FirstClickHostingView accepts first mouse")
        hostView.updateTrackingAreas()
        var hoverDetected: Bool?
        hostView.hover = { hoverDetected = $0 }
        if let event = NSEvent.enterExitEvent(
            with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
        ) {
            hostView.mouseEntered(with: event)
            precondition(hoverDetected == true, "mouseEntered triggers hover callback")
        }
        if let event = NSEvent.enterExitEvent(
            with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
        ) {
            hostView.mouseExited(with: event)
            precondition(hoverDetected == false, "mouseExited triggers hover callback")
        }

        print("✅ Story banner regressions passed")
    }

    private static func png(width: Int, height: Int) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 0.9, green: 0.3, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }
    /// A palette PNG of four colour bands, written by ImageIO from an indexed image.
    private static func palettePNG(width: Int, height: Int) -> Data {
        let table: [UInt8] = [20, 40, 200, 230, 80, 30, 30, 160, 60, 240, 240, 240]
        let space = CGColorSpace(indexedBaseSpace: CGColorSpace(name: CGColorSpace.sRGB)!, last: 3, colorTable: table)!
        let pixels = Data((0..<(width * height)).map { UInt8(($0 % width) * 4 / width) })
        let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: CGDataProvider(data: pixels as CFData)!, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }
    private static func alpha(_ image: CGImage, x: Int, y: Int) -> UInt8 {
        let data = image.dataProvider!.data! as Data
        let bytesPerPixel = image.bitsPerPixel / 8
        let offset = y * image.bytesPerRow + x * bytesPerPixel
        let alphaFirst = [.premultipliedFirst, .first].contains(image.alphaInfo)
        return data[offset + (alphaFirst ? 0 : bytesPerPixel - 1)]
    }
}
