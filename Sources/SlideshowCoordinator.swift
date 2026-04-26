import Foundation

@MainActor
final class SlideshowCoordinator: ObservableObject {
    static let shared = SlideshowCoordinator()

    @Published var launchRequested = false

    private init() {}

    func requestLaunch() {
        launchRequested = true
    }
}
