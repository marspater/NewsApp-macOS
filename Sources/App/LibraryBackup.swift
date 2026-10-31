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
import UniformTypeIdentifiers

/// Library backup and restore (#563). A type of its own, not part of the app entry point, so the Settings view that
/// offers them compiles in harnesses that replace `NewsApp`.
enum LibraryBackup {
    private static var backupType: UTType { UTType(filenameExtension: "sqlite3") ?? .data }

    @MainActor static func backUpLibrary() {
        let panel = NSSavePanel()
        panel.title = "Back Up Library"
        panel.prompt = "Back Up"
        panel.nameFieldStringValue = "News Backup \(Date().formatted(.iso8601.year().month().day())).sqlite3"
        panel.allowedContentTypes = [backupType]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            do {
                let settings = try AppSettings.backupSettings(from: .standard)
                try await DatabaseEngine.shared.writeBackup(to: url, settings: settings)
                showAlert("Library backed up")
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    @MainActor static func restoreLibrary() {
        let panel = NSOpenPanel()
        panel.title = "Restore Library"
        panel.prompt = "Restore"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [backupType]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let confirm = NSAlert()
        confirm.messageText = "Replace your library with this backup?"
        confirm.informativeText =
            "Your current stories, read history and saved stories are replaced by the backup's, and your settings too if the backup includes them. The current library is kept beside it, then News relaunches."
        confirm.addButton(withTitle: "Restore")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor in
            let settings: Data?
            do {
                settings = try await DatabaseEngine.shared.restoreBackup(from: url)
            } catch {
                // A refused or failed restore leaves the library open and unchanged.
                NSAlert(error: error).runModal()
                return
            }
            if let settings, (try? AppSettings.restoreSettings(settings, to: .standard)) == nil {
                showAlert("The library was restored, but the backup's settings couldn't be read.")
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { app, error in
                let launched = app != nil && error == nil
                Task { @MainActor in
                    // This instance quits only once the new one is running, so News never just disappears.
                    guard launched else {
                        return showAlert("The library was restored. Quit and reopen News to use it.")
                    }
                    NSApp.terminate(nil)
                }
            }
        }
    }

    @MainActor private static func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }
}
