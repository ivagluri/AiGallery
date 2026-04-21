import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var isLegacyExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Welcome to AiGallery")
                    .font(.title2.weight(.semibold))

                Text("Open your image folder to begin.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            Button {
                settings.isShowingWelcome = false

                DispatchQueue.main.async {
                    if library.chooseRootFolder() {
                        settings.completeWelcome()
                    } else {
                        settings.isShowingWelcome = true
                    }
                }
            } label: {
                Label("Open Image Folder", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: isLegacyExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)

                    Text("Legacy Mode")
                        .font(.subheadline.weight(.semibold))

                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isLegacyExpanded.toggle()
                    }
                }

                if isLegacyExpanded {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 0) {
                            Text("Enable this if you want compatibility with TagExplorer-style `gens` folders and category parsing.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .allowsHitTesting(false)

                        Button {
                            library.setAppMode(.tagExplorerLegacy)
                        } label: {
                            Label(
                                settings.appMode == .tagExplorerLegacy ? "Legacy Mode Enabled" : "Enable Legacy Mode",
                                systemImage: settings.appMode == .tagExplorerLegacy ? "checkmark.circle.fill" : "square.stack.3d.up"
                            )
                        }
                        .buttonStyle(.bordered)
                        .disabled(settings.appMode == .tagExplorerLegacy)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 1)
            )

            Text("You can change this later from the Mode menu.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 420)
    }
}
