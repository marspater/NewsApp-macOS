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
        font: NSFont = NSFont.systemFont(ofSize: 14),
        containerSize: NSSize
    ) -> String? {
        guard !text.isEmpty, containerSize.width > 0, containerSize.height > 0 else { return nil }
        let textStorage = NSTextStorage(string: text, attributes: [.font: font])
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: containerSize)
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        let charIndex = layoutManager.characterIndex(
            for: point, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
        guard charIndex >= 0 && charIndex < text.count else { return nil }

        return word(at: charIndex, in: text)
    }

    /// Extracts the word around a character index in a string.
    static func word(at charIndex: Int, in string: String) -> String? {
        guard charIndex >= 0 && charIndex < string.count else { return nil }
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
}

/// Attaches dictionary Look Up via force click, long press, context menu, and ⌃⌘D (Issue #1207).
struct ReaderLookUpModifier: ViewModifier {
    let text: String
    var font: NSFont = NSFont.systemFont(ofSize: 14)

    init(text: String, font: NSFont = NSFont.systemFont(ofSize: 14)) {
        self.text = text
        self.font = font
    }

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
                ReaderForceClickBridge(text: text, font: font)
                    .accessibilityHidden(true)
            }
    }

    private func triggerLookup() {
        if let selection = ReaderSelection.current(), !selection.isEmpty {
            ReaderDictionaryLookup.showDefinition(for: selection)
        } else {
            let screenPoint = NSEvent.mouseLocation
            if let window = NSApp.keyWindow, let contentView = window.contentView {
                let windowPoint = window.convertPoint(fromScreen: screenPoint)
                let viewPoint = contentView.convert(windowPoint, from: nil)
                if let w = ReaderDictionaryLookup.word(
                    at: viewPoint, in: text, font: font, containerSize: contentView.bounds.size)
                {
                    ReaderDictionaryLookup.showDefinition(for: w, at: viewPoint, in: contentView)
                } else {
                    ReaderDictionaryLookup.showDefinition(for: text, at: viewPoint, in: contentView)
                }
            }
        }
    }
}

struct ReaderForceClickBridge: NSViewRepresentable {
    let text: String
    let font: NSFont

    init(text: String, font: NSFont) {
        self.text = text
        self.font = font
    }

    func makeNSView(context: Context) -> ForceClickMonitorView {
        let view = ForceClickMonitorView()
        view.text = text
        view.font = font
        return view
    }

    func updateNSView(_ nsView: ForceClickMonitorView, context: Context) {
        nsView.text = text
        nsView.font = font
    }
}

final class ForceClickMonitorView: NSView {
    var text: String = ""
    var font: NSFont = NSFont.systemFont(ofSize: 14)
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.pressure]) { [weak self] event in
                guard let self = self, let window = self.window, event.window == window else { return event }
                if event.stage == 2 {
                    let pointInView = self.convert(event.locationInWindow, from: nil)
                    if self.bounds.contains(pointInView) {
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
        if let selection = ReaderSelection.current(), !selection.isEmpty {
            ReaderDictionaryLookup.showDefinition(for: selection, at: point, in: self)
        } else if let word = ReaderDictionaryLookup.word(at: point, in: text, font: font, containerSize: bounds.size) {
            ReaderDictionaryLookup.showDefinition(for: word, at: point, in: self)
        } else {
            ReaderDictionaryLookup.showDefinition(for: text, at: point, in: self)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Return nil so mouse clicks, selections, link activations pass straight through to SwiftUI Text
        return nil
    }
}

extension View {
    /// Enables system dictionary Look Up on word via force click, long press, context menu, and ⌃⌘D.
    func readerLookUp(text: String, font: NSFont = NSFont.systemFont(ofSize: 14)) -> some View {
        modifier(ReaderLookUpModifier(text: text, font: font))
    }
}
