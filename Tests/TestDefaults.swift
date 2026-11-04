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

import Foundation

/// A unique defaults suite whose plist lives in the temporary directory. A plain suite name
/// is stored in Library/Preferences, where cfprefsd rewrites an empty plist seconds after a
/// test deletes it; an absolute-path suite is not rewritten.
func testDefaultsSuite(_ name: String) -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(name).\(UUID().uuidString)").path
}

/// Removes a temporary defaults suite and its plist, which `removePersistentDomain` leaves behind.
func removeTestDefaults(_ suite: String) {
    UserDefaults.standard.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(atPath: suite + ".plist")
}

/// Removes a temporary library and everything the engine writes beside it: the WAL and shared-memory files, the
/// migration lock, and the `<name>-before-v<n>-<date>.sqlite3` copies a migration keeps. Deleting only the three
/// SQLite files left those behind in the temporary directory (1,400 files after a month of runs).
func removeTemporaryLibrary(atPath path: String) {
    let url = URL(fileURLWithPath: path)
    let folder = url.deletingLastPathComponent()
    let stem = url.deletingPathExtension().lastPathComponent
    let base = url.lastPathComponent
    let exact: Set<String> = [base, base + "-wal", base + "-shm", base + ".migration-lock"]
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    for name in names where exact.contains(name) || name.hasPrefix(stem + "-before-v") {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
    }
}
