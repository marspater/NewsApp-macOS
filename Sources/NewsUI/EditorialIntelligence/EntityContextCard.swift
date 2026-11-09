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

/// Compact context card representing an extracted entity in Overview and Reader views (W2 #716).
public struct EntityContextCard: View {
    public let entity: EntityRecord
    public let onSelect: (() -> Void)?

    @State private var isHovered = false

    public init(entity: EntityRecord, onSelect: (() -> Void)? = nil) {
        self.entity = entity
        self.onSelect = onSelect
    }

    public var body: some View {
        Button(action: {
            onSelect?()
        }) {
            HStack(spacing: 8) {
                Image(systemName: entity.entityType.displayIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(typeColor)
                    .frame(width: 20, height: 20)
                    .background(typeColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(entity.canonicalName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(NSColor.labelColor))
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Text(entity.entityType.displayName)
                            .font(.system(size: 10))
                            .foregroundStyle(Color(NSColor.secondaryLabelColor))

                        Text("•")
                            .font(.system(size: 8))
                            .foregroundStyle(Color(NSColor.tertiaryLabelColor))

                        Text("\(entity.mentionCount) \(entity.mentionCount == 1 ? "mention" : "mentions")")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(NSColor.secondaryLabelColor))
                    }
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(NSColor.tertiaryLabelColor))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        isHovered
                            ? Color(NSColor.quaternaryLabelColor).opacity(0.5) : Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Inspect editorial dossier for \(entity.canonicalName)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(entity.canonicalName), \(entity.entityType.displayName), \(entity.mentionCount) mentions")
    }

    private var typeColor: Color {
        switch entity.entityType {
        case .person:
            return .blue
        case .organization:
            return .purple
        case .location, .place:
            return .teal
        case .unknown:
            return .gray
        }
    }
}
