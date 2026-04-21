import Combine
import Foundation

enum AppMode: String, CaseIterable, Identifiable {
    case general
    case tagExplorerLegacy

    var id: String { rawValue }
}

final class AppSettings: ObservableObject {
    @Published var appMode: AppMode {
        didSet {
            userDefaults.set(appMode.rawValue, forKey: Self.appModeDefaultsKey)
        }
    }

    private let userDefaults: UserDefaults
    private static let appModeDefaultsKey = "appMode"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        if
            let rawValue = userDefaults.string(forKey: Self.appModeDefaultsKey),
            let storedMode = AppMode(rawValue: rawValue)
        {
            self.appMode = storedMode
        } else {
            // Preserve the current startup behavior until the general-mode migration is complete.
            self.appMode = .tagExplorerLegacy
        }
    }
}
