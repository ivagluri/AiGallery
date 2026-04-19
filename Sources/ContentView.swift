import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var library: LibraryStore
    @AppStorage("showInspector") private var showInspector = true
    @AppStorage("imageSortOrder") private var imageSortOrderRawValue = ImageSortOrder.alphabeticalAscending.rawValue
    @AppStorage("thumbnailSizeIndex") private var thumbnailSizeIndex = 2
    @State private var expandedGroupIDs: Set<String> = []
    @State private var isImageInfoExpanded = true
    @State private var isPNGInfoExpanded = true
    @State private var isPNGPromptsExpanded = true
    @State private var isPNGDetailsExpanded = true

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            contentArea
        }
        .navigationTitle("AiGallery")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    library.reload()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .help("Reload Library")

                Button {
                    library.chooseRootFolder()
                } label: {
                    Label("Choose Folder", systemImage: "folder")
                }
                .labelStyle(.iconOnly)
                .help("Choose Image Root")

                Button {
                    showInspector.toggle()
                } label: {
                    Label(showInspector ? "Hide Info" : "Show Info", systemImage: showInspector ? "info.circle.fill" : "info.circle")
                }
                .labelStyle(.iconOnly)
                .help(showInspector ? "Hide Info" : "Show Info")
            }
        }
        .onAppear {
            expandAllGroupsIfNeeded()
        }
        .onChange(of: library.categoryGroups.map(\.id)) { _ in
            expandAllGroupsIfNeeded()
        }
    }

    private var contentArea: some View {
        Group {
            if showInspector {
                HSplitView {
                    thumbnailGrid
                        .frame(minWidth: 320, idealWidth: 820, maxWidth: .infinity)
                    inspector
                        .frame(minWidth: 240, idealWidth: 360, maxWidth: .infinity)
                }
            } else {
                thumbnailGrid
            }
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
        .navigationSplitViewColumnWidth(min: 180, ideal: 260, max: 420)
    }

    private var thumbnailGrid: some View {
        Group {
            if let category = library.selectedCategory {
                VStack(spacing: 0) {
                    gridControls(for: category)

                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: thumbnailSize, maximum: thumbnailSize + 40), spacing: 16)],
                            spacing: 16
                        ) {
                            ForEach(sortedImages(for: category)) { image in
                                ThumbnailCell(
                                    image: image,
                                    isSelected: image.id == library.selectedImage?.id,
                                    thumbnailHeight: thumbnailSize
                                )
                                .onTapGesture {
                                    library.selectImage(image)
                                }
                            }
                        }
                        .padding(20)
                    }
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
            if let image = library.selectedImage {
                let metadata = library.inspectorMetadata(for: image)

                VStack(alignment: .leading, spacing: 16) {
                    LargePreview(imageURL: image.fileURL)
                        .frame(maxWidth: .infinity)

                    InspectorSection("Image", isExpanded: $isImageInfoExpanded) {
                        inspectorRow("Tag", image.inferredTag)
                        inspectorRow("Filename", image.fileURL.lastPathComponent)
                        inspectorRow("Path", image.fileURL.path)
                    }

                    if let metadata, metadata.hasVisibleContent {
                        let additionalMetadataEntries = metadata.textEntries.filter { entry in
                            let keyword = entry.keyword.lowercased()
                            return keyword != "parameters"
                        }

                        InspectorSection("Metadata", isExpanded: $isPNGInfoExpanded) {
                            if metadata.prompt != nil || metadata.negativePrompt != nil {
                                NestedInspectorSection("Prompts", isExpanded: $isPNGPromptsExpanded) {
                                    if let prompt = metadata.prompt {
                                        inspectorRow("Prompt", prompt)
                                    }

                                    if let negativePrompt = metadata.negativePrompt {
                                        inspectorRow("Negative Prompt", negativePrompt)
                                    }
                                }
                            }

                            if !metadata.generationParameters.isEmpty || !additionalMetadataEntries.isEmpty {
                                NestedInspectorSection("Details", isExpanded: $isPNGDetailsExpanded) {
                                    ForEach(metadata.generationParameters) { parameter in
                                        inspectorRow(parameter.keyword, parameter.value)
                                    }

                                    ForEach(additionalMetadataEntries) { entry in
                                        inspectorRow(humanReadablePNGLabel(for: entry.keyword), entry.value)
                                    }
                                }
                            }
                        }
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

    private var imageSortOrder: ImageSortOrder {
        get { ImageSortOrder(rawValue: imageSortOrderRawValue) ?? .alphabeticalAscending }
        nonmutating set { imageSortOrderRawValue = newValue.rawValue }
    }

    private var thumbnailSize: Double {
        Self.thumbnailSizes[clampedThumbnailSizeIndex]
    }

    private var thumbnailSizeSliderBinding: Binding<Double> {
        Binding(
            get: { Double(clampedThumbnailSizeIndex) },
            set: { newValue in
                thumbnailSizeIndex = min(max(Int(newValue.rounded()), 0), Self.thumbnailSizes.count - 1)
            }
        )
    }

    private var clampedThumbnailSizeIndex: Int {
        min(max(thumbnailSizeIndex, 0), Self.thumbnailSizes.count - 1)
    }

    private func gridControls(for category: Category) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                categoryHeader(category)

                Spacer(minLength: 12)

                sortButton
                thumbnailSizeControl
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 12) {
                categoryHeader(category)

                HStack(spacing: 16) {
                    sortButton
                    Spacer(minLength: 8)
                    thumbnailSizeControl
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 12) {
                categoryHeader(category)

                sortButton

                thumbnailSizeControl
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    private func categoryHeader(_ category: Category) -> some View {
        Text(category.name)
            .font(.headline)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(category.name)
    }

    private var sortButton: some View {
        Button {
            imageSortOrder = imageSortOrder.toggled
        } label: {
            Label(imageSortOrder.helpText, systemImage: imageSortOrder.systemImage)
        }
        .labelStyle(.iconOnly)
        .help(imageSortOrder.helpText)
    }

    private var thumbnailSizeControl: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.caption)
                .foregroundStyle(.secondary)

            Slider(
                value: thumbnailSizeSliderBinding,
                in: 0...Double(Self.thumbnailSizes.count - 1),
                step: 1
            )
            .frame(width: 140)

            Image(systemName: "square.grid.3x3.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .help("Adjust thumbnail size")
    }

    private func sortedImages(for category: Category) -> [ImageItem] {
        category.images.sorted { lhs, rhs in
            let comparison = lhs.inferredTag.localizedCaseInsensitiveCompare(rhs.inferredTag)

            switch imageSortOrder {
            case .alphabeticalAscending:
                if comparison == .orderedSame {
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }
                return comparison == .orderedAscending
            case .alphabeticalDescending:
                if comparison == .orderedSame {
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedDescending
                }
                return comparison == .orderedDescending
            }
        }
    }

    private func humanReadablePNGLabel(for keyword: String) -> String {
        keyword
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.lowercased().capitalized }
            .joined(separator: " ")
    }

    private func expandAllGroupsIfNeeded() {
        if expandedGroupIDs.isEmpty {
            expandedGroupIDs = Set(library.categoryGroups.map(\.id))
        }
    }

    private static let thumbnailSizes: [Double] = [100, 120, 150, 185, 225, 260, 300]
}

private struct ThumbnailCell: View {
    let image: ImageItem
    let isSelected: Bool
    let thumbnailHeight: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ThumbnailImage(imageURL: image.fileURL)
                .frame(height: thumbnailHeight)
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

private enum ImageSortOrder: String, CaseIterable, Identifiable {
    case alphabeticalAscending
    case alphabeticalDescending

    var id: String { rawValue }

    var helpText: String {
        switch self {
        case .alphabeticalAscending:
            return "Sort: A to Z"
        case .alphabeticalDescending:
            return "Sort: Z to A"
        }
    }

    var systemImage: String {
        switch self {
        case .alphabeticalAscending:
            return "arrow.down.circle"
        case .alphabeticalDescending:
            return "arrow.up.circle"
        }
    }

    var toggled: ImageSortOrder {
        switch self {
        case .alphabeticalAscending:
            return .alphabeticalDescending
        case .alphabeticalDescending:
            return .alphabeticalAscending
        }
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: Content

    init(_ title: String, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        self._isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    content
                }
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text(title)
                    .font(.headline)
            }
        }
    }
}

private struct NestedInspectorSection<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: Content

    init(_ title: String, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        self._isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
        }
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
