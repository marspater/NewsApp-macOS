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

// ReaderAccessibilityTests.swift
// Dedicated accessibility regression test suite for source-reader experience (Issue #123)

import AppKit
import Foundation
import SwiftUI

extension Notification.Name {
    static let nextArticleCommand = Notification.Name("nextArticleCommand")
    static let prevArticleCommand = Notification.Name("prevArticleCommand")
    static let toggleReadCommand = Notification.Name("toggleReadCommand")
    static let toggleSaveCommand = Notification.Name("toggleSaveCommand")
    static let openInBrowserCommand = Notification.Name("openInBrowserCommand")
}

@main
@MainActor
struct ReaderAccessibilityTests {
    static var testsRun = 0
    static var failures = 0

    static func assertEqual<T: Equatable>(
        _ actual: T, _ expected: T, _ message: String, file: StaticString = #file, line: UInt = #line
    ) {
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
        testReaderLinkResolution()
        testFigureAccessibilityAltTextFallback()
        testSourceLineVoiceOverFormatting()
        testIncreaseContrastValues()
        testReaderTypographyAndSpacing()
        testReduceMotionReaderPolicy()
        testKeyboardShortcutsAndModifiers()
        testLeadImageFraming()
        testEarlierInStoryState()

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
        let run8 = ReaderInlineRun(
            text: "reference link", strong: false, emphasis: false, code: false, link: "https://example.com/article")
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
        assertEqual(
            String(richAttr.characters), fullText, "String(characters) extracts complete text without dropped segments")

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
        assertEqual(
            NSPasteboard.general.string(forType: .string), fullText, "Pasted text matches reader block characters")
    }

    // MARK: - 1b. Link resolution and underline
    static func testReaderLinkResolution() {
        print("  - Testing reader link resolution against the story URL and link underlines...")
        // Links: relative hrefs from older stored documents resolve against the story; link runs are underlined.
        let linked = ReaderBlock(
            kind: .paragraph, text: "Read the report here.",
            inlineRuns: [
                ReaderInlineRun(text: "Read the report "), ReaderInlineRun(text: "here", link: "/reports/2026"),
                ReaderInlineRun(text: "."),
            ])
        let attributed = readerText(linked, baseURL: URL(string: "https://publisher.example/story/1"))
        let linkRun = attributed.runs.first { $0.link != nil }
        assertEqual(
            linkRun?.link?.absoluteString, "https://publisher.example/reports/2026",
            "A relative link resolves against the story URL")
        assertTrue(linkRun?.underlineStyle == .single, "Link runs are underlined")
        assertTrue(
            readerText(linked, baseURL: nil).runs.allSatisfy { $0.link == nil },
            "Without a base a relative link stays plain text")
    }

    // MARK: - 2. VoiceOver Alt Text Fallback Tests
    static func testFigureAccessibilityAltTextFallback() {
        print("  - Testing Figure Accessibility Alt Text Fallback...")

        // Case 1: Alt text provided
        let block1 = ReaderBlock(
            kind: .figure, text: "Photo caption", imageURL: "https://example.com/photo.jpg",
            imageAlt: "Sunset over hills", imageCredit: "Jane Doe", imageWidth: 800, imageHeight: 600)
        let resolvedAlt1 = ReaderFigureView.effectiveImageAlt(for: block1)
        assertEqual(resolvedAlt1, "Sunset over hills", "Explicit alt text is preserved")

        // Case 2: Alt text is nil
        let block2 = ReaderBlock(
            kind: .figure, text: "Photo caption", imageURL: "https://example.com/photo2.jpg", imageAlt: nil,
            imageCredit: "Jane Doe", imageWidth: 800, imageHeight: 600)
        let resolvedAlt2 = ReaderFigureView.effectiveImageAlt(for: block2)
        assertEqual(resolvedAlt2, "Photo caption", "Nil alt text falls back to the caption")

        // Case 3: Alt text is empty or whitespace-only (defect in current code)
        let block3 = ReaderBlock(
            kind: .figure, text: "Photo caption", imageURL: "https://example.com/photo3.jpg", imageAlt: "   ",
            imageCredit: "Jane Doe", imageWidth: 800, imageHeight: 600)
        let resolvedAlt3 = ReaderFigureView.effectiveImageAlt(for: block3)
        assertEqual(resolvedAlt3, "Photo caption", "Whitespace alt text falls back to the caption")

        // Case 4: No alt and no caption: the image is decorative and hidden from VoiceOver.
        let block4 = ReaderBlock(
            kind: .figure, text: "", imageURL: "https://example.com/photo4.jpg", imageAlt: nil, imageCredit: nil,
            imageWidth: 800, imageHeight: 600)
        assertEqual(ReaderFigureView.effectiveImageAlt(for: block4), "", "No alt and no caption reads as decorative")
    }

    static func testLeadImageFraming() {
        print("  - Testing lead image framing for square and portrait photos...")
        assertTrue(ArticleCardView<EmptyView>.framesLeadImageWhole(aspectRatio: 1), "Square photos are framed whole")
        assertTrue(
            ArticleCardView<EmptyView>.framesLeadImageWhole(aspectRatio: 0.8), "Portrait photos are framed whole")
        assertFalse(
            ArticleCardView<EmptyView>.framesLeadImageWhole(aspectRatio: 16.0 / 9.0), "Wide photos fill the card")
        assertFalse(ArticleCardView<EmptyView>.framesLeadImageWhole(aspectRatio: nil), "Unknown sizes fill the card")
    }

    static func testEarlierInStoryState() {
        print("  - Testing Earlier in This Story state: lookup results, failures and overview navigation...")
        let earlier = RelatedStoryEvent(eventID: "e1", articleID: "a1", title: "Earlier", firstPublishedAt: Date())
        let current = RelatedStoryEvent(eventID: "e0", articleID: "a0", title: "Current", firstPublishedAt: Date())
        assertTrue(
            ArticleDetailView.relatedEventsToShow(nil, overviewEventID: "e0").isEmpty,
            "A pending or failed lookup leaves the section out")
        assertTrue(
            ArticleDetailView.relatedEventsToShow(("other", [earlier]), overviewEventID: "e0").isEmpty,
            "Links found for another event never show on this overview")
        assertTrue(
            ArticleDetailView.relatedEventsToShow(("e0", [earlier, current]), overviewEventID: "e0").map(\.eventID)
                == ["e1"], "The section lists earlier events and never the overview's own event")
        assertTrue(
            ArticleDetailView.opensOnOverview(showingOverview: false, requestedArticleID: "a1", articleID: "a1"),
            "An earlier event opens on its overview even after an interrupted load reset the mode")
        assertFalse(
            ArticleDetailView.opensOnOverview(showingOverview: false, requestedArticleID: "a1", articleID: "a2"),
            "Other articles keep the story view")
        assertTrue(
            ArticleDetailView.opensOnOverview(showingOverview: true, requestedArticleID: nil, articleID: "a2"),
            "Moving between events while on the overview stays on overviews")
    }

    // MARK: - 3. VoiceOver Source Line Formatter Tests
    static func testSourceLineVoiceOverFormatting() {
        print("  - Testing Source Line VoiceOver Accessibility Label Formatting...")

        let label = ArticleDetailView.sourceLineAccessibilityLabel(
            source: "BBC News",
            publicationDateText: "Oct 2, 2026",
            readingTimeEstimate: "4 min read"
        )
        assertEqual(
            label, "BBC News, Oct 2, 2026, 4 min read",
            "Source line is formatted cleanly for VoiceOver without separators or screaming caps")
    }

    // MARK: - Reader typography and block spacing
    static func testReaderTypographyAndSpacing() {
        print("  - Testing reader heading sizes and block spacing...")
        for theme in ArticleThemeType.allCases {
            let body = AppTypography.bodySize(for: theme)
            let heading = AppTypography.readerHeadingSize(level: 2, theme: theme)
            let subheading = AppTypography.readerHeadingSize(level: 3, theme: theme)
            assertTrue(subheading > body, "\(theme.displayName) subheadings are larger than body text")
            assertTrue(heading > subheading, "\(theme.displayName) headings are larger than subheadings")
        }

        let spacing = { (after: ReaderBlock.Kind, before: ReaderBlock.Kind?, scale: CGFloat) in
            ArticleDetailView.blockSpacing(after: after, before: before, scale: scale)
        }
        assertEqual(spacing(.paragraph, .paragraph, 1), AppSpacing.lg, "Paragraphs are a full step apart")
        assertEqual(spacing(.listItem, .listItem, 1), AppSpacing.xs, "List items stay together")
        assertEqual(spacing(.listItem, .paragraph, 1), AppSpacing.lg, "A list ends with a full step")
        assertEqual(spacing(.paragraph, .heading, 1), AppSpacing.xl, "A heading is set apart from the text before it")
        assertEqual(spacing(.heading, .paragraph, 1), AppSpacing.xs, "A heading sits close to the text it introduces")
        assertEqual(spacing(.subheading, .subheading, 1), AppSpacing.xs, "Stacked headings stay together")
        assertEqual(spacing(.paragraph, .heading, 1.5), AppSpacing.xl * 1.5, "Spacing scales with the text size")
    }

    // MARK: - 4. Increase Contrast Values Tests
    static func testIncreaseContrastValues() {
        print("  - Testing Increase Contrast Color and Stroke Adjustments...")

        // Divider opacity under standard vs increased contrast
        let standardDividerOpacity = ArticleDetailView.dividerOpacity(for: .standard)
        let increasedDividerOpacity = ArticleDetailView.dividerOpacity(for: .increased)
        assertTrue(
            increasedDividerOpacity > standardDividerOpacity,
            "Increased contrast divider opacity must be stronger than standard")
        assertEqual(standardDividerOpacity, 0.15, "Standard divider opacity is 0.15")
        assertEqual(increasedDividerOpacity, 1.0, "Increased divider opacity is the full separator")

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
        assertTrue(
            ArticleDetailView.shouldPassThroughToSystem(modifiers: cmdModifier),
            "Cmd modifier passes through to system (e.g. Cmd+C)")

        let ctrlModifier = EventModifiers.control
        assertTrue(
            ArticleDetailView.shouldPassThroughToSystem(modifiers: ctrlModifier),
            "Control modifier passes through to system")

        let optModifier = EventModifiers.option
        assertTrue(
            ArticleDetailView.shouldPassThroughToSystem(modifiers: optModifier),
            "Option modifier passes through to system")

        let emptyModifiers: EventModifiers = []
        assertFalse(
            ArticleDetailView.shouldPassThroughToSystem(modifiers: emptyModifiers),
            "Unmodified single-key strokes are captured by reader shortcuts")

        // #597: one summary label that says how the summary was made.
        assertEqual(
            ArticleDetailView.summaryLabel(modelIdentifier: "apple.natural-language.fallback"), "Extractive summary",
            "Selected sentences are an extractive summary")
        assertEqual(
            ArticleDetailView.summaryLabel(modelIdentifier: "apple.foundation-model"), "Generated summary",
            "The on-device model writes a generated summary")
        assertEqual(
            ArticleDetailView.summaryLabel(modelIdentifier: nil), "Generated summary",
            "Before analysis the label names the model summary")

        // #594: Esc and B step back one reader; a section click or ⌘1 returns to the list from any depth.
        var path = NavigationPath()
        path.append("first")
        path.append("second")
        ArticleDetailView.stepBack(&path)
        assertEqual(path.count, 1, "Esc steps back one reader")
        path.append("second")
        ArticleDetailView.stepBack(&path, toList: true)
        assertTrue(path.isEmpty, "Reselecting the section or ⌘1 returns to the list")
        ArticleDetailView.stepBack(&path)
        assertTrue(path.isEmpty, "Stepping back from the list is a no-op")
    }
}
