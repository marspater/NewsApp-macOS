// ReaderAccessibilityTests.swift
// Dedicated accessibility regression test suite for source-reader experience (Issue #123)

import Foundation
import SwiftUI
import AppKit

extension Notification.Name {
    static let nextArticleCommand = Notification.Name("nextArticleCommand")
    static let prevArticleCommand = Notification.Name("prevArticleCommand")
    static let toggleReadCommand = Notification.Name("toggleReadCommand")
    static let toggleSaveCommand = Notification.Name("toggleSaveCommand")
    static let openInBrowserCommand = Notification.Name("openInBrowserCommand")
    static let toggleViewModeCommand = Notification.Name("toggleViewModeCommand")
}

@main
@MainActor
struct ReaderAccessibilityTests {
    static var testsRun = 0
    static var failures = 0

    static func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, file: StaticString = #file, line: UInt = #line) {
        testsRun += 1
        if actual != expected {
            failures += 1
            print("❌ FAILURE [\(file):\(line)]: \(message) — Expected '\(expected)', got '\(actual)'")
        }
    }

    static func assertTrue(_ condition: Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
        testsRun += 1
        if !condition {
            failures += 1
            print("❌ FAILURE [\(file):\(line)]: \(message) — Expected true, got false")
        }
    }

    static func assertFalse(_ condition: Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
        testsRun += 1
        if condition {
            failures += 1
            print("❌ FAILURE [\(file):\(line)]: \(message) — Expected false, got true")
        }
    }

    static func main() async {
        print("=== Running Reader Accessibility Tests (Issue #123) ===")

        testReaderBlockTextFormattingAndCopy()
        testFigureAccessibilityAltTextFallback()
        testSourceLineVoiceOverFormatting()
        testIncreaseContrastValues()
        testReduceMotionReaderPolicy()
        testKeyboardShortcutsAndModifiers()

        print("Finished \(testsRun) reader accessibility checks with \(failures) failures.")
        if failures > 0 {
            exit(1)
        } else {
            print("✅ ALL READER ACCESSIBILITY CHECKS PASSED")
        }
    }

    // MARK: - 1. Text Selection and Copy Formatting Tests
    static func testReaderBlockTextFormattingAndCopy() {
        print("  - Testing Reader Block Text Formatting and Copy Fidelity...")

        // Plain block
        let plainBlock = ReaderBlock(kind: .paragraph, text: "Simple paragraph without formatting.")
        let plainAttr = readerText(plainBlock)
        assertEqual(String(plainAttr.characters), "Simple paragraph without formatting.", "Plain text matches verbatim")

        // Block with rich inline runs: strong, emphasis, code, and link
        let run1 = ReaderInlineRun(text: "Here is ", strong: false, emphasis: false, code: false, link: nil)
        let run2 = ReaderInlineRun(text: "bold text", strong: true, emphasis: false, code: false, link: nil)
        let run3 = ReaderInlineRun(text: ", ", strong: false, emphasis: false, code: false, link: nil)
        let run4 = ReaderInlineRun(text: "italicized", strong: false, emphasis: true, code: false, link: nil)
        let run5 = ReaderInlineRun(text: ", and ", strong: false, emphasis: false, code: false, link: nil)
        let run6 = ReaderInlineRun(text: "code snippet", strong: false, emphasis: false, code: true, link: nil)
        let run7 = ReaderInlineRun(text: ", with a ", strong: false, emphasis: false, code: false, link: nil)
        let run8 = ReaderInlineRun(text: "reference link", strong: false, emphasis: false, code: false, link: "https://example.com/article")
        let run9 = ReaderInlineRun(text: ".", strong: false, emphasis: false, code: false, link: nil)

        let runs = [run1, run2, run3, run4, run5, run6, run7, run8, run9]
        let fullText = runs.map(\.text).joined()

        let richBlock = ReaderBlock(
            kind: .paragraph,
            text: fullText,
            inlineRuns: runs
        )

        let richAttr = readerText(richBlock)
        // 1. Text copy fidelity: String conversion preserves exact plain text
        assertEqual(String(richAttr.characters), fullText, "String(characters) extracts complete text without dropped segments")

        // 2. Formatting verification: inspect attribute runs
        var foundStrong = false
        var foundEmphasis = false
        var foundCode = false
        var foundLink = false

        for run in richAttr.runs {
            let slice = String(richAttr.characters[run.range])
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) && slice == "bold text" {
                    foundStrong = true
                }
                if intent.contains(.emphasized) && slice == "italicized" {
                    foundEmphasis = true
                }
                if intent.contains(.code) && slice == "code snippet" {
                    foundCode = true
                }
            }
            if let link = run.link, link.absoluteString == "https://example.com/article" && slice == "reference link" {
                foundLink = true
            }
        }

        assertTrue(foundStrong, "Inline strong presentation intent is applied")
        assertTrue(foundEmphasis, "Inline emphasis presentation intent is applied")
        assertTrue(foundCode, "Inline code presentation intent is applied")
        assertTrue(foundLink, "Inline link URL attribute is applied")

        // Test clipboard copy simulation
        NSPasteboard.general.clearContents()
        let copied = NSPasteboard.general.setString(String(richAttr.characters), forType: .string)
        assertTrue(copied, "Clipboard accepted reader block text")
        assertEqual(NSPasteboard.general.string(forType: .string), fullText, "Pasted text matches reader block characters")
    }

    // MARK: - 2. VoiceOver Alt Text Fallback Tests
    static func testFigureAccessibilityAltTextFallback() {
        print("  - Testing Figure Accessibility Alt Text Fallback...")

        // Case 1: Alt text provided
        let block1 = ReaderBlock(kind: .figure, text: "Photo caption", imageURL: "https://example.com/photo.jpg", imageAlt: "Sunset over hills", imageCredit: "Jane Doe", imageWidth: 800, imageHeight: 600)
        let resolvedAlt1 = ReaderFigureView.effectiveImageAlt(for: block1)
        assertEqual(resolvedAlt1, "Sunset over hills", "Explicit alt text is preserved")

        // Case 2: Alt text is nil
        let block2 = ReaderBlock(kind: .figure, text: "Photo caption", imageURL: "https://example.com/photo2.jpg", imageAlt: nil, imageCredit: "Jane Doe", imageWidth: 800, imageHeight: 600)
        let resolvedAlt2 = ReaderFigureView.effectiveImageAlt(for: block2)
        assertEqual(resolvedAlt2, "Article image", "Nil alt text falls back to 'Article image'")

        // Case 3: Alt text is empty or whitespace-only (defect in current code)
        let block3 = ReaderBlock(kind: .figure, text: "Photo caption", imageURL: "https://example.com/photo3.jpg", imageAlt: "   ", imageCredit: "Jane Doe", imageWidth: 800, imageHeight: 600)
        let resolvedAlt3 = ReaderFigureView.effectiveImageAlt(for: block3)
        assertEqual(resolvedAlt3, "Article image", "Whitespace/empty alt text must fall back to 'Article image' instead of empty label")
    }

    // MARK: - 3. VoiceOver Source Line Formatter Tests
    static func testSourceLineVoiceOverFormatting() {
        print("  - Testing Source Line VoiceOver Accessibility Label Formatting...")

        let label = ArticleDetailView.sourceLineAccessibilityLabel(
            source: "BBC News",
            publicationDateText: "Oct 2, 2026",
            readingTimeEstimate: "4 min read"
        )
        assertEqual(label, "BBC News, Oct 2, 2026, 4 min read", "Source line is formatted cleanly for VoiceOver without separators or screaming caps")
    }

    // MARK: - 4. Increase Contrast Values Tests
    static func testIncreaseContrastValues() {
        print("  - Testing Increase Contrast Color and Stroke Adjustments...")

        // Divider opacity under standard vs increased contrast
        let standardDividerOpacity = ArticleDetailView.dividerOpacity(for: .standard)
        let increasedDividerOpacity = ArticleDetailView.dividerOpacity(for: .increased)
        assertTrue(increasedDividerOpacity > standardDividerOpacity, "Increased contrast divider opacity must be stronger than standard")
        assertEqual(standardDividerOpacity, 0.15, "Standard divider opacity is 0.15")
        assertEqual(increasedDividerOpacity, 0.60, "Increased divider opacity is 0.60")

        // Quote bar opacity
        let standardQuoteBarOpacity = ArticleDetailView.quoteBarOpacity(for: .standard)
        let increasedQuoteBarOpacity = ArticleDetailView.quoteBarOpacity(for: .increased)
        assertEqual(standardQuoteBarOpacity, 0.5, "Standard quote bar opacity is 0.5")
        assertEqual(increasedQuoteBarOpacity, 1.0, "Increased contrast quote bar opacity is 1.0")

        // Border opacity
        let standardBorderOpacity = ArticleDetailView.capsuleBorderOpacity(for: .standard)
        let increasedBorderOpacity = ArticleDetailView.capsuleBorderOpacity(for: .increased)
        assertTrue(increasedBorderOpacity > standardBorderOpacity, "Increased contrast button border is stronger")
        assertEqual(standardBorderOpacity, 0.08, "Standard capsule border opacity is 0.08")
        assertEqual(increasedBorderOpacity, 0.35, "Increased capsule border opacity is 0.35")
    }

    // MARK: - 5. Reduce Motion Policy Tests
    static func testReduceMotionReaderPolicy() {
        print("  - Testing Reduce Motion Reader Animation Policy...")

        // Test that animation duration resolves to zero / nil when reduceMotion is active
        let standardAnimation = ArticleDetailView.readerAnimation(reduceMotion: false)
        let reducedAnimation = ArticleDetailView.readerAnimation(reduceMotion: true)
        assertTrue(standardAnimation != nil, "Standard mode enables smooth animation")
        assertTrue(reducedAnimation == nil, "Reduce motion disables animation for reader transitions")
    }

    // MARK: - 6. Keyboard Shortcuts & Modifier Pass-Through Tests
    static func testKeyboardShortcutsAndModifiers() {
        print("  - Testing Keyboard Shortcuts & Modifier Pass-Through...")

        // Command modifier (e.g. Cmd+C for copying selection) must pass through to system
        let cmdModifier = EventModifiers.command
        assertTrue(ArticleDetailView.shouldPassThroughToSystem(modifiers: cmdModifier), "Cmd modifier passes through to system (e.g. Cmd+C)")

        let ctrlModifier = EventModifiers.control
        assertTrue(ArticleDetailView.shouldPassThroughToSystem(modifiers: ctrlModifier), "Control modifier passes through to system")

        let optModifier = EventModifiers.option
        assertTrue(ArticleDetailView.shouldPassThroughToSystem(modifiers: optModifier), "Option modifier passes through to system")

        let emptyModifiers: EventModifiers = []
        assertFalse(ArticleDetailView.shouldPassThroughToSystem(modifiers: emptyModifiers), "Unmodified single-key strokes are captured by reader shortcuts")
    }
}
