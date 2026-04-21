import Foundation
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    var id: String { self.rawValue }
    
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum ArticleThemeType: String, CaseIterable, Identifiable {
    case casper = "Ghost Casper"
    case edition = "Ghost Edition"
    case alto = "Ghost Alto"
    var id: String { self.rawValue }
}

class ThemeManager: ObservableObject {
    static let shared = ThemeManager()
    
    @AppStorage("appAppearance") var appearance: AppAppearance = .dark {
        willSet { objectWillChange.send() }
    }
    
    @AppStorage("articleTheme") var articleTheme: ArticleThemeType = .casper {
        willSet { objectWillChange.send() }
    }
    
    @AppStorage("autoHideRead") var autoHideRead: Bool = false {
        willSet { objectWillChange.send() }
    }
}
