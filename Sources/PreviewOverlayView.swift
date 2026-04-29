import AppKit
import SwiftUI

struct PreviewOverlayView: View {
    let session: PreviewOverlaySession
    let onBackgroundTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isVisible = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Rectangle()
                    .fill(backdropColor)
                    .ignoresSafeArea()
                    .onTapGesture {
                        onBackgroundTap()
                    }

                previewSurface(in: proxy.size)
                    .opacity(isVisible ? 1 : 0)
                    .animation(.linear(duration: 0.08), value: isVisible)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.clear)
        .onAppear {
            isVisible = true
        }
    }

    @MainActor private func previewSurface(in availableSize: CGSize) -> some View {
        let metrics = dynamicMetrics(for: availableSize)
        let layout = previewLayout(for: availableSize)

        return VStack(spacing: layout.controlSpacing) {
            Group {
                if let imageURL = session.image?.fileURL {
                    PreviewOverlayImage(imageURL: imageURL)
                        .frame(
                            width: layout.imageDisplaySize.width,
                            height: layout.imageDisplaySize.height
                        )
                        .padding(.horizontal, layout.imagePadding.width)
                        .padding(.vertical, layout.imagePadding.height)
                } else {
                    PlaceholderView(title: "No Preview", systemImage: "photo")
                        .frame(
                            width: layout.imageDisplaySize.width,
                            height: layout.imageDisplaySize.height
                        )
                        .padding(.horizontal, layout.imagePadding.width)
                        .padding(.vertical, layout.imagePadding.height)
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            }
            .overlay {
                if session.overlayPreset != .none, let image = session.image {
                    SlideshowOverlayView(
                        preset: session.overlayPreset,
                        promptContent: SlideshowSettings.shared.promptContent,
                        position: SlideshowSettings.shared.overlayPosition,
                        image: image,
                        metadata: session.metadata,
                        bottomClearance: 20
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                }
            }
            .shadow(color: shadowColor, radius: 36, y: 12)
            .onTapGesture(count: 2) {
                onBackgroundTap()
            }

            previewControls(metrics: metrics)
        }
        .frame(width: layout.viewerSize.width, height: layout.viewerSize.height)
    }

    @ViewBuilder
    private func previewControls(metrics: PreviewDynamicMetrics) -> some View {
        let showsControls = session.capabilities.supportsNavigation
            || session.capabilities.supportsFavorite
            || session.capabilities.supportsSlideshow

        if showsControls {
            HStack(spacing: metrics.controlButtonSpacing) {
                if session.capabilities.supportsNavigation {
                    overlayButton(
                        systemImage: "chevron.left",
                        metrics: metrics,
                        isEnabled: session.canNavigatePrevious
                    ) {
                        session.onNavigate?(.previous)
                    }
                }

                if session.capabilities.supportsFavorite {
                    overlayButton(
                        systemImage: session.isFavorite ? "star.fill" : "star",
                        metrics: metrics,
                        isEmphasized: session.isFavorite
                    ) {
                        session.onToggleFavorite?()
                    }
                }

                if session.capabilities.supportsNavigation {
                    overlayButton(
                        systemImage: "chevron.right",
                        metrics: metrics,
                        isEnabled: session.canNavigateNext
                    ) {
                        session.onNavigate?(.next)
                    }
                }

                if session.capabilities.supportsSlideshow {
                    Rectangle()
                        .fill(buttonBorderColor.opacity(0.5))
                        .frame(width: 1, height: metrics.controlButtonDiameter * 0.6)
                        .padding(.horizontal, 2)

                    overlayButton(
                        systemImage: "play.circle",
                        metrics: metrics
                    ) {
                        session.onStartSlideshow?()
                    }
                }
            }
            .padding(.horizontal, metrics.controlClusterHorizontalPadding)
            .padding(.vertical, metrics.controlClusterVerticalPadding)
            .background(controlClusterBackground, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .stroke(buttonBorderColor.opacity(colorScheme == .dark ? 0.9 : 0.8), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.10), radius: 16, y: 6)
        }
    }

    private var backdropColor: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.66)
            : Color.black.opacity(0.42)
    }

    private var borderColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.14)
            : Color.white.opacity(0.48)
    }

    private var shadowColor: Color {
        Color.black.opacity(colorScheme == .dark ? 0.42 : 0.18)
    }

    private func overlayButton(
        systemImage: String,
        metrics: PreviewDynamicMetrics,
        isEmphasized: Bool = false,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: metrics.controlIconSize, weight: .semibold))
                .foregroundStyle(iconColor(isEmphasized: isEmphasized, isEnabled: isEnabled))
                .frame(width: metrics.controlButtonDiameter, height: metrics.controlButtonDiameter)
                .background(buttonBackground(isEnabled: isEnabled), in: Circle())
                .overlay {
                    Circle()
                        .stroke(buttonBorderColor.opacity(isEnabled ? 1 : 0.55), lineWidth: 1)
                }
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.12), radius: 14, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private func buttonBackground(isEnabled: Bool) -> Color {
        let base = colorScheme == .dark
            ? Color.black.opacity(0.24)
            : Color.white.opacity(0.36)
        return isEnabled ? base : base.opacity(0.55)
    }

    private var buttonBorderColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.white.opacity(0.55)
    }

    private var controlClusterBackground: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.18)
            : Color.white.opacity(0.24)
    }

    private func iconColor(isEmphasized: Bool, isEnabled: Bool) -> Color {
        guard isEnabled else {
            return colorScheme == .dark ? Color.white.opacity(0.32) : Color.primary.opacity(0.28)
        }

        if isEmphasized {
            return Color(
                red: 255.0 / 255.0,
                green: 218.0 / 255.0,
                blue: 107.0 / 255.0
            )
        }

        return colorScheme == .dark ? Color.white.opacity(0.92) : Color.primary.opacity(0.88)
    }

    private func previewLayout(for availableSize: CGSize) -> PreviewLayout {
        let metrics = dynamicMetrics(for: availableSize)
        let screenInsetX = max(availableSize.width * 0.015, 9)
        let screenInsetY = max(availableSize.height * 0.0175, 9)
        let controlHeight: CGFloat = previewControlsVisible ? metrics.controlClusterHeight : 0
        let controlSpacing: CGFloat = previewControlsVisible ? metrics.controlSpacing : 0

        let maxViewerWidth = max(availableSize.width - screenInsetX * 2, 320)
        let maxViewerHeight = max(availableSize.height - screenInsetY * 2, 240)
        let maxSurfaceHeight = max(maxViewerHeight - controlHeight - controlSpacing, 180)
        let aspectRatio = previewAspectRatio
        let imagePadding = imagePadding(for: aspectRatio, metrics: metrics)

        let maxImageWidth = max(maxViewerWidth - imagePadding.width * 2, 180)
        let maxImageHeight = max(maxSurfaceHeight - imagePadding.height * 2, 180)
        let imageDisplaySize = fittedSize(
            aspectRatio: aspectRatio,
            maxWidth: maxImageWidth,
            maxHeight: maxImageHeight
        )

        let surfaceSize = CGSize(
            width: imageDisplaySize.width + imagePadding.width * 2,
            height: imageDisplaySize.height + imagePadding.height * 2
        )

        let viewerWidth = max(surfaceSize.width, previewControlsVisible ? 220 : 0)
        let viewerHeight = surfaceSize.height + controlSpacing + controlHeight

        return PreviewLayout(
            imageDisplaySize: imageDisplaySize,
            imagePadding: imagePadding,
            viewerSize: CGSize(width: viewerWidth, height: viewerHeight),
            controlSpacing: controlSpacing
        )
    }

    private var previewAspectRatio: CGFloat {
        guard
            let imageURL = session.image?.fileURL,
            let pixelSize = SafeImageLoader.imagePixelSize(for: imageURL),
            pixelSize.width > 0,
            pixelSize.height > 0
        else {
            return 1
        }

        return pixelSize.width / pixelSize.height
    }

    private var previewControlsVisible: Bool {
        session.capabilities.supportsNavigation || session.capabilities.supportsFavorite
    }

    private func imagePadding(for aspectRatio: CGFloat, metrics: PreviewDynamicMetrics) -> CGSize {
        if aspectRatio >= 1.35 {
            return CGSize(width: metrics.wideImagePadding, height: metrics.wideImagePadding)
        }

        if aspectRatio <= 0.8 {
            return CGSize(width: metrics.portraitImagePadding, height: metrics.portraitImagePadding)
        }

        return CGSize(width: metrics.standardImagePadding, height: metrics.standardImagePadding)
    }

    private func fittedSize(aspectRatio: CGFloat, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        guard aspectRatio > 0 else {
            let side = min(maxWidth, maxHeight)
            return CGSize(width: side, height: side)
        }

        let widthLimitedHeight = maxWidth / aspectRatio
        if widthLimitedHeight <= maxHeight {
            return CGSize(width: maxWidth, height: widthLimitedHeight)
        }

        return CGSize(width: maxHeight * aspectRatio, height: maxHeight)
    }

    private func dynamicMetrics(for availableSize: CGSize) -> PreviewDynamicMetrics {
        let widthScale = availableSize.width / 2560
        let heightScale = availableSize.height / 1440
        let paddingScale = min(max(min(widthScale, heightScale), 0.9), 1.2)
        let controlScale = min(max(min(widthScale, heightScale), 0.92), 1.15)

        return PreviewDynamicMetrics(
            standardImagePadding: 10 * paddingScale,
            portraitImagePadding: 13 * paddingScale,
            wideImagePadding: 12 * paddingScale,
            controlButtonDiameter: 48 * controlScale,
            controlIconSize: 17 * controlScale,
            controlButtonSpacing: 14 * controlScale,
            controlClusterHorizontalPadding: 14 * controlScale,
            controlClusterVerticalPadding: 10 * controlScale,
            controlClusterHeight: 68 * controlScale,
            controlSpacing: 18 * controlScale
        )
    }
}

private struct PreviewLayout {
    let imageDisplaySize: CGSize
    let imagePadding: CGSize
    let viewerSize: CGSize
    let controlSpacing: CGFloat
}

private struct PreviewDynamicMetrics {
    let standardImagePadding: CGFloat
    let portraitImagePadding: CGFloat
    let wideImagePadding: CGFloat
    let controlButtonDiameter: CGFloat
    let controlIconSize: CGFloat
    let controlButtonSpacing: CGFloat
    let controlClusterHorizontalPadding: CGFloat
    let controlClusterVerticalPadding: CGFloat
    let controlClusterHeight: CGFloat
    let controlSpacing: CGFloat
}

private struct PreviewOverlayImage: View {
    let imageURL: URL

    var body: some View {
        Group {
            switch SafeImageLoader.loadImage(for: imageURL, maximumThumbnailDimension: 3_072) {
            case .success(let nsImage):
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            case .blocked(let reason):
                PlaceholderView(title: reason.title, systemImage: "shield", description: reason.message)
                    .frame(minWidth: 320, minHeight: 240)
            case .failed:
                PlaceholderView(title: "No Preview", systemImage: "photo")
                    .frame(minWidth: 320, minHeight: 240)
            }
        }
    }
}

