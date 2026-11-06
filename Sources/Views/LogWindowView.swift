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

/// The development Log window (#1005): this launch's entries for the app's subsystem, read through
/// `DiagnosticsExport.logLines(since:)`, with level, category and text filters. Present only in the development bundle
/// that `make run` builds; values stay as the log redacts them.
@MainActor
final class LogWindowModel: ObservableObject {
    struct Entry: Identifiable, Equatable {
        let id: Int
        let line: DiagnosticsExport.LogLine
    }

    nonisolated static let windowID = "log"
    nonisolated static let developmentBundleIdentifier = "com.marspater.news.dev"
    // ponytail: the newest 5,000 lines stay; a longer launch is what Export Diagnostics is for.
    static let maximumEntries = 5_000

    nonisolated static func isAvailable(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == developmentBundleIdentifier
    }

    nonisolated static var isAvailable: Bool { isAvailable(bundleIdentifier: Bundle.main.bundleIdentifier) }

    @Published private(set) var entries: [Entry] = []
    @Published var level: String?
    @Published var category: String?
    @Published var search = ""
    /// Follows new lines until the person scrolls up, and again once they scroll back to the end or clear the view.
    @Published var follows = true
    private var readThrough = Date.distantPast
    private var nextID = 0

    var visible: [Entry] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return entries.filter { entry in
            (level == nil || entry.line.level == level) && (category == nil || entry.line.category == category)
                && (query.isEmpty || entry.line.message.localizedCaseInsensitiveContains(query)
                    || entry.line.category.localizedCaseInsensitiveContains(query))
        }
    }

    var categories: [String] { Set(entries.map(\.line.category) + [category].compactMap { $0 }).sorted() }

    var visibleText: String { visible.map { Self.text(of: $0.line) }.joined(separator: "\n") }

    static func text(of line: DiagnosticsExport.LogLine) -> String {
        let time = line.date.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3)))
        return "\(time) \(line.level) \(line.category): \(line.message)"
    }

    /// Appends lines newer than the last one read, oldest first, keeping the newest `maximumEntries`.
    func append(_ lines: [DiagnosticsExport.LogLine]) {
        // ponytail: a reread starts at the last line's time, so lines of that same instant written after the read
        // are skipped; a sequence position in the store would keep them if that ever matters.
        let new = lines.filter { $0.date > readThrough }
        guard let last = new.last else { return }
        readThrough = last.date
        entries += new.map { line in
            defer { nextID += 1 }
            return Entry(id: nextID, line: line)
        }
        if entries.count > Self.maximumEntries { entries.removeFirst(entries.count - Self.maximumEntries) }
    }

    /// Hides what was shown so far; later lines keep arriving. An empty view has nothing to scroll back from.
    func clear() {
        entries.removeAll()
        follows = true
    }

    func refresh() async {
        let start = readThrough
        let lines = try? await Task.detached(priority: .utility) { try DiagnosticsExport.logLines(since: start) }.value
        append(lines ?? [])
    }

    func copyVisible() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(visibleText, forType: .string)
    }
}

struct LogWindowView: View {
    @StateObject private var model = LogWindowModel()

    var body: some View {
        let visible = model.visible
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppSpacing.textStack) {
                    ForEach(visible) { entry in
                        Text(LogWindowModel.text(of: entry.line))
                            .font(AppTypography.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(entry.id)
                    }
                }
                .padding(AppSpacing.sm)
            }
            .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { old, new in
                // New lines grow the content; only the person's own scrolling decides whether the view follows.
                guard old.contentSize == new.contentSize else { return }
                model.follows = new.contentOffset.y + new.containerSize.height >= new.contentSize.height - AppSpacing.xs
            }
            .onChange(of: visible.last?.id) { _, last in
                if model.follows, let last { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
        // Edit › Copy Log and Clear Log act on the Log window in front (DESIGN.md 5: every toolbar action has a command).
        .focusedSceneObject(model)
        .overlay {
            if visible.isEmpty {
                if model.search.isEmpty {
                    ContentUnavailableView(
                        "No Log Entries", systemImage: "list.bullet.rectangle",
                        description: Text("Lines this launch writes appear here."))
                } else {
                    ContentUnavailableView.search(text: model.search)
                }
            }
        }
        .navigationTitle("Log")
        .searchable(text: $model.search, placement: .toolbar)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Picker("Level", selection: $model.level) {
                    Text("All Levels").tag(String?.none)
                    ForEach(DiagnosticsExport.levels, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .help("Show one level")
                Picker("Category", selection: $model.category) {
                    Text("All Categories").tag(String?.none)
                    ForEach(model.categories, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .help("Show one category")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Copy", systemImage: "doc.on.doc") { model.copyVisible() }
                    .help("Copy the visible lines")
                    .disabled(visible.isEmpty)
                Button("Clear", systemImage: "eraser") { model.clear() }
                    .help("Hide the lines shown so far")
                    .disabled(model.entries.isEmpty)
            }
        }
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
