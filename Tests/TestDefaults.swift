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
