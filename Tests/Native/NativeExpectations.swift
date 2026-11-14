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
import Testing

// Swift Testing counterparts of NewsTestSupport.swift's assertEqual/assertTrue/assertFalse for ported suites (#1070):
// same argument order, but a failure is recorded against the caller's line instead of exiting the process.

func expectEqual<T: Equatable>(
    _ actual: T, _ expected: T, _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(actual == expected, Comment(rawValue: message), sourceLocation: sourceLocation)
}

func expectTrue(_ condition: Bool, _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(condition, Comment(rawValue: message), sourceLocation: sourceLocation)
}

func expectFalse(_ condition: Bool, _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(!condition, Comment(rawValue: message), sourceLocation: sourceLocation)
}

func expectNil<T>(
    _ value: T?,
    _ message: String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(value == nil, Comment(rawValue: message), sourceLocation: sourceLocation)
}

/// The checkout root, for fixtures the runner reads relative to its working directory: xctest runs elsewhere.
let nativeRepositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

/// Parent of every native suite: Swift Testing runs unrelated suites concurrently, and ported tests share static
/// doubles such as `MockURLProtocol.requestHandler`, so all nested suites run one test at a time. They run in the
/// checkout, like the runner: xctest starts in another directory, and the app's `bundledModelResource` falls back to
/// `Sources/Resources/CoreML`, which `SentenceEmbedder.shared` and `PairScorer.shared` resolve once per process.
@Suite(.serialized, .repositoryWorkingDirectory) enum NativeSuites {}

/// Runs a suite with the checkout as the working directory and restores the previous one afterwards.
struct RepositoryWorkingDirectory: SuiteTrait, TestScoping {
    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        let previous = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(nativeRepositoryRoot.path)
        defer { FileManager.default.changeCurrentDirectoryPath(previous) }
        try await function()
    }
}

extension Trait where Self == RepositoryWorkingDirectory {
    static var repositoryWorkingDirectory: Self { Self() }
}

extension Tag {
    @Tag static var feedParsing: Self
    @Tag static var migration: Self
    @Tag static var feedHealth: Self
    @Tag static var publisherExcerpts: Self
    @Tag static var storage: Self
    @Tag static var editorial: Self
    @Tag static var networking: Self
    @Tag static var diagnostics: Self
    @Tag static var cancellation: Self
    @Tag static var clustering: Self
    @Tag static var intelligence: Self
    /// Every suite the Integration test plan runs: a plan's tag list selects only tests carrying all of its tags.
    @Tag static var integration: Self
}
