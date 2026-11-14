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

/// The app-wide appearance the reader picks; the raw value is stored and shown.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    var id: String { self.rawValue }

    /// The color scheme to force; nil follows the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// The reader's typographic theme; the raw value is stored.
enum ArticleThemeType: String, CaseIterable, Identifiable {
    case casper = "Ghost Casper"
    case edition = "Ghost Edition"
    case alto = "Ghost Alto"
    var id: String { self.rawValue }
    /// The theme's name without the "Ghost " prefix.
    var displayName: String { rawValue.replacingOccurrences(of: "Ghost ", with: "") }
}

/// Shared by the menu and popover; bound saved values before using them in layout.
enum ReaderTextSize {
    /// The smallest reader text scale.
    static let minimum: CGFloat = 0.85
    /// The largest reader text scale.
    static let maximum: CGFloat = 1.5
    /// `scale` clamped to `minimum` through `maximum`; 1 for a non-finite value.
    static func normalized(_ scale: CGFloat) -> CGFloat {
        scale.isFinite ? min(maximum, max(minimum, scale)) : 1
    }
    /// The scale moved by `steps` of 5 percentage points, rounded to whole percent and clamped.
    static func adjusted(_ scale: CGFloat, by steps: Int) -> CGFloat {
        normalized((normalized(scale) * 100 + CGFloat(steps) * 5).rounded() / 100)
    }
}

/// The reader's appearance, theme and text size, stored in user defaults and published to the views.
@MainActor
final class ThemeManager: ObservableObject {
    /// The instance the app uses, backed by the standard defaults.
    static let shared = ThemeManager()

    /// The app-wide appearance.
    @AppStorage("appAppearance") var appearance: AppAppearance = .system {
        willSet { objectWillChange.send() }
    }

    /// The reader's typographic theme.
    @AppStorage("articleTheme") var articleTheme: ArticleThemeType = .casper {
        willSet { objectWillChange.send() }
    }

    @AppStorage("readerTextScale") private var storedReaderTextScale: Double = 1 {
        willSet { objectWillChange.send() }
    }

    /// The reader text scale, always within `ReaderTextSize` bounds.
    var readerTextScale: CGFloat {
        get { ReaderTextSize.normalized(CGFloat(storedReaderTextScale)) }
        set { storedReaderTextScale = Double(ReaderTextSize.normalized(newValue)) }
    }

    /// A binding that writes only a change. A control that restates its own selection while SwiftUI updates a view (a
    /// menu or segmented Picker) would otherwise publish from within the update ("Publishing changes from within view
    /// updates is not allowed"), and every publish redraws every view that reads the theme.
    func binding<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<ThemeManager, Value>) -> Binding<Value> {
        Binding(
            get: { self[keyPath: keyPath] },
            set: { newValue in
                if self[keyPath: keyPath] != newValue { self[keyPath: keyPath] = newValue }
            })
    }

    /// Creates a manager that stores its values in `defaults`.
    init(defaults: UserDefaults = .standard) {
        _appearance = AppStorage(wrappedValue: .system, "appAppearance", store: defaults)
        _articleTheme = AppStorage(wrappedValue: .casper, "articleTheme", store: defaults)
        _autoHideRead = AppStorage(wrappedValue: false, "autoHideRead", store: defaults)
        _storedReaderTextScale = AppStorage(wrappedValue: 1, "readerTextScale", store: defaults)
    }

    /// Whether read stories are hidden from every list except Saved Stories.
    @AppStorage("autoHideRead") var autoHideRead: Bool = false {
        willSet { objectWillChange.send() }
    }
}
