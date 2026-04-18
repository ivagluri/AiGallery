import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var expandedGroupIDs: Set<String> = []

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            thumbnailGrid
        } detail: {
            inspector
        }
        .navigationTitle("Tag Browser")
        .toolbar {
            ToolbarItemGroup {
                Button("Reload") {
                    library.reload()
                }

                Button("Choose Folder…") {
                    library.chooseRootFolder()
                }
            }
        }
        .onAppear {
            expandAllGroupsIfNeeded()
        }
        .onChange(of: library.categoryGroups.map(\.id)) { _ in
            expandAllGroupsIfNeeded()
        }
    }

    private var sidebar: some View {
        List(selection: categorySelectionBinding) {
            ForEach(library.categoryGroups) { group in
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expandedGroupIDs.contains(group.id) },
                        set: { isExpanded in
                            if isExpanded {
                                expandedGroupIDs.insert(group.id)
                            } else {
                                expandedGroupIDs.remove(group.id)
                            }
                        }
                    )
                ) {
                    ForEach(group.categories) { category in
                        Button {
                            library.selectCategory(category)
                        } label: {
                            HStack {
                                Text(category.shortName)
                                    .lineLimit(2)
                                Spacer()
                                Text("\(category.images.count)")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(category.id == library.selectedCategory?.id ? Color.accentColor.opacity(0.14) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                        .tag(category.id)
                    }
                } label: {
                    HStack {
                        Text(group.name)
                            .font(.headline)
                        Spacer()
                        Text("\(group.categories.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .overlay {
            if library.categories.isEmpty {
                PlaceholderView(title: "No Categories", systemImage: "folder")
            }
        }
    }

    private var thumbnailGrid: some View {
        Group {
            if let category = library.selectedCategory {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 16)],
                        spacing: 16
                    ) {
                        ForEach(category.images) { image in
                            ThumbnailCell(
                                image: image,
                                isSelected: image.id == library.selectedImage?.id
                            )
                            .onTapGesture {
                                library.selectImage(image)
                            }
                        }
                    }
                    .padding(20)
                }
            } else if let errorMessage = library.errorMessage {
                PlaceholderView(
                    title: "Could Not Load Images",
                    systemImage: "exclamationmark.triangle",
                    description: errorMessage
                )
            } else {
                PlaceholderView(title: "Choose a Category", systemImage: "photo.on.rectangle")
            }
        }
    }

    private var inspector: some View {
        ScrollView {
            if let category = library.selectedCategory, let image = library.selectedImage {
                VStack(alignment: .leading, spacing: 16) {
                    LargePreview(imageURL: image.fileURL)
                        .frame(maxWidth: .infinity)

                    GroupBox("Image") {
                        inspectorRow("Filename", image.fileURL.lastPathComponent)
                        inspectorRow("Tag", image.inferredTag)
                        inspectorRow("Category", category.shortName)
                        inspectorRow("Root Group", category.rootGroupName)
                        inspectorRow("Folder", category.folderURL.lastPathComponent)
                        inspectorRow("Path", image.fileURL.path)
                    }
                }
                .padding(20)
            } else {
                PlaceholderView(title: "Choose an Image", systemImage: "sidebar.right")
            }
        }
    }

    private func inspectorRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var categorySelectionBinding: Binding<String?> {
        Binding(
            get: { library.selectedCategory?.id },
            set: { newValue in
                let category = library.categories.first { $0.id == newValue }
                library.selectCategory(category)
            }
        )
    }

    private func expandAllGroupsIfNeeded() {
        if expandedGroupIDs.isEmpty {
            expandedGroupIDs = Set(library.categoryGroups.map(\.id))
        }
    }
}

private struct ThumbnailCell: View {
    let image: ImageItem
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ThumbnailImage(imageURL: image.fileURL)
                .frame(height: 140)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(image.inferredTag)
                .font(.subheadline)
                .lineLimit(2)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct ThumbnailImage: View {
    let imageURL: URL

    var body: some View {
        Group {
            if let nsImage = NSImage(contentsOf: imageURL) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                PlaceholderView(title: "No Preview", systemImage: "photo")
            }
        }
    }
}

private struct LargePreview: View {
    let imageURL: URL

    var body: some View {
        Group {
            if let nsImage = NSImage(contentsOf: imageURL) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                PlaceholderView(title: "No Preview", systemImage: "photo")
                    .frame(height: 260)
            }
        }
    }
}

private struct PlaceholderView: View {
    let title: String
    let systemImage: String
    var description: String?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            if let description, !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
