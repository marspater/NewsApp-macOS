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

/// The first-launch flow, one step per screen, in order (#562).
enum OnboardingStep: Int, CaseIterable, Sendable {
    case welcome, feeds, sections, intelligence, notifications, done

    var next: OnboardingStep? { Self(rawValue: rawValue + 1) }
    var previous: OnboardingStep? { Self(rawValue: rawValue - 1) }
    var isLast: Bool { next == nil }

    /// "Step 2 of 6", for the page indicator and VoiceOver.
    var position: String { "Step \(rawValue + 1) of \(Self.allCases.count)" }

    /// The forward button: the last step closes the flow.
    var continueTitle: String { isLast ? "Start Reading" : "Continue" }

    var title: String {
        switch self {
        case .welcome: return "Welcome to News"
        case .feeds: return "Choose Your Feeds"
        case .sections: return "Pick Your Sections"
        case .intelligence: return "On-Device Intelligence"
        case .notifications: return "Notifications"
        case .done: return "You're All Set"
        }
    }

    /// The step's art: one main symbol, drawn large.
    var symbol: String {
        switch self {
        case .welcome: return "newspaper.fill"
        case .feeds: return "antenna.radiowaves.left.and.right"
        case .sections: return "square.grid.2x2.fill"
        case .intelligence: return "sparkles"
        case .notifications: return "bell.badge.fill"
        case .done: return "checkmark.circle.fill"
        }
    }

    /// Smaller symbols around the main one, each naming something the step is about.
    var companions: [String] {
        switch self {
        case .welcome: return ["globe", "square.stack.3d.up", "bookmark.fill"]
        case .feeds: return ["globe", "chart.line.uptrend.xyaxis", "atom"]
        case .sections: return ["sidebar.left", "list.bullet"]
        case .intelligence: return ["lock.fill", "laptopcomputer"]
        case .notifications: return ["clock", "star.fill"]
        case .done: return []
        }
    }

    /// One short tip per step; each names a feature that exists, with the place or key that reaches it.
    var tip: String {
        switch self {
        case .welcome:
            return
                "Reports of the same event from several publishers appear as one card. Click it to open the event overview."
        case .feeds:
            return "Star a feed in Settings › Subscriptions to be notified about every new story from it."
        case .sections:
            return "Today, Unread, Saved Stories and History are always a shortcut away: ⌘1 to ⌘4."
        case .intelligence:
            return "You can turn analysis off at any time in Settings › Intelligence."
        case .notifications:
            return "Settings › Notifications chooses how much a notification shows, from the headline to a count only."
        case .done:
            return
                "J and K move between stories, S saves and M marks as read. Help › Keyboard Shortcuts lists the rest."
        }
    }
}
