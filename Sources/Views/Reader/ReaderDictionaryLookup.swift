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

/// Controller for system dictionary Look Up popover in reader and event overview (Issue #1207).
@MainActor
enum ReaderDictionaryLookup {
    /// Formats the context menu item label for a given text selection or word.
    static func lookupTitle(for text: String?) -> String {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return "Look Up"
        }
        if text.count <= 25 {
            return "Look Up “\(text)”"
        } else {
            return "Look Up “\(text.prefix(20))…”"
        }
    }

    /// Extracts the word under the given point in a text container laid out with the given font.
    static func word(
        at point: NSPoint,
        in text: String,
        lineSpacing: CGFloat = 0,
        font: NSFont = NSFont.systemFont(ofSize: 14),
        containerSize: NSSize
    ) -> String? {
        guard !text.isEmpty, containerSize.width > 0, containerSize.height > 0 else { return nil }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let textStorage = NSTextStorage(string: text, attributes: [.font: font, .paragraphStyle: paragraph])
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: containerSize)
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        let charIndex = layoutManager.characterIndex(
            for: point, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
        guard charIndex >= 0 && charIndex < text.utf16.count else { return nil }

        return word(at: charIndex, in: text)
    }

    /// Extracts the word around a character index in a string.
    static func word(at charIndex: Int, in string: String) -> String? {
        guard charIndex >= 0 && charIndex < string.utf16.count else { return nil }
        var foundWord: String?
        string.enumerateSubstrings(in: string.startIndex..<string.endIndex, options: [.byWords, .substringNotRequired])
        { _, range, _, stop in
            let nsRange = NSRange(range, in: string)
            if nsRange.contains(charIndex) {
                foundWord = String(string[range])
                stop = true
            }
        }
        return foundWord
    }

    /// Presents the system Look Up popover for the given string at the specified point (or mouse location).
    static func showDefinition(for text: String, at point: NSPoint? = nil, in targetView: NSView? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let window = targetView?.window ?? NSApp.keyWindow
        guard let window else { return }
        let view = targetView ?? window.contentView
        guard let view else { return }

        let baselinePoint: NSPoint
        if let point {
            baselinePoint = point
        } else {
            let screenPoint = NSEvent.mouseLocation
            let windowPoint = window.convertPoint(fromScreen: screenPoint)
            baselinePoint = view.convert(windowPoint, from: nil)
        }

        let attrString = NSAttributedString(string: trimmed)
        view.showDefinition(for: attrString, at: baselinePoint)
    }

    /// Triggers dictionary lookup for selected text or word under point within a view.
    static func performLookup(
        for fallbackText: String,
        lineSpacing: CGFloat = 0,
        font: NSFont = NSFont.systemFont(ofSize: 14),
        at pointInView: NSPoint? = nil,
        in view: NSView? = nil
    ) {
        if let selection = ReaderSelection.current(), !selection.isEmpty {
            showDefinition(for: selection, at: pointInView, in: view)
            return
        }

        let targetView = view ?? NSApp.keyWindow?.contentView
        guard let targetView else { return }

        let localPoint: NSPoint
        if let pointInView {
            localPoint = pointInView
        } else if let window = targetView.window {
            let screenPoint = NSEvent.mouseLocation
            let windowPoint = window.convertPoint(fromScreen: screenPoint)
            localPoint = targetView.convert(windowPoint, from: nil)
        } else {
            localPoint = .zero
        }

        if let word = word(
            at: localPoint, in: fallbackText, lineSpacing: lineSpacing, font: font,
            containerSize: targetView.bounds.size)
        {
            showDefinition(for: word, at: localPoint, in: targetView)
        } else {
            showDefinition(for: fallbackText, at: localPoint, in: targetView)
        }
    }
}

/// System fonts that match the SwiftUI reader faces, so word hit-testing lays text out like the rendered block.
extension ReaderDictionaryLookup {
    static func font(
        size: CGFloat, weight: NSFont.Weight = .regular, design: NSFontDescriptor.SystemDesign = .default,
        italic: Bool = false
    ) -> NSFont {
        var font = NSFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = font.fontDescriptor.withDesign(design),
            let styled = NSFont(descriptor: descriptor, size: size)
        {
            font = styled
        }
        return italic ? NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) : font
    }

    static func bodyFont(for theme: ArticleThemeType, scale: CGFloat, italic: Bool = false) -> NSFont {
        font(
            size: AppTypography.bodySize(for: theme) * scale, design: theme == .casper ? .serif : .default,
            italic: italic)
    }

    static func leadFont(for theme: ArticleThemeType, scale: CGFloat, italic: Bool = false) -> NSFont {
        switch theme {
        case .casper: return font(size: 20 * scale, design: .serif, italic: italic)
        case .edition: return font(size: 18 * scale, italic: italic)
        case .alto: return font(size: 16 * scale, weight: .medium, design: .monospaced, italic: italic)
        }
    }

    static func headingFont(level: Int, theme: ArticleThemeType, scale: CGFloat) -> NSFont {
        let design: NSFontDescriptor.SystemDesign =
            theme == .casper ? .serif : (theme == .alto ? .monospaced : .default)
        return font(
            size: AppTypography.readerHeadingSize(level: level, theme: theme) * scale,
            weight: level <= 2 ? .bold : .semibold, design: design)
    }

    static func codeFont(for theme: ArticleThemeType, scale: CGFloat) -> NSFont {
        font(size: (AppTypography.bodySize(for: theme) * 0.85).rounded() * scale, design: .monospaced)
    }

    static func overviewFont(_ role: OverviewTextRole, scale: CGFloat) -> NSFont {
        let weight: NSFont.Weight
        switch role {
        case .title, .section, .subheading: weight = .bold
        case .emphasis, .eyebrow, .micro: weight = .semibold
        case .bodyMedium, .metadata, .annotation, .captionMedium: weight = .medium
        case .introduction, .fact, .body, .caption: weight = .regular
        }
        return font(
            size: AppTypography.overviewSize(role) * scale, weight: weight, design: role == .title ? .serif : .default)
    }
}

@MainActor
final class LookUpBridgeCoordinator {
    weak var view: ForceClickMonitorView?
}

/// Attaches dictionary Look Up via force click, long press, context menu, and ⌃⌘D (Issue #1207).
struct ReaderLookUpModifier: ViewModifier {
    let text: String
    var lineSpacing: CGFloat = 0
    var font: NSFont = NSFont.systemFont(ofSize: 14)
    @State private var coordinator = LookUpBridgeCoordinator()

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5)
                    .onEnded { _ in
                        triggerLookup()
                    }
            )
            .contextMenu {
                Button {
                    triggerLookup()
                } label: {
                    Label(
                        ReaderDictionaryLookup.lookupTitle(for: ReaderSelection.current()),
                        systemImage: "character.book.closed")
                }
                .keyboardShortcut("d", modifiers: [.control, .command])
            }
            .background {
                ReaderForceClickBridge(text: text, lineSpacing: lineSpacing, font: font, coordinator: coordinator)
                    .accessibilityHidden(true)
            }
    }

    private func triggerLookup() {
        ReaderDictionaryLookup.performLookup(
            for: text,
            lineSpacing: lineSpacing,
            font: font,
            in: coordinator.view
        )
    }
}

struct ReaderForceClickBridge: NSViewRepresentable {
    let text: String
    let lineSpacing: CGFloat
    let font: NSFont
    let coordinator: LookUpBridgeCoordinator

    func makeNSView(context _: Context) -> ForceClickMonitorView {
        let view = ForceClickMonitorView()
        view.text = text
        view.font = font
        view.lineSpacing = lineSpacing
        coordinator.view = view
        return view
    }

    func updateNSView(_ nsView: ForceClickMonitorView, context _: Context) {
        nsView.text = text
        nsView.font = font
        nsView.lineSpacing = lineSpacing
        coordinator.view = nsView
    }
}

final class ForceClickMonitorView: NSView {
    var text: String = ""
    var lineSpacing: CGFloat = 0
    var font: NSFont = NSFont.systemFont(ofSize: 14)
    nonisolated(unsafe) private var monitor: Any?
    /// One force click is one lookup: pressure keeps reporting stage 2 while the button stays down.
    private var forceClickLatched = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.pressure]) { [weak self] event in
                guard let self = self, let window = self.window, event.window == window else { return event }
                if event.stage < 2 { self.forceClickLatched = false }
                if event.stage == 2, !self.forceClickLatched {
                    let pointInView = self.convert(event.locationInWindow, from: nil)
                    if self.bounds.contains(pointInView) {
                        self.forceClickLatched = true
                        self.triggerForceClick(at: pointInView)
                    }
                }
                return event
            }
        } else if window == nil, let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func triggerForceClick(at point: NSPoint) {
        ReaderDictionaryLookup.performLookup(for: text, lineSpacing: lineSpacing, font: font, at: point, in: self)
    }

    /// The text system measures from the top-left, so points in this view must too.
    override var isFlipped: Bool { true }

    override func hitTest(_: NSPoint) -> NSView? {
        // Return nil so mouse clicks, selections, link activations pass straight through to SwiftUI Text
        nil
    }
}

extension View {
    /// Enables system dictionary Look Up on word via force click, long press, context menu, and ⌃⌘D.
    func readerLookUp(text: String, lineSpacing: CGFloat = 0, font: NSFont = NSFont.systemFont(ofSize: 14))
        -> some View
    {
        modifier(ReaderLookUpModifier(text: text, lineSpacing: lineSpacing, font: font))
    }
}
