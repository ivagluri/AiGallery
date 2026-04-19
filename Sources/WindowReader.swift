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

struct KeyEventMonitor: NSViewRepresentable {
    let handler: (NSEvent) -> NSEvent?

    func makeCoordinator() -> Coordinator {
        Coordinator(handler: handler)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.installMonitorIfNeeded()
        return PassthroughHelperView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.handler = handler
        context.coordinator.installMonitorIfNeeded()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        var handler: (NSEvent) -> NSEvent?
        private var monitor: Any?

        init(handler: @escaping (NSEvent) -> NSEvent?) {
            self.handler = handler
        }

        func installMonitorIfNeeded() {
            guard monitor == nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handler(event) ?? event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            removeMonitor()
        }
    }
}

private final class PassthroughHelperView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
