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

import SwiftUI

/// The people, organizations and places the given stories name, each a pill that opens that entity's dossier in a
/// popover (W2 #716). The row is hidden until the entity index has an entity with coverage beyond these stories, never
/// shown empty (DESIGN.md 8.4).
struct EntityChipRow: View {
    let articleIDs: [String]
    let source: EntitySource
    let onSelectStory: (String) -> Void
    @State private var entities: [EntityRecord] = []

    var body: some View {
        Group {
            if !entities.isEmpty {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    EyebrowText("In this story")
                        .accessibilityAddTraits(.isHeader)
                    ReaderTagLayout(spacing: AppSpacing.xs) {
                        ForEach(entities) { entity in
                            EntityChip(entity: entity, source: source, onOpenStory: onSelectStory)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: articleIDs) { entities = await source.entities(articleIDs) }
    }
}

/// One entity as a pill. A single click opens its dossier (DESIGN.md 15).
struct EntityChip: View {
    let entity: EntityRecord
    let source: EntitySource
    let onOpenStory: (String) -> Void
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            TagView(title: entity.canonicalName, systemImage: entity.entityType.symbol)
        }
        .buttonStyle(.plain)
        .buttonBorderShape(.capsule)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            EntityDossierPopover(
                entity: entity, source: source,
                onOpenStory: { id in
                    isPresented = false
                    onOpenStory(id)
                })
        }
        .accessibilityLabel("\(entity.canonicalName), \(entity.entityType.displayName)")
        .accessibilityHint("Shows how the stories on this Mac covered it over 30 days")
        .help("Show coverage of \(entity.canonicalName)")
        .fixedSize(horizontal: false, vertical: true)
    }
}
