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
