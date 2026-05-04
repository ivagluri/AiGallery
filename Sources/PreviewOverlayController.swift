import AppKit
import SwiftUI

struct PreviewOverlayCapabilities {
    var supportsNavigation = false
    var supportsFavorite = false
    var supportsMetadata = false
    var supportsSlideshow = false
}

struct PreviewOverlaySession {
    let image: ImageItem?
    var capabilities = PreviewOverlayCapabilities()
    var isFavorite = false
    var canNavigatePrevious = false
    var canNavigateNext = false
    var onNavigate: ((PreviewOverlayNavigationAction) -> Void)?
    var onToggleFavorite: (() -> Void)?
    var onTrash: (() -> Void)?
    var onStartSlideshow: (() -> Void)?
    var metadata: ImageMetadata?
    var overlayPreset: SlideshowOverlayPreset = .none
}

enum PreviewOverlayNavigationAction {
    case previous
    case next
    case up
    case down
    case pageUp
    case pageDown
    case home
    case end
}

@MainActor
final class PreviewOverlayController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isPresented = false

    private weak var sourceWindow: NSWindow?
    private var panel: PreviewOverlayPanel?
    private var hostingController: NSHostingController<PreviewOverlayView>?
    private var keyMonitor: Any?
    private var notificationObservers: [NSObjectProtocol] = []
    private var activeSession: PreviewOverlaySession?
    private var currentOverlayPreset: SlideshowOverlayPreset = {
        let raw = UserDefaults.standard.string(forKey: "previewOverlayPreset") ?? ""
        return SlideshowOverlayPreset(rawValue: raw) ?? .none
    }()

    func present(session: PreviewOverlaySession, from sourceWindow: NSWindow?) {
        guard session.image != nil, let sourceWindow else {
            dismiss()
            return
        }

        show(session: session, from: sourceWindow)
    }

    func dismiss() {
        guard let panel else { return }

        removeObservers()
        activeSession = nil
        isPresented = false

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
            panel.alphaValue = 1
            panel.contentViewController = nil
            self.hostingController = nil
            self.panel = nil
            self.sourceWindow = nil
        }
    }

    func update(session: PreviewOverlaySession) {
        activeSession = session

        guard isPresented else { return }

        guard session.image != nil else {
            dismiss()
            return
        }

        hostingController?.rootView = makeView(for: session)
    }

    private func makeView(for session: PreviewOverlaySession) -> PreviewOverlayView {
        var s = session
        s.overlayPreset = currentOverlayPreset
        return PreviewOverlayView(session: s) { [weak self] in self?.dismiss() }
    }

    private func show(session: PreviewOverlaySession, from sourceWindow: NSWindow) {
        guard let image = session.image else {
            dismiss()
            return
        }

        dismiss()

        self.sourceWindow = sourceWindow
        activeSession = session

        let panel = PreviewOverlayPanel(frame: targetFrame(for: sourceWindow))
        panel.delegate = self

        let rootView = makeView(for: session)
        let hostingController = NSHostingController(rootView: rootView)
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor

        panel.contentViewController = hostingController
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.center()

        self.panel = panel
        self.hostingController = hostingController
        isPresented = true

        installObservers(for: sourceWindow)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 1
        }

        // Keep the main app active while the preview floats above it.
        NSApp.activate(ignoringOtherApps: true)

        // Update the frame again after ordering so the panel stays on the source display.
        panel.setFrame(targetFrame(for: sourceWindow), display: true)

        _ = image
    }

    private func targetFrame(for sourceWindow: NSWindow) -> NSRect {
        if let visibleFrame = sourceWindow.screen?.visibleFrame {
            return visibleFrame
        }

        if let visibleFrame = NSScreen.main?.visibleFrame {
            return visibleFrame
        }

        return NSRect(x: 80, y: 80, width: 1200, height: 800)
    }

    private func installObservers(for sourceWindow: NSWindow) {
        let notificationCenter = NotificationCenter.default

        notificationObservers = [
            notificationCenter.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.dismiss()
                }
            },
            notificationCenter.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: sourceWindow,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.dismiss()
                }
            },
            notificationCenter.addObserver(
                forName: NSWindow.willCloseNotification,
                object: sourceWindow,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.dismiss()
                }
            }
        ]

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, self.isPresented else {
                return event
            }

            if event.type == .keyUp {
                return nil
            }

            let disallowedModifiers = event.modifierFlags.intersection([.command, .control, .option])
            guard disallowedModifiers.isEmpty else {
                return event
            }

            switch event.keyCode {
            case 49, 53:
                Task { @MainActor [weak self] in
                    self?.dismiss()
                }
                return nil
            case 123:
                self.activeSession?.onNavigate?(.previous)
                return nil
            case 124:
                self.activeSession?.onNavigate?(.next)
                return nil
            case 125:
                self.activeSession?.onNavigate?(.down)
                return nil
            case 126:
                self.activeSession?.onNavigate?(.up)
                return nil
            case 116:
                self.activeSession?.onNavigate?(.pageUp)
                return nil
            case 121:
                self.activeSession?.onNavigate?(.pageDown)
                return nil
            case 115:
                self.activeSession?.onNavigate?(.home)
                return nil
            case 119:
                self.activeSession?.onNavigate?(.end)
                return nil
            case 3:
                self.activeSession?.onToggleFavorite?()
                return nil
            case 51:
                self.activeSession?.onTrash?()
                return nil
            case 35: // p — cycle info overlay
                self.currentOverlayPreset = self.currentOverlayPreset.next
                UserDefaults.standard.set(self.currentOverlayPreset.rawValue, forKey: "previewOverlayPreset")
                if let session = self.activeSession {
                    self.hostingController?.rootView = self.makeView(for: session)
                }
                return nil
            default:
                return nil
            }
        }
    }

    private func removeObservers() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }

        let notificationCenter = NotificationCenter.default
        for observer in notificationObservers {
            notificationCenter.removeObserver(observer)
        }
        notificationObservers.removeAll()
    }

    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }
}

private final class PreviewOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {}

    override func keyUp(with event: NSEvent) {}

    init(frame: NSRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        hasShadow = false
        backgroundColor = .clear
        isOpaque = false
        collectionBehavior = [.transient, .ignoresCycle]
        animationBehavior = .utilityWindow
    }
}

