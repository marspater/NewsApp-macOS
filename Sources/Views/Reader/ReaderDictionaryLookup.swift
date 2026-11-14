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
    /// Do not query selection in a menu label: SwiftUI rebuilds it for every reader text block (#1311).
    static let contextMenuTitle = "Look Up"

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
    /// The system font of the size, weight and design, made italic when asked.
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

    /// The body face of the reading style at the text scale: serif for Casper, the system face otherwise.
    static func bodyFont(for theme: ArticleThemeType, scale: CGFloat, italic: Bool = false) -> NSFont {
        font(
            size: AppTypography.bodySize(for: theme) * scale, design: theme == .casper ? .serif : .default,
            italic: italic)
    }

    /// The lead paragraph's face of the reading style at the text scale.
    static func leadFont(for theme: ArticleThemeType, scale: CGFloat, italic: Bool = false) -> NSFont {
        switch theme {
        case .casper: return font(size: 20 * scale, design: .serif, italic: italic)
        case .edition: return font(size: 18 * scale, italic: italic)
        case .alto: return font(size: 16 * scale, weight: .medium, design: .monospaced, italic: italic)
        }
    }

    /// A heading's face of the reading style: bold for levels 1 and 2, semibold below.
    static func headingFont(level: Int, theme: ArticleThemeType, scale: CGFloat) -> NSFont {
        let design: NSFontDescriptor.SystemDesign =
            theme == .casper ? .serif : (theme == .alto ? .monospaced : .default)
        return font(
            size: AppTypography.readerHeadingSize(level: level, theme: theme) * scale,
            weight: level <= 2 ? .bold : .semibold, design: design)
    }

    /// The code face: monospaced at 85% of the body size, rounded, then scaled.
    static func codeFont(for theme: ArticleThemeType, scale: CGFloat) -> NSFont {
        font(size: (AppTypography.bodySize(for: theme) * 0.85).rounded() * scale, design: .monospaced)
    }

    /// The event overview's face for a text role at the text scale; only the title is serif.
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

/// Holds the force-click view behind a block, so the long press and the context menu look up in the same view.
@MainActor
final class LookUpBridgeCoordinator {
    /// The block's force-click view; nil until it is made.
    weak var view: ForceClickMonitorView?
}

/// Attaches dictionary Look Up via force click, long press, context menu, and ⌃⌘D (Issue #1207).
struct ReaderLookUpModifier: ViewModifier {
    /// The block's text, in which the word is looked up.
    let text: String
    /// The block's line spacing, for laying the text out as it is drawn.
    var lineSpacing: CGFloat = 0
    /// The block's font, for laying the text out as it is drawn.
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
                        ReaderDictionaryLookup.contextMenuTitle,
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

/// The invisible view behind a reader block that watches for a force click and gives the lookup a view to show in.
struct ReaderForceClickBridge: NSViewRepresentable {
    /// The block's text.
    let text: String
    /// The block's line spacing.
    let lineSpacing: CGFloat
    /// The block's font.
    let font: NSFont
    /// Receives the view, for the modifier's other lookup paths.
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

/// Looks up the word under a force click, once per press, without taking any clicks from the text above it.
final class ForceClickMonitorView: NSView {
    /// The block's text.
    var text: String = ""
    /// The block's line spacing.
    var lineSpacing: CGFloat = 0
    /// The block's font.
    var font: NSFont = NSFont.systemFont(ofSize: 14)
    nonisolated(unsafe) private var monitor: Any?
    /// One force click is one lookup: pressure keeps reporting stage 2 while the button stays down.
    private var forceClickLatched = false

    /// Starts watching pressure events while the view is in a window and stops when it leaves.
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

    /// Returns nil, so clicks, selections and links reach the SwiftUI text above.
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
