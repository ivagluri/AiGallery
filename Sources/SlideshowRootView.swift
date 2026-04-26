import AppKit
import SwiftUI

// MARK: - Root

struct SlideshowRootView: View {
    @ObservedObject var viewModel: SlideshowViewModel
    let controller: SlideshowWindowController

    @State private var hudVisible = false
    @State private var hudHideTask: DispatchWorkItem?

    var body: some View {
        ZStack(alignment: .bottom) {
            viewModel.settings.swiftUIBackgroundColor
                .ignoresSafeArea()

            if let image = viewModel.currentImage {
                SlideshowImageView(
                    item: image,
                    fitMode: viewModel.settings.imageFitMode,
                    transition: viewModel.settings.transition
                )
            }

            if hudVisible {
                SlideshowControlsHUD(
                    isPaused: viewModel.isPaused,
                    displayIndex: viewModel.displayIndex,
                    imageCount: viewModel.imageCount,
                    onPrevious: { controller.retreat(); controller.resetTimer() },
                    onNext: { controller.advance(); controller.resetTimer() },
                    onTogglePause: { controller.togglePause() },
                    onExit: { controller.dismiss() }
                )
                .padding(.bottom, 32)
                .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }

            SlideshowKeyView { event in
                handleKey(event)
            }
            .frame(width: 0, height: 0)
        }
        .ignoresSafeArea()
        .onContinuousHover { phase in
            switch phase {
            case .active:
                showHUD()
            case .ended:
                scheduleHUDHide(delay: 2.5)
            }
        }
    }

    // MARK: - Key handling

    @MainActor
    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let mod = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mod.isDisjoint(with: [.command, .option]) else { return false }

        switch event.keyCode {
        case 49: // Space
            controller.togglePause()
            return true
        case 53: // Esc
            controller.dismiss()
            return true
        case 123: // Left arrow
            controller.retreat()
            controller.resetTimer()
            return true
        case 124: // Right arrow
            controller.advance()
            controller.resetTimer()
            return true
        default:
            return false
        }
    }

    // MARK: - HUD

    private func showHUD() {
        hudHideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { hudVisible = true }
        scheduleHUDHide(delay: 3.0)
    }

    private func scheduleHUDHide(delay: TimeInterval) {
        hudHideTask?.cancel()
        let task = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.4)) { hudVisible = false }
        }
        hudHideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }
}

// MARK: - Image View

private struct SlideshowImageView: View {
    let item: ImageItem
    let fitMode: SlideshowImageFitMode
    let transition: SlideshowTransition

    @State private var loadedImage: NSImage?

    var body: some View {
        GeometryReader { geo in
            if let img = loadedImage {
                imageContent(img, in: geo.size)
                    .id(item.id)
                    .transition(transitionEffect)
                    .animation(.easeInOut(duration: 0.3), value: item.id)
            }
        }
        .task(id: item.id) {
            loadedImage = nil
            let result = await SafeImageLoader.loadImageAsync(for: item.fileURL, maximumThumbnailDimension: 4096)
            if case .success(let img) = result {
                loadedImage = img
            }
        }
    }

    @ViewBuilder
    private func imageContent(_ img: NSImage, in size: CGSize) -> some View {
        let swiftImage = Image(nsImage: img)
        switch fitMode {
        case .fit:
            swiftImage.resizable().scaledToFit()
                .frame(width: size.width, height: size.height)
        case .fill:
            swiftImage.resizable().scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
        case .center:
            swiftImage
                .frame(width: size.width, height: size.height)
        case .stretch:
            swiftImage.resizable()
                .frame(width: size.width, height: size.height)
        }
    }

    private var transitionEffect: AnyTransition {
        switch transition {
        case .crossfade: return .opacity
        case .none: return .identity
        }
    }
}

// MARK: - HUD

private struct SlideshowControlsHUD: View {
    let isPaused: Bool
    let displayIndex: Int
    let imageCount: Int
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onTogglePause: () -> Void
    let onExit: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            hudButton(systemImage: "chevron.left", action: onPrevious)
            hudButton(systemImage: isPaused ? "play.fill" : "pause.fill", action: onTogglePause)

            Text("\(displayIndex) / \(imageCount)")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary)
                .frame(minWidth: 60)

            hudButton(systemImage: "chevron.right", action: onNext)

            Divider()
                .frame(height: 20)
                .opacity(0.5)

            hudButton(systemImage: "xmark", action: onExit)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
    }

    private func hudButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Key Handler

fileprivate struct SlideshowKeyView: NSViewRepresentable {
    let onKeyDown: (NSEvent) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(onKeyDown: onKeyDown) }

    func makeNSView(context: Context) -> SlideshowKeyHandlerView {
        let view = SlideshowKeyHandlerView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: SlideshowKeyHandlerView, context: Context) {
        context.coordinator.onKeyDown = onKeyDown
    }

    final class Coordinator {
        var onKeyDown: (NSEvent) -> Bool
        init(onKeyDown: @escaping (NSEvent) -> Bool) { self.onKeyDown = onKeyDown }
    }
}

fileprivate final class SlideshowKeyHandlerView: NSView {
    var coordinator: SlideshowKeyView.Coordinator?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if coordinator?.onKeyDown(event) == true { return }
        super.keyDown(with: event)
    }
}
