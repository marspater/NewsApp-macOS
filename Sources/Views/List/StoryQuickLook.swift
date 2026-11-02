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
import QuickLookUI

// MARK: - Notification Names

extension Notification.Name {
    static let quickLookCommand = Notification.Name("quickLookCommand")
    static let openFocusedStoryCommand = Notification.Name("openFocusedStoryCommand")
}

// MARK: - Navigation Index Mapping

/// Pure navigation index and identifier resolution for story lists and Quick Look cycling.
enum StoryQuickLookNavigation: Sendable {
    static func targetIndex(currentIndex: Int?, count: Int, offset: Int) -> Int? {
        guard count > 0 else { return nil }
        let current: Int
        if let currentIndex {
            current = currentIndex
        } else {
            current = offset > 0 ? -1 : count
        }
        return max(0, min(count - 1, current + offset))
    }

    static func targetID(currentID: String?, itemIDs: [String], offset: Int) -> String? {
        guard !itemIDs.isEmpty else { return nil }
        let currentIndex = currentID.flatMap { itemIDs.firstIndex(of: $0) }
        guard let targetIdx = targetIndex(currentIndex: currentIndex, count: itemIDs.count, offset: offset) else {
            return nil
        }
        return itemIDs[targetIdx]
    }
}

// MARK: - Preview Document Renderer

/// Renders a local, privacy-preserving preview document for Quick Look peek.
/// ZERO network calls: uses only local text and DecodedImageCache.
enum StoryQuickLookRenderer: Sendable {
    struct RenderData: Sendable {
        let title: String
        let publisher: String
        let dateText: String
        let excerpt: String
        let image: CGImage?

        init(
            title: String,
            publisher: String,
            dateText: String,
            excerpt: String,
            image: CGImage? = nil
        ) {
            self.title = title
            self.publisher = publisher
            self.dateText = dateText
            self.excerpt = excerpt
            self.image = image
        }
    }

    static func makeExcerpt(for article: FeedArticle) -> String {
        if let blocks = article.readerDocument?.blocks, !blocks.isEmpty {
            let paragraphs = blocks.compactMap { block -> String? in
                let stripped = FeedXMLParser.stripHTMLSimple(block.text).trimmingCharacters(in: .whitespacesAndNewlines)
                return stripped.isEmpty ? nil : stripped
            }
            if !paragraphs.isEmpty {
                return paragraphs.prefix(4).joined(separator: "\n\n")
            }
        }
        if !article.description.isEmpty {
            let stripped = FeedXMLParser.stripHTMLSimple(article.description)
            let cleaned = ArticleContentRedactor.cleanText(stripped)
            if !cleaned.isEmpty { return cleaned }
        }
        if let full = article.fullContent, !full.isEmpty {
            let stripped = FeedXMLParser.stripHTMLSimple(full)
            let cleaned = ArticleContentRedactor.cleanText(stripped)
            if !cleaned.isEmpty { return cleaned }
        }
        return ""
    }

    @MainActor
    static func renderData(for article: FeedArticle) -> RenderData {
        let excerpt = makeExcerpt(for: article)
        var cachedImage: CGImage? = nil
        let targetURL =
            FeedArticle.bestCardImage(in: [article])
            ?? article.imageUrl.flatMap { URL(string: $0) }
        if let targetURL {
            cachedImage = DecodedImageCache.images.object(forKey: targetURL as NSURL)
        }
        return RenderData(
            title: article.title,
            publisher: article.publisherName,
            dateText: article.publicationDateText,
            excerpt: excerpt,
            image: cachedImage
        )
    }

    /// Renders an offscreen single-page PDF containing exclusively local article content.
    @MainActor
    static func renderPDF(data: RenderData, to fileURL: URL, isDark: Bool = false) -> Bool {
        let pageWidth: CGFloat = 600
        let pageHeight: CGFloat = 750
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        guard let consumer = CGDataConsumer(url: fileURL as CFURL),
            let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            return false
        }

        context.beginPDFPage(nil)
        let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext

        let appearance = NSApp?.effectiveAppearance ?? NSAppearance(named: isDark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance {
            // Background fill
            let bgColor =
                isDark
                ? NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.13, alpha: 1.0)
                : NSColor(calibratedRed: 0.98, green: 0.98, blue: 0.99, alpha: 1.0)
            bgColor.setFill()
            NSRect(x: 0, y: 0, width: pageWidth, height: pageHeight).fill()

            // Outer border for high contrast
            if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
                NSColor.separatorColor.setStroke()
                let borderPath = NSBezierPath(
                    rect: NSRect(x: 0.5, y: 0.5, width: pageWidth - 1, height: pageHeight - 1))
                borderPath.lineWidth = 1
                borderPath.stroke()
            }

            let margin: CGFloat = 44
            let contentWidth = pageWidth - (margin * 2)
            var currentY: CGFloat = 40

            // 1. Eyebrow: Publisher • Date
            let eyebrowText = "\(data.publisher) • \(data.dateText)"
            let eyebrowAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            (eyebrowText as NSString).draw(
                in: NSRect(x: margin, y: currentY, width: contentWidth, height: 18),
                withAttributes: eyebrowAttrs
            )
            currentY += 26

            // 2. Headline
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 22, weight: .bold),
                .foregroundColor: NSColor.labelColor,
            ]
            let titleBounding = (data.title as NSString).boundingRect(
                with: NSSize(width: contentWidth, height: 100),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: titleAttrs
            )
            (data.title as NSString).draw(
                in: NSRect(x: margin, y: currentY, width: contentWidth, height: ceil(titleBounding.height)),
                withAttributes: titleAttrs
            )
            currentY += ceil(titleBounding.height) + 16

            // 3. Lead Image (if locally cached in DecodedImageCache)
            if let image = data.image {
                let imgWidth = contentWidth
                let aspectRatio = CGFloat(image.width) / CGFloat(max(1, image.height))
                let imgHeight = min(200, max(120, imgWidth / max(0.5, aspectRatio)))
                let imgRect = NSRect(x: margin, y: currentY, width: imgWidth, height: imgHeight)

                NSGraphicsContext.saveGraphicsState()
                let clipPath = NSBezierPath(roundedRect: imgRect, xRadius: 8, yRadius: 8)
                clipPath.addClip()
                let nsImage = NSImage(cgImage: image, size: imgRect.size)
                nsImage.draw(in: imgRect)
                NSGraphicsContext.restoreGraphicsState()

                currentY += imgHeight + 16
            }

            // 4. Body excerpt
            if !data.excerpt.isEmpty {
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.lineSpacing = 4
                paragraphStyle.paragraphSpacing = 10
                let bodyAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 14, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraphStyle,
                ]
                let remainingHeight = max(80, pageHeight - currentY - 54)
                (data.excerpt as NSString).draw(
                    in: NSRect(x: margin, y: currentY, width: contentWidth, height: remainingHeight),
                    withAttributes: bodyAttrs
                )
            }

            // 5. Divider and footer prompt
            let dividerY = pageHeight - 44
            NSColor.separatorColor.setFill()
            NSRect(x: margin, y: dividerY, width: contentWidth, height: 1).fill()

            let footerText = "↵ Open in Reader   •   Space / ⎋ Close"
            let footerAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            (footerText as NSString).draw(
                in: NSRect(x: margin, y: dividerY + 10, width: contentWidth, height: 18),
                withAttributes: footerAttrs
            )
        }

        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()

        return true
    }
}

// MARK: - Quick Look Preview Item

final class StoryQuickLookPreviewItem: NSObject, QLPreviewItem, Sendable {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL, title: String) {
        self.previewItemURL = url
        self.previewItemTitle = title
        super.init()
    }
}

// MARK: - Quick Look Coordinator

@MainActor
final class StoryQuickLookCoordinator: NSObject, @preconcurrency QLPreviewPanelDataSource,
    @preconcurrency QLPreviewPanelDelegate
{
    static let shared = StoryQuickLookCoordinator()

    private var currentItem: StoryQuickLookPreviewItem?
    private var currentTempURL: URL?
    private var closeObserver: (any NSObjectProtocol)?

    var isOpen: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && (QLPreviewPanel.shared()?.isVisible ?? false)
    }

    override private init() {
        super.init()
    }

    deinit {
        if let url = currentTempURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func present(article: FeedArticle) {
        let renderData = StoryQuickLookRenderer.renderData(for: article)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "com.marspater.news.quicklook", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let newURL = tempDir.appendingPathComponent("\(UUID().uuidString).pdf")

        let appearance = NSApp?.effectiveAppearance ?? NSAppearance(named: .aqua)!
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard StoryQuickLookRenderer.renderPDF(data: renderData, to: newURL, isDark: isDark) else {
            return
        }

        cleanupCurrentTempFile()
        currentTempURL = newURL
        currentItem = StoryQuickLookPreviewItem(url: newURL, title: article.title)

        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()

        registerCloseObserver(for: panel)

        if !panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func toggle(for article: FeedArticle) {
        if isOpen {
            close()
        } else {
            present(article: article)
        }
    }

    func close() {
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
        }
        cleanupCurrentTempFile()
        currentItem = nil
        unregisterCloseObserver()
    }

    private func cleanupCurrentTempFile() {
        if let url = currentTempURL {
            try? FileManager.default.removeItem(at: url)
            currentTempURL = nil
        }
    }

    private func registerCloseObserver(for panel: QLPreviewPanel) {
        unregisterCloseObserver()
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cleanupCurrentTempFile()
                self?.currentItem = nil
                self?.unregisterCloseObserver()
            }
        }
    }

    private func unregisterCloseObserver() {
        if let observer = closeObserver {
            NotificationCenter.default.removeObserver(observer)
            closeObserver = nil
        }
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        return currentItem == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        return currentItem
    }

    // MARK: - QLPreviewPanelDelegate

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard modifiers.isEmpty else { return false }

        switch event.keyCode {
        case 49:  // Space
            close()
            return true
        case 53:  // Esc
            close()
            return true
        case 36, 76:  // Return / Enter
            close()
            NotificationCenter.default.post(name: .openFocusedStoryCommand, object: nil)
            return true
        case 125:  // Down arrow
            NotificationCenter.default.post(name: .nextArticleCommand, object: nil)
            return true
        case 126:  // Up arrow
            NotificationCenter.default.post(name: .prevArticleCommand, object: nil)
            return true
        default:
            if event.charactersIgnoringModifiers == "j" {
                NotificationCenter.default.post(name: .nextArticleCommand, object: nil)
                return true
            } else if event.charactersIgnoringModifiers == "k" {
                NotificationCenter.default.post(name: .prevArticleCommand, object: nil)
                return true
            }
            return false
        }
    }
}
