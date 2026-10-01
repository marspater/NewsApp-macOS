import SwiftUI

/// One line of operational feed health. Wording and color describe availability and content only, never trustworthiness.
struct FeedHealthLine: View {
    let health: FeedHealth?

    var body: some View {
        let health = health ?? FeedHealth(nil, now: Date())
        let summary = health.summary(now: Date())
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xxs) {
            if health.needsAttention {
                // Text stays in the secondary color for contrast; the icon carries the warning.
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(AppColor.warning)
                    .accessibilityHidden(true)
            }
            Text(summary)
                .foregroundColor(AppColor.secondaryText)
                .lineLimit(2)
        }
        .font(AppTypography.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Feed health: \(summary)")
    }
}
