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

/// One report as the importance rater sees it: its headline and the start of its feed summary. The on-device event judge
/// that once read pairs of these was removed in matcher v12 (#580); clustering is deterministic plus the pair model.
struct EventJudgeReport: Sendable, Hashable {
    static let summaryPrefix = 600

    let id: String
    let title: String
    let summary: String

    init(id: String, title: String, summary: String) {
        self.id = id
        self.title = title
        self.summary = String(summary.prefix(Self.summaryPrefix))
    }
}
