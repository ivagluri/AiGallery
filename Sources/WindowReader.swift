import AppKit
import SwiftUI

struct HostWindowReader: NSViewRepresentable {
    let onWindowChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowReaderView {
        let view = WindowReaderView()
        view.onWindowChange = onWindowChange
        return view
    }

    func updateNSView(_ nsView: WindowReaderView, context: Context) {
        nsView.onWindowChange = onWindowChange
        nsView.publishWindowIfNeeded()
    }
}

final class WindowReaderView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?
    private weak var observedWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        publishWindowIfNeeded()
    }

    func publishWindowIfNeeded() {
        guard observedWindow !== window else { return }
        observedWindow = window
        DispatchQueue.main.async { [weak self] in
            self?.onWindowChange?(self?.window)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

struct KeyAwareView: NSViewRepresentable {
    let isActive: Bool
    let handler: (NSEvent) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(handler: handler, isActive: isActive)
    }

    func makeNSView(context: Context) -> KeyHandlingView {
        let view = KeyHandlingView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: KeyHandlingView, context: Context) {
        context.coordinator.handler = handler
        context.coordinator.isActive = isActive
        nsView.coordinator = context.coordinator
    }

    final class Coordinator {
        var handler: (NSEvent) -> Bool
        var isActive: Bool

        init(handler: @escaping (NSEvent) -> Bool, isActive: Bool) {
            self.handler = handler
            self.isActive = isActive
        }
    }
}

final class KeyHandlingView: NSView {
    var coordinator: KeyAwareView.Coordinator?
    private var eventMonitorToken: Any?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { installMonitor() } else { removeMonitor() }
    }

    private func installMonitor() {
        guard eventMonitorToken == nil else { return }
        eventMonitorToken = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self,
                  let coordinator = self.coordinator,
                  coordinator.isActive else { return event }
            return coordinator.handler(event) ? nil : event
        }
    }

    private func removeMonitor() {
        if let token = eventMonitorToken {
            NSEvent.removeMonitor(token)
            eventMonitorToken = nil
        }
    }

    deinit { removeMonitor() }

    // Secondary path if the view ever becomes first responder via the normal chain.
    override func keyDown(with event: NSEvent) {
        if coordinator?.handler(event) == true { return }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if coordinator?.handler(event) == true { return }
        super.keyUp(with: event)
    }
}
