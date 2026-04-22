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
        nsView.activateIfNeeded()
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

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        activateIfNeeded()
    }

    func activateIfNeeded() {
        guard
            let coordinator,
            coordinator.isActive,
            window?.firstResponder !== self,
            !(window?.firstResponder is NSTextView)
        else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard
                let self,
                let coordinator = self.coordinator,
                coordinator.isActive,
                self.window?.attachedSheet == nil,
                NSApp.modalWindow == nil
            else {
                return
            }
            // Only claim first responder when no interactive control has it.
            // If a button or text field currently holds focus, leave it alone.
            let fr = self.window?.firstResponder
            guard fr == nil || fr is NSWindow else { return }

            self.window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        if coordinator?.handler(event) == true {
            return
        }

        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if coordinator?.handler(event) == true {
            return
        }

        super.keyUp(with: event)
    }
}
