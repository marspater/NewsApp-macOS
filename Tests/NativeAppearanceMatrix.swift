import AppKit
import ImageIO
import SwiftUI

/// Captures the offline VoiceOver fixture's list, grid, reader and overview under each
/// window appearance. Pixel evidence for token alignment and contrast only: not the
/// production scene toolbar, Reduce Transparency or spoken VoiceOver.
@main
struct NativeAppearanceMatrix {
    @MainActor
    static func main() {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let app = NSApplication.shared
        let delegate = MatrixDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
private final class MatrixDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            var host: LiveVoiceOverHost?
            do {
                let fixture = try LiveVoiceOverHost()
                host = fixture
                try await fixture.run()
                try await capture(fixture, to: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
                await fixture.shutdown()
                NSApplication.shared.terminate(nil)
            } catch {
                await host?.shutdown()
                fputs("Appearance matrix failed: \(error)\n", stderr)
                exit(1)
            }
        }
    }

    private func capture(_ host: LiveVoiceOverHost, to output: URL) async throws {
        let appearances: [(String, NSAppearance.Name, ColorSchemeContrast)] = [
            ("light", .aqua, .standard), ("dark", .darkAqua, .standard),
            ("light-increased-contrast", .accessibilityHighContrastAqua, .increased),
            ("dark-increased-contrast", .accessibilityHighContrastDarkAqua, .increased),
        ]
        let views = [
            ("list", "LIST", false), ("grid", "LIST", true), ("reader", "READER", false),
            ("overview", "OVERVIEW", false),
        ]
        for (suffix, name, contrast) in appearances {
            host.window?.appearance = NSAppearance(named: name)
            for (file, mode, grid) in views {
                guard let window = host.window, let defaults = host.defaults else {
                    throw QAFailure("Fixture host is not initialized")
                }
                defaults.set(grid, forKey: "articleGridLayout")
                // Same root as LiveVoiceOverHost.displayMode. A window's high-contrast appearance
                // does not reach SwiftUI, and split-view columns re-derive the system value, so the
                // app's own QA override (what `effectiveContrast` reads) carries the contrast too.
                window.contentView = nil
                host.loadedImages.removeAll()
                host.state.activeMode = mode
                let image = host.image
                window.contentView = NSHostingView(
                    rootView: HostRootView(state: host.state)
                        .defaultAppStorage(defaults)
                        .environment(\.readerImageLoader, { _ in image })
                        .environment(\._colorSchemeContrast, contrast)
                        .environment(\.overrideContrast, contrast))
                // Reader figures decode asynchronously; the other fixtures settle within one pass.
                let deadline = ProcessInfo.processInfo.systemUptime + 8
                repeat {
                    try await Task.sleep(for: .milliseconds(300))
                } while mode == "READER" && host.loadedImages.count < 2
                    && ProcessInfo.processInfo.systemUptime < deadline
                try await captureWindow(window, to: output.appendingPathComponent("\(file)-\(suffix).png"))
            }
        }
        // Relative times and live glass make pixel baselines flaky; instead every view must respond to
        // the appearance and to Increase Contrast, which catches frozen or contrast-blind tokens.
        for (file, _, _) in views {
            let png = { (suffix: String) in output.appendingPathComponent("\(file)-\(suffix).png") }
            for (a, b) in [
                ("light", "dark"), ("light", "light-increased-contrast"), ("dark", "dark-increased-contrast"),
            ] {
                let changed = try Self.changedPixels(png(a), png(b))
                guard changed >= Self.minimumChangedPixels else {
                    throw QAFailure("\(file): \(b) differs from \(a) in only \(changed) pixels")
                }
            }
        }
        print("APPEARANCE_MATRIX_PASS: \(appearances.count * views.count) renders in \(output.path)")
    }

    /// A strengthened divider alone changes a few thousand pixels at 2x; unchanged captures differ by none.
    static let minimumChangedPixels = 500

    static func changedPixels(_ first: URL, _ second: URL) throws -> Int {
        func rgba(_ url: URL) throws -> (bytes: [UInt8], width: Int, height: Int) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { throw QAFailure("Cannot read \(url.lastPathComponent)") }
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            guard
                let context = CGContext(
                    data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw QAFailure("Cannot decode \(url.lastPathComponent)") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return (bytes, image.width, image.height)
        }
        let a = try rgba(first)
        let b = try rgba(second)
        guard a.width == b.width, a.height == b.height else { return Int.max }
        var changed = 0
        for pixel in stride(from: 0, to: a.bytes.count, by: 4) {
            let delta =
                abs(Int(a.bytes[pixel]) - Int(b.bytes[pixel])) + abs(Int(a.bytes[pixel + 1]) - Int(b.bytes[pixel + 1]))
                + abs(Int(a.bytes[pixel + 2]) - Int(b.bytes[pixel + 2]))
            if delta > 8 { changed += 1 }
        }
        return changed
    }

    /// The window server composites sidebar vibrancy, materials and the toolbar; cacheDisplay
    /// does not. A window that lost focus can be shrunk (Stage Manager), so the size is checked.
    private func captureWindow(_ window: NSWindow, to url: URL) async throws {
        let expected = Int(window.frame.width * window.backingScaleFactor)
        for _ in 0..<5 {
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(400))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
            try capture.run()
            capture.waitUntilExit()
            guard capture.terminationStatus == 0 else {
                throw QAFailure("screencapture failed; grant Screen Recording to the launching terminal")
            }
            if NSBitmapImageRep(data: try Data(contentsOf: url))?.pixelsWide == expected { return }
        }
        throw QAFailure("Window kept losing focus; captured \(url.lastPathComponent) below \(expected) px")
    }
}
