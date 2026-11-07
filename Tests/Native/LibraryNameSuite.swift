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

extension NativeSuites {
    /// `NEWS_LIBRARY_NAME` picks a file name, never a directory (#1113).
    @Suite struct LibraryNameSuite {
        private let directory = URL(fileURLWithPath: "/tmp/library-name-check", isDirectory: true)

        private func resolved(_ value: String?) -> URL {
            let environment = value.map { ["NEWS_LIBRARY_NAME": $0] } ?? [:]
            return directory.appendingPathComponent(DatabaseEngine.libraryFileName(environment: environment))
        }

        @Test func unsetKeepsTheDefaultName() {
            #expect(resolved(nil).lastPathComponent == "news.sqlite3")
        }

        @Test(arguments: ["uitest-2026-11-07", "a", "A_b.c-1"])
        func validNameStaysInTheSameDirectory(_ name: String) {
            let url = resolved(name)
            #expect(url.lastPathComponent == "\(name).sqlite3")
            #expect(url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
        }

        @Test(arguments: ["", "..", "../news", "a/b", "/etc/x", "a..b", "nam e", "näme", "a\\b", "~"])
        func invalidNameFallsBackToTheDefault(_ name: String) {
            let url = resolved(name)
            #expect(url.lastPathComponent == "news.sqlite3")
            #expect(url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
        }
    }
}
