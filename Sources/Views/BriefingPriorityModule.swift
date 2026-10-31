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
import SwiftUI

/// Priority developments: impact, momentum, original reports and the reported fact (#849).
/// Phase B fills the data and the view; until then the module is hidden.
struct BriefingPriorityData: Equatable, Sendable {
    /// nil hides the module.
    @MainActor static func load(_ context: BriefingLoadContext, store: ArticleStore) async -> Self? { nil }
    /// Sample data for `Tests/OverviewCaptures.swift`.
    static var captureFixture: Self? { nil }
}

struct BriefingPriorityModuleView: View {
    let data: BriefingPriorityData
    let filter: BriefingBoardFilter
    let actions: BriefingActions

    var body: some View { EmptyView() }
}
