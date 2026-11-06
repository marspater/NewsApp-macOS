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

/// Synthetic, isolated rendering of the production export menu; no library or settings are opened.
/// NEWS_NATIVE_HARNESS=Tests/Harness/NativeKnowledgeExport.swift script/native_performance_baseline.sh OUTPUT
@main struct NativeKnowledgeExport {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let app = NSApplication.shared
        let delegate = KnowledgeExportQADelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor private final class KnowledgeExportQADelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let root = NSMenu()
        let app = NSMenuItem()
        app.submenu = NSMenu(title: "Knowledge QA")
        app.submenu?.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        root.addItem(app)
        let export = NSMenuItem(title: "Export", action: nil, keyEquivalent: "")
        export.submenu = NSMenu(title: "Export")
        let notes = NSMenuItem(title: "Add to Apple Notes…", action: #selector(showNotes), keyEquivalent: "")
        notes.target = self
        export.submenu?.addItem(notes)
        root.addItem(export)
        NSApp.mainMenu = root
        Task {
            do {
                try await run()
                if ProcessInfo.processInfo.environment["NEWS_EXPORT_INTERACTIVE"] != "1" {
                    NSApplication.shared.terminate(nil)
                }
            } catch {
                fputs("Knowledge export QA failed: \(error)\n", stderr)
                exit(1)
            }
        }
    }

    @objc private func showNotes() {
        let document = KnowledgeExportDocument(
            id: "qa", title: "Fictional knowledge export QA",
            publisher: "Example Publisher", url: "https://example.com/story", published: nil,
            body: "A fictional offline story for format verification.", tags: [],
            quotes: [
                KnowledgeExportQuote(
                    text: "A qualified fictional quotation.", publisher: "Second Publisher",
                    url: "https://example.org/report")
            ],
            notes: [
                UserNote(
                    articleID: "qa", paragraphIndex: 0, charStart: 0, selectedText: "Fictional highlight", prefix: "",
                    suffix: "", noteBody: "Fictional private note")
            ])
        do { try KnowledgeExportUI.shareToNotes([document], title: "Fictional knowledge export QA") } catch {
            fputs("Notes preview failed: \(error)\n", stderr)
        }
    }

    private func run() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let actions = KnowledgeExportActions(
            markdown: { print("ACTION_MARKDOWN") }, epub: { print("ACTION_EPUB") },
            notes: {
                let service = NSSharingService(named: NSSharingService.Name("com.apple.Notes.SharingExtension"))
                let rich = KnowledgeExportUI.richText(
                    [
                        KnowledgeExportDocument(
                            id: "qa", title: "Fictional knowledge export QA", publisher: "Example Publisher",
                            url: "https://example.com/story", published: nil,
                            body: "A fictional offline story for format verification.", tags: [], quotes: [], notes: [])
                    ], title: "Fictional knowledge export QA")
                service?.perform(withItems: [rich])
            })
        let appearances: [(String, NSAppearance.Name, ColorSchemeContrast, Bool)] = [
            ("light", .aqua, .standard, false), ("dark", .darkAqua, .standard, false),
            ("high-contrast-light", .accessibilityHighContrastAqua, .increased, false),
            ("high-contrast-dark", .accessibilityHighContrastDarkAqua, .increased, false),
            ("reduce-motion", .aqua, .standard, true),
        ]
        for width in [900, 1400] {
            for (name, appearance, contrast, motion) in appearances {
                let root = VStack(alignment: .leading, spacing: AppLayout.cardGap) {
                    HStack {
                        Text("Fictional story").font(.title)
                        Spacer()
                        KnowledgeExportMenu(actions: actions)
                    }
                    Text("A synthetic article for export menu appearance and accessibility review.")
                    Spacer()
                }
                .padding(AppLayout.pageInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(AppColor.background)
                .environment(\._colorSchemeContrast, contrast)
                .environment(\.overrideContrast, contrast)
                .environment(\.overrideReduceMotion, motion)
                let host = NSHostingView(rootView: root)
                let current = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
                    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                current.isReleasedWhenClosed = false
                current.appearance = NSAppearance(named: appearance)
                current.contentView = host
                current.title = "Isolated export menu QA"
                current.center()
                current.makeKeyAndOrderFront(nil)
                window?.close()
                window = current
                NSApplication.shared.activate()
                try await Task.sleep(for: .milliseconds(300))
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw Failure.render }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure.render }
                try png.write(to: output.appendingPathComponent("export-\(width)-\(name).png"))
                print("CAPTURE \(width) \(name): \(host.bounds)")
            }
        }
        let service = NSSharingService(named: NSSharingService.Name("com.apple.Notes.SharingExtension"))
        let canShare = service?.canPerform(withItems: [NSAttributedString(string: "Fictional export QA")]) ?? false
        print("NOTES_SERVICE_CAN_PERFORM=\(canShare)")
        print(
            "MANUAL: inspect menu accessibility label, keyboard focus and each action; captures show closed menu only.")
        print("LIMITATION: Reduce Transparency is the host setting and was not simulated; no Notes compose was opened.")
        if ProcessInfo.processInfo.environment["NEWS_EXPORT_INTERACTIVE"] != "1" { window?.close() }
    }
    private enum Failure: Error { case render }
}
