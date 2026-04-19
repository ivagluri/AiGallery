import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var library: LibraryStore
    @AppStorage("showInspector") private var showInspector = true
    @AppStorage("imageSortOrder") private var imageSortOrderRawValue = ImageSortOrder.alphabeticalAscending.rawValue
    @AppStorage("thumbnailSizeIndex") private var thumbnailSizeIndex = 2
    @AppStorage("inspectorPanelWidth") private var inspectorPanelWidth = 360.0
    @FocusState private var isSearchFieldFocused: Bool
    @State private var searchText = ""
    @State private var activeSearchText = ""
    @State private var expandedGroupIDs: Set<String> = []
    @State private var isImageInfoExpanded = true
    @State private var isPNGInfoExpanded = true
    @State private var isPNGPromptsExpanded = true
    @State private var isPNGDetailsExpanded = true
    @State private var copiedInspectorValue: String?
    @State private var copiedInspectorResetTask: DispatchWorkItem?
    @State private var savedBrowseSelection: BrowseSelection?
    @State private var searchSelectedImageID: ImageItem.ID?
    @State private var pendingSearchUpdateTask: DispatchWorkItem?
    @State private var activeSearchResults: TagSearchResult = .empty

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            contentArea
                .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
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

            ToolbarItem(placement: .automatic) {
                toolbarSearchField
            }
        }
        .onAppear {
            expandAllGroupsIfNeeded()
        }
        .onChange(of: library.categoryGroups.map(\.id)) { _ in
            expandAllGroupsIfNeeded()
        }
        .onChange(of: library.rootURL) { _ in
            clearSearchForRootChange()
        }
        .onChange(of: searchText) { newValue in
            handleSearchTextChange(newValue)
        }
    }

    private var contentArea: some View {
        InspectorSplitView(
            isInspectorVisible: $showInspector,
            inspectorWidth: $inspectorPanelWidth,
            minPrimaryWidth: 320,
            minInspectorWidth: 240,
            primary: thumbnailGrid,
            inspector: inspector
        )
    }

    private var toolbarSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search Tags", text: $searchText)
                .textFieldStyle(.plain)
                .focused($isSearchFieldFocused)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    activeSearchText = ""
                    pendingSearchUpdateTask?.cancel()
                    isSearchFieldFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear Search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 220)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isSearchFieldFocused
                        ? Color.accentColor.opacity(0.45)
                        : Color.primary.opacity(0.08),
                    lineWidth: 1
                )
        )
    }

    private var sidebar: some View {
        List {
            ForEach(Array(library.categoryGroups.enumerated()), id: \.element.id) { index, group in
                if group.isSynthetic, let category = group.categories.first, group.categories.count == 1 {
                    categoryRow(category, title: category.name, systemImage: "star.fill")
                } else {
                    sidebarGroup(group, stripeIndex: index)
                }
            }
        }
        .overlay {
            if library.categories.isEmpty {
                PlaceholderView(title: "No Categories", systemImage: "folder")
            }
        }
        .listStyle(.plain)
        .disabled(isSearching)
        .navigationSplitViewColumnWidth(min: 180, ideal: 260, max: 420)
    }

    private func sidebarGroup(_ group: CategoryGroup, stripeIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                toggleGroupExpansion(group.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isGroupExpanded(group.id) ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)

                    Text(group.name)
                        .font(.headline)

                    Spacer()

                    Text("\(group.categories.count)")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isCollapsedActiveGroup(group) ? Color.accentColor.opacity(0.14) : Color.clear)
                )
            }
            .buttonStyle(.plain)

            if isGroupExpanded(group.id) {
                ForEach(sidebarNodes(for: group)) { node in
                    sidebarNodeRow(node, level: 1)
                }
            }
        }
        .padding(.vertical, 2)
        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
        .listRowBackground(sidebarStripeFill(for: stripeIndex))
    }

    private func sidebarNodeRow(_ node: SidebarNode, level: Int) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if node.hasChildren {
                        Button {
                            toggleGroupExpansion(node.id)
                        } label: {
                            Image(systemName: isGroupExpanded(node.id) ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 12, height: 12)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear
                            .frame(width: 12, height: 12)
                    }

                    if let category = node.category {
                        categoryRow(
                            category,
                            title: node.title,
                            systemImage: nil,
                            isActiveOverride: isCollapsedActiveNode(node)
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Button {
                            toggleGroupExpansion(node.id)
                        } label: {
                            HStack {
                                Text(node.title)
                                    .lineLimit(2)
                                Spacer()
                                Text("\(node.children.count)")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isCollapsedActiveNode(node) ? Color.accentColor.opacity(0.14) : Color.clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, CGFloat(level) * 14)

                if node.hasChildren && isGroupExpanded(node.id) {
                    ForEach(node.children) { child in
                        sidebarNodeRow(child, level: level + 1)
                    }
                }
            }
        )
    }

    private func categoryRow(
        _ category: Category,
        title: String,
        systemImage: String?,
        isActiveOverride: Bool = false
    ) -> some View {
        Button {
            guard !isSearching else { return }
            library.selectCategory(category)
        } label: {
            HStack {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                        .lineLimit(2)
                } else {
                    Text(title)
                        .lineLimit(2)
                }
                Spacer()
                Text("\(category.images.count)")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill((category.id == library.selectedCategory?.id || isActiveOverride) ? Color.accentColor.opacity(0.14) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tag(category.id)
    }

    private var thumbnailGrid: some View {
        Group {
            if isSearching {
                VStack(spacing: 0) {
                    gridControls(title: "Search Results", subtitle: searchResultsSummary)

                    if displayImages.isEmpty {
                        PlaceholderView(
                            title: "No Matches",
                            systemImage: "magnifyingglass",
                            description: searchPlaceholderDescription
                        )
                    } else {
                        imageGrid(images: displayImages)
                    }
                }
            } else if let category = library.selectedCategory {
                VStack(spacing: 0) {
                    gridControls(for: category)
                    imageGrid(images: displayImages)
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
            if let image = displayedSelectedImage {
                let metadata = library.inspectorMetadata(for: image)

                VStack(alignment: .leading, spacing: 16) {
                    LargePreview(imageURL: image.fileURL)
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .topTrailing) {
                            previewFavoriteButton(for: image)
                                .padding(12)
                        }

                    InspectorSection("Image", isExpanded: $isImageInfoExpanded) {
                        inspectorTagRow("Tag", image.inferredTag)
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

    private func inspectorTagRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 8) {
                Text(value)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    copyInspectorTag(value)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: copiedInspectorValue == value ? "checkmark" : "doc.on.doc")
                            .font(.caption.weight(.semibold))

                        Text(copiedInspectorValue == value ? "Copied" : "Copy")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(copiedInspectorValue == value ? Color.accentColor : Color.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                copiedInspectorValue == value
                                    ? Color.accentColor.opacity(0.35)
                                    : Color.primary.opacity(0.08),
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(.plain)
                .help("Copy Tag")

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copyInspectorTag(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)

        copiedInspectorResetTask?.cancel()
        copiedInspectorValue = value

        let resetTask = DispatchWorkItem {
            copiedInspectorValue = nil
        }

        copiedInspectorResetTask = resetTask
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: resetTask)
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
        gridControls(title: category.name, subtitle: nil)
    }

    private func gridControls(title: String, subtitle: String?) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                categoryHeader(title: title, subtitle: subtitle)

                Spacer(minLength: 12)

                sortButton
                thumbnailSizeControl
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 12) {
                categoryHeader(title: title, subtitle: subtitle)

                HStack(spacing: 16) {
                    sortButton
                    Spacer(minLength: 8)
                    thumbnailSizeControl
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 12) {
                categoryHeader(title: title, subtitle: subtitle)

                sortButton

                thumbnailSizeControl
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(controlStripBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(controlStripDivider)
                .frame(height: 1)
        }
    }

    private var controlStripBackground: some View {
        Rectangle()
            .fill(
                Color(
                    nsColor: colorScheme == .dark
                        ? .controlBackgroundColor
                        : .windowBackgroundColor
                )
                .opacity(colorScheme == .dark ? 0.35 : 0.92)
            )
    }

    private var controlStripDivider: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.06)
            : Color.black.opacity(0.10)
    }

    private func categoryHeader(title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(title)

            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private func imageGrid(images: [ImageItem]) -> some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: thumbnailSize, maximum: thumbnailSize + 40), spacing: 16)],
                spacing: 16
            ) {
                ForEach(images) { image in
                    ThumbnailCell(
                        image: image,
                        isSelected: image.id == displayedSelectedImage?.id,
                        thumbnailHeight: thumbnailSize,
                        isFavorite: library.isFavorite(image),
                        onToggleFavorite: {
                            library.toggleFavorite(image)
                        }
                    )
                    .onTapGesture {
                        selectImage(image)
                    }
                }
            }
            .padding(20)
        }
    }

    private func previewFavoriteButton(for image: ImageItem) -> some View {
        let isFavorite = library.isFavorite(image)

        return Button {
            library.toggleFavorite(image)
        } label: {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.title3.weight(.semibold))
                .foregroundStyle(isFavorite ? Color.yellow : Color.white)
                .padding(10)
                .background(.black.opacity(0.4), in: Circle())
        }
        .buttonStyle(.plain)
        .help(isFavorite ? "Remove from Favorites" : "Add to Favorites")
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
        sortedImages(category.images)
    }

    private func sortedImages(_ images: [ImageItem]) -> [ImageItem] {
        images.sorted { lhs, rhs in
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

    private func sidebarStripeFill(for stripeIndex: Int) -> Color {
        guard stripeIndex.isMultiple(of: 2) else {
            return Color.clear
        }

        return Color.primary.opacity(colorScheme == .dark ? 0.018 : 0.012)
    }

    private func sidebarNodes(for group: CategoryGroup) -> [SidebarNode] {
        var nodes: [SidebarNode] = []

        for category in group.categories {
            let relativePath = Array(category.pathParts.dropFirst())

            if relativePath.isEmpty {
                nodes.append(
                    SidebarNode(
                        id: "\(group.id)/__overview__",
                        title: "Overview",
                        pathParts: category.pathParts,
                        category: category,
                        children: []
                    )
                )
                continue
            }

            insertSidebarNode(
                category: category,
                remainingParts: relativePath,
                accumulatedPath: [group.id],
                nodes: &nodes
            )
        }

        return sortSidebarNodes(nodes)
    }

    private func isGroupExpanded(_ groupID: String) -> Bool {
        expandedGroupIDs.contains(groupID)
    }

    private func isCollapsedActiveGroup(_ group: CategoryGroup) -> Bool {
        guard !isGroupExpanded(group.id) else { return false }
        return library.selectedCategory?.rootGroupID == group.id
    }

    private func isCollapsedActiveNode(_ node: SidebarNode) -> Bool {
        guard node.hasChildren, !isGroupExpanded(node.id), let selectedCategory = library.selectedCategory else {
            return false
        }

        if node.category?.id == selectedCategory.id {
            return false
        }

        return selectedCategory.pathParts.starts(with: node.pathParts)
    }

    private func toggleGroupExpansion(_ groupID: String) {
        if expandedGroupIDs.contains(groupID) {
            expandedGroupIDs.remove(groupID)
        } else {
            expandedGroupIDs.insert(groupID)
        }
    }

    private func expandAllGroupsIfNeeded() {
        let expandableNodeIDs = Set(allExpandableNodeIDs())
        expandedGroupIDs = expandedGroupIDs.intersection(expandableNodeIDs)

        let topLevelGroupIDs = Set(library.categoryGroups.filter { !$0.isSynthetic }.map(\.id))
        if expandedGroupIDs.isEmpty || expandedGroupIDs.intersection(topLevelGroupIDs).isEmpty {
            expandedGroupIDs = expandableNodeIDs
        }
    }

    private func allExpandableNodeIDs() -> [String] {
        library.categoryGroups.reduce(into: [String]()) { result, group in
            guard !group.isSynthetic else { return }
            result.append(group.id)
            result.append(contentsOf: expandableNodeIDs(in: sidebarNodes(for: group)))
        }
    }

    private func expandableNodeIDs(in nodes: [SidebarNode]) -> [String] {
        nodes.reduce(into: [String]()) { result, node in
            guard node.hasChildren else { return }
            result.append(node.id)
            result.append(contentsOf: expandableNodeIDs(in: node.children))
        }
    }

    private func insertSidebarNode(
        category: Category,
        remainingParts: [String],
        accumulatedPath: [String],
        nodes: inout [SidebarNode]
    ) {
        guard let nextPart = remainingParts.first else { return }

        let currentPath = accumulatedPath + [nextPart]
        let nodeID = currentPath.joined(separator: "/")

        let nodeIndex = nodes.firstIndex(where: { $0.id == nodeID }) ?? {
            nodes.append(
                SidebarNode(
                    id: nodeID,
                    title: displayTitle(for: nextPart),
                    pathParts: currentPath,
                    category: nil,
                    children: []
                )
            )
            return nodes.endIndex - 1
        }()

        if remainingParts.count == 1 {
            nodes[nodeIndex].category = category
        } else {
            insertSidebarNode(
                category: category,
                remainingParts: Array(remainingParts.dropFirst()),
                accumulatedPath: currentPath,
                nodes: &nodes[nodeIndex].children
            )
        }
    }

    private func sortSidebarNodes(_ nodes: [SidebarNode]) -> [SidebarNode] {
        nodes
            .map { node in
                var updatedNode = node
                updatedNode.children = sortSidebarNodes(node.children)
                return updatedNode
            }
            .sorted { lhs, rhs in
                if lhs.title == "Overview" || rhs.title == "Overview" {
                    return lhs.title == "Overview"
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    private func displayTitle(for slug: String) -> String {
        slug
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedActiveSearchText: String {
        activeSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool {
        !trimmedActiveSearchText.isEmpty
    }

    private var displayImages: [ImageItem] {
        if isSearching {
            return activeSearchResults.images
        }

        guard let category = library.selectedCategory else {
            return []
        }

        return sortedImages(for: category)
    }

    private var displayedSelectedImage: ImageItem? {
        if isSearching {
            return displayImages.first { $0.id == searchSelectedImageID } ?? displayImages.first
        }

        return library.selectedImage
    }

    private var searchResultsSummary: String {
        let resultCount = activeSearchResults.totalMatches
        let visibleCount = activeSearchResults.images.count
        let matchLabel = resultCount == 1 ? "match" : "matches"

        if resultCount > visibleCount {
            return "Showing first \(visibleCount) of \(resultCount) \(matchLabel) for \"\(trimmedActiveSearchText)\""
        }

        return "\(resultCount) \(matchLabel) for \"\(trimmedActiveSearchText)\""
    }

    private var searchPlaceholderDescription: String {
        if trimmedSearchText.count < Self.minimumSearchLength {
            let characterLabel = Self.minimumSearchLength == 1 ? "character" : "characters"
            return "Type at least \(Self.minimumSearchLength) \(characterLabel) to search tags."
        }

        return "No tags matched \"\(trimmedActiveSearchText)\"."
    }

    private func handleSearchTextChange(_ newValue: String) {
        let trimmedValue = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let wasSearching = !trimmedActiveSearchText.isEmpty
        let isActivatingSearch = !trimmedValue.isEmpty && !wasSearching && savedBrowseSelection == nil
        let isClearingSearch = trimmedValue.isEmpty && (wasSearching || savedBrowseSelection != nil)

        if isActivatingSearch {
            savedBrowseSelection = BrowseSelection(
                categoryID: library.selectedCategory?.id,
                imageID: library.selectedImage?.id
            )
        }

        pendingSearchUpdateTask?.cancel()

        if isClearingSearch {
            activeSearchText = ""
            activeSearchResults = .empty
            restoreBrowseSelection()
            return
        }

        guard !trimmedValue.isEmpty else {
            return
        }

        guard trimmedValue.count >= Self.minimumSearchLength else {
            activeSearchText = ""
            activeSearchResults = .empty
            searchSelectedImageID = nil
            return
        }

        let updateTask = DispatchWorkItem {
            activeSearchText = trimmedValue
            activeSearchResults = library.searchTags(
                matching: trimmedValue,
                limit: Self.maximumSearchResults
            )

            if let searchSelectedImageID, activeSearchResults.images.contains(where: { $0.id == searchSelectedImageID }) {
                return
            }

            searchSelectedImageID = activeSearchResults.images.first?.id
        }

        pendingSearchUpdateTask = updateTask
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: updateTask)
    }

    private func clearSearchForRootChange() {
        guard !searchText.isEmpty || !activeSearchText.isEmpty || savedBrowseSelection != nil else {
            return
        }

        pendingSearchUpdateTask?.cancel()
        searchText = ""
        activeSearchText = ""
        activeSearchResults = .empty
        searchSelectedImageID = nil
        savedBrowseSelection = nil
        isSearchFieldFocused = false
    }

    private func restoreBrowseSelection() {
        if let categoryID = savedBrowseSelection?.categoryID {
            let category = library.categories.first { $0.id == categoryID }
            library.selectCategory(category)

            if let imageID = savedBrowseSelection?.imageID,
               let image = category?.images.first(where: { $0.id == imageID }) {
                library.selectImage(image)
            }
        }

        savedBrowseSelection = nil
        searchSelectedImageID = nil
        pendingSearchUpdateTask?.cancel()
        activeSearchResults = .empty
    }

    private func selectImage(_ image: ImageItem) {
        if isSearching {
            searchSelectedImageID = image.id
        } else {
            library.selectImage(image)
        }
    }

    private static let maximumSearchResults = 300
    private static let minimumSearchLength = 2
    private static let thumbnailSizes: [Double] = [100, 120, 150, 185, 225, 260, 300]
}

private struct BrowseSelection {
    let categoryID: Category.ID?
    let imageID: ImageItem.ID?
}

private struct SidebarNode: Identifiable, Hashable {
    let id: String
    let title: String
    let pathParts: [String]
    var category: Category?
    var children: [SidebarNode]

    var hasChildren: Bool {
        !children.isEmpty
    }
}

private struct InspectorSplitView<Primary: View, Inspector: View>: NSViewControllerRepresentable {
    @Binding var isInspectorVisible: Bool
    @Binding var inspectorWidth: Double
    let minPrimaryWidth: CGFloat
    let minInspectorWidth: CGFloat
    let primary: Primary
    let inspector: Inspector

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isInspectorVisible: $isInspectorVisible,
            inspectorWidth: $inspectorWidth
        )
    }

    func makeNSViewController(context: Context) -> SplitViewController {
        let controller = SplitViewController(
            coordinator: context.coordinator,
            minPrimaryWidth: minPrimaryWidth,
            minInspectorWidth: minInspectorWidth
        )
        controller.update(primary: primary, inspector: inspector)
        controller.setInspectorVisible(isInspectorVisible, animated: false)
        controller.restoreInspectorWidth(CGFloat(inspectorWidth))
        return controller
    }

    func updateNSViewController(_ controller: SplitViewController, context: Context) {
        controller.update(primary: primary, inspector: inspector)
        controller.setInspectorVisible(isInspectorVisible, animated: false)
        controller.restoreInspectorWidth(CGFloat(inspectorWidth))
    }

    final class Coordinator: NSObject {
        @Binding var isInspectorVisible: Bool
        @Binding var inspectorWidth: Double
        weak var controller: SplitViewController?

        init(
            isInspectorVisible: Binding<Bool>,
            inspectorWidth: Binding<Double>
        ) {
            self._isInspectorVisible = isInspectorVisible
            self._inspectorWidth = inspectorWidth
        }
    }

    final class SplitViewController: NSSplitViewController {
        let primaryHostingController = NSHostingController(rootView: AnyView(EmptyView()))
        let inspectorHostingController = NSHostingController(rootView: AnyView(EmptyView()))
        let primaryItem: NSSplitViewItem
        let inspectorItem: NSSplitViewItem

        private let coordinator: Coordinator
        private let minPrimaryWidth: CGFloat
        private let minInspectorWidth: CGFloat
        private var hasAppliedInitialWidth = false
        private var pendingInspectorWidth: CGFloat?

        init(coordinator: Coordinator, minPrimaryWidth: CGFloat, minInspectorWidth: CGFloat) {
            self.coordinator = coordinator
            self.minPrimaryWidth = minPrimaryWidth
            self.minInspectorWidth = minInspectorWidth
            self.primaryItem = NSSplitViewItem(viewController: primaryHostingController)
            self.inspectorItem = NSSplitViewItem(viewController: inspectorHostingController)
            super.init(nibName: nil, bundle: nil)

            coordinator.controller = self

            primaryItem.minimumThickness = minPrimaryWidth
            inspectorItem.minimumThickness = minInspectorWidth
            inspectorItem.canCollapse = true

            addSplitViewItem(primaryItem)
            addSplitViewItem(inspectorItem)

            splitView.delegate = self
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidLayout() {
            super.viewDidLayout()

            if !hasAppliedInitialWidth || pendingInspectorWidth != nil {
                restoreInspectorWidth(pendingInspectorWidth)
                pendingInspectorWidth = nil
                hasAppliedInitialWidth = true
            }
        }

        func update<PrimaryContent: View, InspectorContent: View>(
            primary: PrimaryContent,
            inspector: InspectorContent
        ) {
            primaryHostingController.rootView = AnyView(primary)
            inspectorHostingController.rootView = AnyView(inspector)
        }

        func setInspectorVisible(_ isVisible: Bool, animated: Bool) {
            guard inspectorItem.isCollapsed != !isVisible else { return }

            if isVisible, animated {
                inspectorItem.animator().isCollapsed = false
            } else if animated {
                inspectorItem.animator().isCollapsed = true
            } else if isVisible {
                inspectorItem.isCollapsed = false
            } else {
                inspectorItem.isCollapsed = true
            }
        }

        func restoreInspectorWidth(_ width: CGFloat?) {
            guard let width else { return }

            guard
                isViewLoaded,
                view.bounds.width > 0,
                !inspectorItem.isCollapsed
            else {
                pendingInspectorWidth = width
                return
            }

            let totalWidth = splitView.bounds.width
            let dividerThickness = splitView.dividerThickness
            let clampedInspectorWidth = max(
                minInspectorWidth,
                min(width, totalWidth - minPrimaryWidth - dividerThickness)
            )
            let dividerPosition = totalWidth - clampedInspectorWidth - dividerThickness

            splitView.setPosition(dividerPosition, ofDividerAt: 0)
        }

        override func splitViewDidResizeSubviews(_ notification: Notification) {
            guard
                coordinator.isInspectorVisible,
                !inspectorItem.isCollapsed,
                inspectorHostingController.isViewLoaded
            else {
                return
            }

            let width = max(inspectorHostingController.view.frame.width, minInspectorWidth)
            if abs(coordinator.inspectorWidth - width) > 0.5 {
                coordinator.inspectorWidth = width
            }
        }
    }
}

private struct ThumbnailCell: View {
    @Environment(\.colorScheme) private var colorScheme
    let image: ImageItem
    let isSelected: Bool
    let thumbnailHeight: Double
    let isFavorite: Bool
    let onToggleFavorite: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                ThumbnailImage(imageURL: image.fileURL)
                    .frame(height: thumbnailHeight)
                    .frame(maxWidth: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                Button(action: onToggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.headline)
                        .foregroundStyle(isFavorite ? Color.yellow : Color.white)
                        .padding(8)
                        .background(.black.opacity(0.35), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(8)
            }

            Text(image.inferredTag)
                .font(.subheadline)
                .lineLimit(2)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(cardFillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(cardBorderColor, lineWidth: isSelected ? 1.2 : 1)
        )
        .shadow(
            color: colorScheme == .dark ? .clear : Color.black.opacity(isSelected ? 0.10 : 0.06),
            radius: colorScheme == .dark ? 0 : 8,
            y: colorScheme == .dark ? 0 : 2
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    private var cardFillColor: Color {
        if isSelected {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.14 : 0.12)
        }

        return Color(
            nsColor: colorScheme == .dark
                ? .controlBackgroundColor
                : .windowBackgroundColor
        )
    }

    private var cardBorderColor: Color {
        if isSelected {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.9 : 0.75)
        }

        return colorScheme == .dark
            ? Color.clear
            : Color.black.opacity(0.08)
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
