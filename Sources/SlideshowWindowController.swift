import AppKit
import SwiftUI

// MARK: - ViewModel (observed by SlideshowRootView)

@MainActor
final class SlideshowViewModel: ObservableObject {
    @Published var currentImage: ImageItem?
    @Published var currentMetadata: ImageMetadata?
    @Published var isPaused = false
    @Published var imageCount = 0
    @Published var displayIndex = 0
    @Published var settings: SlideshowSettingsSnapshot

    init(settings: SlideshowSettingsSnapshot) {
        self.settings = settings
    }
}

// MARK: - Controller

@MainActor
final class SlideshowWindowController: NSObject, NSWindowDelegate {
    static let shared = SlideshowWindowController()

    private(set) var isPresented = false
    private var window: NSWindow?
    private var hostingController: NSHostingController<SlideshowRootView>?

    private var images: [ImageItem] = []
    private var currentIndex: Int = 0
    private var shuffleOrder: [Int] = []
    private var timer: Timer?
    private var prefetchTask: Task<Void, Never>?
    private(set) var viewModel = SlideshowViewModel(settings: SlideshowSettings.shared.snapshot())

    weak var metadataSource: LibraryStore?

    private override init() {}

    // MARK: - Present

    func present(images: [ImageItem], startIndex: Int, settings: SlideshowSettingsSnapshot, metadataSource: LibraryStore) {
        guard !images.isEmpty else { return }
        dismiss()

        self.images = images
        self.metadataSource = metadataSource
        self.currentIndex = max(0, min(startIndex, images.count - 1))

        viewModel = SlideshowViewModel(settings: settings)
        viewModel.isPaused = false
        viewModel.imageCount = images.count

        if settings.playbackOrder == .random {
            shuffleOrder = shuffled(count: images.count, pinning: currentIndex)
        }

        syncViewModel()

        let rootView = SlideshowRootView(viewModel: viewModel, controller: self)
        let hosting = NSHostingController(rootView: rootView)
        self.hostingController = hosting

        let screen = NSScreen.main ?? NSScreen.screens.first!
        let sf = screen.visibleFrame
        let winW = min(1200, sf.width  * 0.75)
        let winH = min(800,  sf.height * 0.75)
        let startRect = CGRect(x: sf.midX - winW / 2, y: sf.midY - winH / 2, width: winW, height: winH)
        let win = NSWindow(
            contentRect: startRect,
            // .resizable is required for toggleFullScreen to succeed
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.collectionBehavior = [.fullScreenPrimary]
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.backgroundColor = settings.nsBackgroundColor
        win.contentViewController = hosting
        win.delegate = self
        win.isReleasedWhenClosed = false
        self.window = win
        isPresented = true

        win.makeKeyAndOrderFront(nil)
        // Defer toggleFullScreen one runloop tick to let the window fully present
        DispatchQueue.main.async {
            win.toggleFullScreen(nil)
        }

        scheduleTimer()
        prefetchNext()
    }

    // MARK: - Dismiss

    func dismiss() {
        guard isPresented, let win = window else { return }
        stopTimer()
        prefetchTask?.cancel()
        isPresented = false
        if win.styleMask.contains(.fullScreen) {
            win.toggleFullScreen(nil)
            // window closed in windowDidExitFullScreen
        } else {
            win.close()
            cleanup()
        }
    }

    // MARK: - Navigation

    func advance() {
        guard !images.isEmpty else { return }
        if let next = nextIndex(after: currentIndex) {
            currentIndex = next
            syncViewModel()
            prefetchNext()
            scheduleTimer()
        } else {
            dismiss()
        }
    }

    func retreat() {
        guard !images.isEmpty else { return }
        currentIndex = prevIndex(before: currentIndex)
        syncViewModel()
    }

    func togglePause() {
        viewModel.isPaused.toggle()
        if viewModel.isPaused {
            stopTimer()
        } else {
            scheduleTimer()
        }
    }

    func resetTimer() {
        guard !viewModel.isPaused else { return }
        stopTimer()
        scheduleTimer()
    }

    // MARK: - Timer

    private func scheduleTimer() {
        stopTimer()
        guard !viewModel.isPaused, viewModel.settings.duration > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: viewModel.settings.duration, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.advance() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Index math

    private func nextIndex(after index: Int) -> Int? {
        if viewModel.settings.playbackOrder == .random {
            guard let pos = shuffleOrder.firstIndex(of: index) else { return nil }
            let nextPos = pos + 1
            if nextPos < shuffleOrder.count { return shuffleOrder[nextPos] }
            if viewModel.settings.loopEnabled {
                shuffleOrder = shuffled(count: images.count, pinning: shuffleOrder.last)
                return shuffleOrder.first
            }
            return nil
        }
        let next = index + 1
        if next < images.count { return next }
        if viewModel.settings.loopEnabled { return 0 }
        return nil
    }

    private func prevIndex(before index: Int) -> Int {
        if viewModel.settings.playbackOrder == .random {
            if let pos = shuffleOrder.firstIndex(of: index), pos > 0 {
                return shuffleOrder[pos - 1]
            }
            return index
        }
        return max(0, index - 1)
    }

    private func shuffled(count: Int, pinning first: Int? = nil) -> [Int] {
        var order = Array(0..<count)
        for i in stride(from: count - 1, through: 1, by: -1) {
            let j = Int.random(in: 0...i)
            order.swapAt(i, j)
        }
        if let pinned = first, let pos = order.firstIndex(of: pinned) {
            order.swapAt(0, pos)
        }
        return order
    }

    // MARK: - Prefetch

    private func prefetchNext() {
        prefetchTask?.cancel()
        guard let next = nextIndex(after: currentIndex) else { return }
        let url = images[next].fileURL
        prefetchTask = Task.detached(priority: .utility) {
            _ = await SafeImageLoader.loadImageAsync(for: url, maximumThumbnailDimension: 4096)
        }
    }

    // MARK: - ViewModel sync

    private func syncViewModel() {
        let image = images.indices.contains(currentIndex) ? images[currentIndex] : nil
        viewModel.currentImage = image
        viewModel.displayIndex = currentIndex + 1
        viewModel.currentMetadata = nil
        guard let image, let source = metadataSource else { return }
        Task.detached(priority: .utility) { [weak source] in
            let meta = source?.inspectorMetadata(for: image)
            await MainActor.run { [weak self] in self?.viewModel.currentMetadata = meta }
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidExitFullScreen(_ notification: Notification) {
        window?.close()
        cleanup()
    }

    func windowWillClose(_ notification: Notification) {
        cleanup()
    }

    private func cleanup() {
        stopTimer()
        prefetchTask?.cancel()
        prefetchTask = nil
        window?.delegate = nil
        window = nil
        hostingController = nil
        images = []
        isPresented = false
    }
}
