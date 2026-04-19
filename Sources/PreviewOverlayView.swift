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
                    .scaleEffect(isVisible ? 1 : 0.965)
                    .opacity(isVisible ? 1 : 0)
                    .animation(.easeOut(duration: 0.16), value: isVisible)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.clear)
        .onAppear {
            isVisible = true
        }
    }

    private func previewSurface(in availableSize: CGSize) -> some View {
        let horizontalPadding = max(availableSize.width * 0.07, 36)
        let verticalPadding = max(availableSize.height * 0.08, 36)

        return Group {
            if let imageURL = session.image?.fileURL {
                PreviewOverlayImage(imageURL: imageURL)
                    .padding(22)
            } else {
                PreviewOverlayPlaceholder(title: "No Preview", systemImage: "photo")
                    .frame(width: min(availableSize.width * 0.6, 520), height: min(availableSize.height * 0.5, 360))
                    .padding(22)
            }
        }
        .frame(
            maxWidth: max(availableSize.width - horizontalPadding * 2, 320),
            maxHeight: max(availableSize.height - verticalPadding * 2, 240)
        )
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        }
        .shadow(color: shadowColor, radius: 36, y: 12)
        .onTapGesture {
            // Keep the preview passive for v1 while preserving a hit target
            // that future controls can build on without changing dismissal.
        }
    }

    private var backdropColor: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.56)
            : Color.black.opacity(0.34)
    }

    private var borderColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.14)
            : Color.white.opacity(0.48)
    }

    private var shadowColor: Color {
        Color.black.opacity(colorScheme == .dark ? 0.42 : 0.18)
    }
}

private struct PreviewOverlayImage: View {
    let imageURL: URL

    var body: some View {
        Group {
            if let nsImage = NSImage(contentsOf: imageURL) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                PreviewOverlayPlaceholder(title: "No Preview", systemImage: "photo")
                    .frame(minWidth: 320, minHeight: 240)
            }
        }
    }
}

private struct PreviewOverlayPlaceholder: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
