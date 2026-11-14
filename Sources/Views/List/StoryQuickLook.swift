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
import Foundation
import QuickLookUI

extension Notification.Name {
    /// Posted by File › Quick Look to preview the focused story.
    static let quickLookCommand = Notification.Name("quickLookCommand")
    /// Posted by the Quick Look panel's Return key to open the focused story in the reader.
    static let openFocusedStoryCommand = Notification.Name("openFocusedStoryCommand")
}

/// Renders a one-page PDF preview from local text and the decoded image cache; it never fetches (#707).
@MainActor
enum StoryQuickLookRenderer {
    /// The text and image one preview page shows.
    struct RenderData {
        let title: String
        let publisher: String
        let dateText: String
        let excerpt: String
        /// The decoded card image, when it is already in the cache.
        var image: CGImage? = nil
    }

    private static let pageSize = CGSize(width: 600, height: 750)
    private static let margin = AppSpacing.xl
    private static var contentWidth: CGFloat { pageSize.width - margin * 2 }

    /// The preview's text: up to four paragraphs of the reader document without the headline, else the cleaned
    /// description, else the cleaned full content; empty when none has text.
    static func makeExcerpt(for article: FeedArticle) -> String {
        if let blocks = article.readerDocument?.blocks, !blocks.isEmpty {
            let paragraphs = blocks.compactMap { block -> String? in
                let stripped = FeedXMLParser.stripHTMLSimple(block.text).trimmingCharacters(in: .whitespacesAndNewlines)
                // A reader document often opens with the headline, which the page already shows.
                return stripped.isEmpty || stripped == article.title ? nil : stripped
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

    /// The preview's text and the first already-decoded image of the card or the feed; nothing is fetched.
    static func renderData(for article: FeedArticle) -> RenderData {
        // The card's image first, then the feed's own, whichever is already decoded.
        let imageURLs = [FeedArticle.bestCardImage(in: [article]), article.imageUrl.flatMap { URL(string: $0) }]
        return RenderData(
            title: article.title,
            publisher: article.publisherName,
            dateText: article.publicationDateText,
            excerpt: makeExcerpt(for: article),
            image: imageURLs.lazy.compactMap { $0 }.compactMap { DecodedImageCache.cached($0, size: .card) }.first
        )
    }

    /// Writes a one-page PDF of the preview to `fileURL` in the light or dark appearance; false when the file cannot be
    /// created.
    static func renderPDF(data: RenderData, to fileURL: URL, isDark: Bool = false) -> Bool {
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(url: fileURL as CFURL),
            let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            return false
        }

        context.beginPDFPage(nil)
        // `flipped: true` only tells AppKit the transform is flipped; flip it so layout runs top-down.
        context.translateBy(x: 0, y: pageSize.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        NSAppearance(named: isDark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            drawPage(data)
        }
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return true
    }

    private static func drawPage(_ data: RenderData) {
        let page = NSRect(origin: .zero, size: pageSize)
        NSColor.textBackgroundColor.setFill()
        page.fill()
        if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            NSColor.separatorColor.setStroke()
            NSBezierPath(rect: page.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }

        var top = margin
        top +=
            drawText(
                "\(data.publisher) • \(data.dateText)", font: font(.caption2, bold: true),
                color: .secondaryLabelColor, top: top, maxHeight: 40) + AppSpacing.xs
        top += drawText(data.title, font: font(.title1, bold: true), top: top, maxHeight: 100) + AppSpacing.md
        if let image = data.image {
            top += drawImage(image, top: top) + AppSpacing.md
        }

        let dividerY = pageSize.height - margin
        if !data.excerpt.isEmpty {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = AppSpacing.xxs
            paragraph.paragraphSpacing = AppSpacing.xs
            drawText(
                data.excerpt, font: font(.body), top: top, maxHeight: max(80, dividerY - AppSpacing.md - top),
                paragraph: paragraph)
        }

        NSColor.separatorColor.setFill()
        NSRect(x: margin, y: dividerY, width: contentWidth, height: 1).fill()
        drawText(
            "↵ Open in Reader   •   Space / ⎋ Close", font: font(.subheadline), color: .tertiaryLabelColor,
            top: dividerY + AppSpacing.xs, maxHeight: 20)
    }

    /// Draws text at the content width, truncated to `maxHeight`; returns the height it took.
    @discardableResult
    private static func drawText(
        _ text: String, font: NSFont, color: NSColor = .labelColor, top: CGFloat, maxHeight: CGFloat,
        paragraph: NSParagraphStyle = .default
    ) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
        ]
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine]
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: contentWidth, height: maxHeight), options: options, attributes: attributes)
        let height = min(maxHeight, ceil(bounds.height))
        (text as NSString).draw(
            with: NSRect(x: margin, y: top, width: contentWidth, height: height), options: options,
            attributes: attributes, context: nil)
        return height
    }

    /// Draws the lead image filling a rounded frame without stretching; returns the frame height.
    private static func drawImage(_ image: CGImage, top: CGFloat) -> CGFloat {
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(max(1, image.height))
        let frame = NSRect(
            x: margin, y: top, width: contentWidth,
            height: min(200, max(120, contentWidth / max(0.5, imageWidth / imageHeight))))
        let scale = max(frame.width / max(1, imageWidth), frame.height / imageHeight)
        let size = NSSize(width: imageWidth * scale, height: imageHeight * scale)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: frame, xRadius: AppRadius.card, yRadius: AppRadius.card).addClip()
        NSImage(cgImage: image, size: size).draw(
            in: NSRect(
                x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
        )
        NSGraphicsContext.restoreGraphicsState()
        return frame.height
    }

    private static func font(_ style: NSFont.TextStyle, bold: Bool = false) -> NSFont {
        let font = NSFont.preferredFont(forTextStyle: style)
        return bold ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
    }
}

/// The preview file and title the Quick Look panel shows.
final class StoryQuickLookPreviewItem: NSObject, QLPreviewItem, Sendable {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL, title: String) {
        self.previewItemURL = url
        self.previewItemTitle = title
        super.init()
    }
}

/// Owns the shared Quick Look panel and the one preview file it shows; Space, Esc, Return, arrows and J/K drive the
/// list while the panel is key.
@MainActor
final class StoryQuickLookCoordinator: NSObject, @preconcurrency QLPreviewPanelDataSource,
    @preconcurrency QLPreviewPanelDelegate
{
    static let shared = StoryQuickLookCoordinator()

    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "com.marspater.news.quicklook", isDirectory: true)
    private var currentItem: StoryQuickLookPreviewItem?

    private var isClosing = false

    /// Visible and not already animating out.
    var isOpen: Bool {
        !isClosing && QLPreviewPanel.sharedPreviewPanelExists() && (QLPreviewPanel.shared()?.isVisible ?? false)
    }

    var hasPreview: Bool { currentItem != nil }

    /// Called by the panel's controller (`AppDelegate`) when the panel asks for its data.
    func control(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
    }

    override private init() {
        super.init()
        // Previews left behind by a quit or crash go before the first new one.
        try? FileManager.default.removeItem(at: directory)
    }

    /// `isDark` is the list window's appearance: the app's theme sets it on the window, not on `NSApp`.
    func present(article: FeedArticle, isDark: Bool) {
        guard let panel = QLPreviewPanel.shared() else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString).pdf")
        guard
            StoryQuickLookRenderer.renderPDF(
                data: StoryQuickLookRenderer.renderData(for: article), to: url, isDark: isDark)
        else {
            // Never leave the previous story on screen as if it were this one.
            try? FileManager.default.removeItem(at: url)
            close()
            return
        }

        removeCurrentItem()
        currentItem = StoryQuickLookPreviewItem(url: url, title: article.title)
        panel.reloadData()
        if !panel.isVisible || isClosing {
            panel.makeKeyAndOrderFront(nil)
        }
        isClosing = false
    }

    /// Hides the panel. A second close while it animates out keeps it on screen, and opening a story from the panel
    /// closes it twice (the Return key, then the reader appearing), so only the first one counts. The preview file
    /// stays until the next preview replaces it, or the next launch.
    func close() {
        guard isOpen else { return }
        isClosing = true
        QLPreviewPanel.shared()?.close()
    }

    private func removeCurrentItem() {
        if let url = currentItem?.previewItemURL {
            try? FileManager.default.removeItem(at: url)
        }
        currentItem = nil
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in _: QLPreviewPanel!) -> Int {
        currentItem == nil ? 0 : 1
    }

    func previewPanel(_: QLPreviewPanel!, previewItemAt _: Int) -> (any QLPreviewItem)! {
        currentItem
    }

    // MARK: - QLPreviewPanelDelegate

    func previewPanel(_: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            return false
        }
        let character = event.charactersIgnoringModifiers
        switch event.keyCode {
        case 49, 53:  // Space, Esc
            close()
        case 36, 76:  // Return, Enter
            close()
            NotificationCenter.default.post(name: .openFocusedStoryCommand, object: nil)
        case 125:  // Down arrow
            NotificationCenter.default.post(name: .nextArticleCommand, object: nil)
        case 126:  // Up arrow
            NotificationCenter.default.post(name: .prevArticleCommand, object: nil)
        default:
            guard character == "j" || character == "k" else { return false }
            NotificationCenter.default.post(
                name: character == "j" ? .nextArticleCommand : .prevArticleCommand, object: nil)
        }
        return true
    }
}
