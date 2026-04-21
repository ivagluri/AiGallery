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
    @Published var isShowingWelcome: Bool

    private let userDefaults: UserDefaults
    private static let appModeDefaultsKey = "appMode"
    private static let didCompleteWelcomeDefaultsKey = "didCompleteWelcome"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        // Temporary for first-run verification: always show the welcome flow on launch.
        // self.isShowingWelcome = !userDefaults.bool(forKey: Self.didCompleteWelcomeDefaultsKey)
        self.isShowingWelcome = true

        if
            let rawValue = userDefaults.string(forKey: Self.appModeDefaultsKey),
            let storedMode = AppMode(rawValue: rawValue)
        {
            self.appMode = storedMode
        } else {
            self.appMode = .general
        }
    }

    func completeWelcome() {
        userDefaults.set(true, forKey: Self.didCompleteWelcomeDefaultsKey)
        isShowingWelcome = false
    }
}
