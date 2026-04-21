import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    private static let topLevelFolderTitle = "This Folder"

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
    @State private var activeSearchResults: SearchResult = .empty
    @StateObject private var previewController = PreviewOverlayController()
    @StateObject private var displayImageCache = DisplayImageCache()
    @State private var hostWindow: NSWindow?
    @State private var gridLayoutMetrics = GridLayoutMetrics(columns: 1, pageStep: 1)
    @State private var pendingScrollRequest: GridScrollRequest?
    @State private var isInspectorResizing = false
    @State private var scrollEndNonce = false
    @State private var droppedInspectionImage: ImageItem?
    @State private var isDropTargeted = false

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
                    relinquishSearchFocus()
                    library.reload()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .help("Reload Library")

                Button {
                    relinquishSearchFocus()
                    library.chooseRootFolder()
                } label: {
                    Label("Choose Folder", systemImage: "folder")
                }
                .labelStyle(.iconOnly)
                .help("Choose Image Root")

                Button {
                    relinquishSearchFocus()
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
            clearDroppedInspection()
            clearSearchForRootChange()
        }
        .onChange(of: searchText) { newValue in
            handleSearchTextChange(newValue)
        }
        .onChange(of: displayedSelectedImage?.id) { _ in
            syncPreviewSession()
        }
        .background(
            HostWindowReader { window in
                hostWindow = window
            }
        )
        .background(
            KeyAwareView(isActive: !isSearchFieldFocused) { event in
                handleKeyEvent(event)
            }
        )
        .overlay {
            if isDropTargeted {
                dropTargetOverlay
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted, perform: handleDroppedFileProviders)
        .onDisappear {
            previewController.dismiss()
        }
    }

    private var contentArea: some View {
        InspectorSplitView(
            isInspectorVisible: $showInspector,
            inspectorWidth: $inspectorPanelWidth,
            isInspectorResizing: $isInspectorResizing,
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
                        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                        .listRowBackground(sidebarStripeFill(for: index))
                        .overlay(alignment: .top) {
                            sidebarGroupDividerOverlay(isVisible: index > 0)
                        }
                } else {
                    sidebarGroup(group, stripeIndex: index)
                }
            }
        }
        .overlay {
            if library.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if library.categories.isEmpty {
                PlaceholderView(title: "No Categories", systemImage: "folder")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(sidebarPaneBackground)
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
        .overlay(alignment: .top) {
            sidebarGroupDividerOverlay(isVisible: stripeIndex > 0)
        }
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
            relinquishSearchFocus()
            clearDroppedInspection()
            library.selectCategory(category)
        } label: {
            HStack {
                if let systemImage {
                    HStack(spacing: 6) {
                        Image(systemName: systemImage)
                            .foregroundStyle(systemImage == "star.fill" ? favoriteStarColor : Color.primary)

                        Text(title)
                            .lineLimit(2)
                    }
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
            } else if library.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    if isInspectingDroppedImage {
                        temporaryInspectionBanner
                    }

                    LargePreview(imageURL: image.fileURL)
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .topTrailing) {
                            if !isInspectingDroppedImage {
                                previewFavoriteButton(for: image)
                                    .padding(12)
                            }
                        }

                    InspectorSection("Image", isExpanded: $isImageInfoExpanded) {
                        if isInspectingDroppedImage {
                            inspectorRow("Source", "Dropped PNG (temporary)")
                        }
                        inspectorTagRow("Tag", image.displayLabel)
                        inspectorRow("Filename", image.fileURL.lastPathComponent)
                        inspectorRow("Path", image.fileURL.path)
                    }

                    if let metadata, metadata.hasVisibleContent {
                        let additionalMetadataEntries = metadata.textEntries.filter { entry in
                            shouldDisplayMetadataEntry(
                                entry,
                                hasStructuredMetadata: metadata.prompt != nil
                                    || metadata.negativePrompt != nil
                                    || !metadata.generationParameters.isEmpty
                            )
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

                previewButton
                sortButton
                thumbnailSizeControl
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 12) {
                categoryHeader(title: title, subtitle: subtitle)

                HStack(spacing: 16) {
                    previewButton
                    sortButton
                    Spacer(minLength: 8)
                    thumbnailSizeControl
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 12) {
                categoryHeader(title: title, subtitle: subtitle)

                previewButton
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
        let selectedImageID = displayedSelectedImage?.id

        return GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(
                        columns: gridColumns,
                        spacing: 16
                    ) {
                        ForEach(images) { image in
                            ThumbnailCell(
                                image: image,
                                isSelected: image.id == selectedImageID,
                                thumbnailHeight: thumbnailSize,
                                isFavorite: library.isFavorite(image),
                                suspendThumbnailLoading: isInspectorResizing,
                                onSelect: {
                                    selectImage(image)
                                },
                                onOpenPreview: {
                                    openPreview(for: image)
                                },
                                onToggleFavorite: {
                                    library.toggleFavorite(image)
                                }
                            )
                        }
                    }
                    .padding(20)
                }
                .onAppear {
                    updateGridLayoutMetrics(from: geometry.size)
                }
                .onChange(of: geometry.size) { newSize in
                    if !isInspectorResizing {
                        updateGridLayoutMetrics(from: newSize)
                    }
                }
                .onChange(of: thumbnailSize) { _ in
                    updateGridLayoutMetrics(from: geometry.size)
                }
                .onChange(of: isInspectorResizing) { isResizing in
                    if !isResizing {
                        updateGridLayoutMetrics(from: geometry.size)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSScrollView.didEndLiveScrollNotification)) { _ in
                    scrollEndNonce.toggle()
                }
                .onChange(of: pendingScrollRequest) { request in
                    guard let request else { return }

                    if request.animated {
                        withAnimation(.easeInOut(duration: 0.24)) {
                            proxy.scrollTo(request.targetID, anchor: request.anchor)
                        }
                    } else {
                        proxy.scrollTo(request.targetID, anchor: request.anchor)
                    }

                    DispatchQueue.main.async {
                        pendingScrollRequest = nil
                    }
                }
            }
        }
    }

    private func previewFavoriteButton(for image: ImageItem) -> some View {
        let isFavorite = library.isFavorite(image)

        return Button {
            library.toggleFavorite(image)
        } label: {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.title3.weight(.semibold))
                .foregroundStyle(isFavorite ? favoriteStarColor : Color.white)
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

    private var previewButton: some View {
        Button {
            presentPreview()
        } label: {
            Label("Open Preview", systemImage: "arrow.up.left.and.arrow.down.right")
        }
        .labelStyle(.iconOnly)
        .help("Open Large Preview")
        .disabled(displayedSelectedImage == nil)
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
        displayImageCache.images(for: category, order: imageSortOrder)
    }

    private func humanReadablePNGLabel(for keyword: String) -> String {
        keyword
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.lowercased().capitalized }
            .joined(separator: " ")
    }

    private func shouldDisplayMetadataEntry(_ entry: PNGTextEntry, hasStructuredMetadata: Bool) -> Bool {
        let keyword = entry.keyword.lowercased()
        guard keyword != "parameters" else {
            return false
        }

        if hasStructuredMetadata && isRawMetadataBlob(entry.value) {
            return false
        }

        return true
    }

    private func isRawMetadataBlob(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 240 else {
            return false
        }

        let looksLikeXML = trimmed.hasPrefix("<") && (
            trimmed.contains("</")
                || trimmed.localizedCaseInsensitiveContains("<x:xmpmeta")
                || trimmed.localizedCaseInsensitiveContains("<?xml")
        )

        let looksLikeJSON = (trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
            || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))

        return looksLikeXML || looksLikeJSON
    }

    private var favoriteStarColor: Color {
        Color(
            red: 255.0 / 255.0,
            green: 218.0 / 255.0,
            blue: 107.0 / 255.0
        )
    }

    private var sidebarPaneBackground: Color {
        Color(
            nsColor: colorScheme == .dark
                ? .windowBackgroundColor
                : .controlBackgroundColor
        )
    }

    private func sidebarStripeFill(for stripeIndex: Int) -> Color {
        guard stripeIndex.isMultiple(of: 2) else {
            return Color.clear
        }

        return Color.primary.opacity(colorScheme == .dark ? 0.018 : 0.05)
    }

    private var sidebarGroupDividerColor: Color {
        let separator = Color(nsColor: .separatorColor)
        return separator.opacity(colorScheme == .dark ? 0.45 : 0.9)
    }

    @ViewBuilder
    private func sidebarGroupDividerOverlay(isVisible: Bool) -> some View {
        if isVisible {
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(sidebarDividerBaseFill)
                    .frame(height: 2)

                Rectangle()
                    .fill(sidebarGroupDividerColor)
                    .frame(height: 1)
            }
        }
    }

    private var sidebarDividerBaseFill: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    private func sidebarNodes(for group: CategoryGroup) -> [SidebarNode] {
        var nodes: [SidebarNode] = []

        for category in group.categories {
            let relativePath = Array(category.pathParts.dropFirst())

            if relativePath.isEmpty {
                nodes.append(
                    SidebarNode(
                        id: "\(group.id)/__overview__",
                        title: Self.topLevelFolderTitle,
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
                if lhs.title == Self.topLevelFolderTitle || rhs.title == Self.topLevelFolderTitle {
                    return lhs.title == Self.topLevelFolderTitle
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

    private var isInspectingDroppedImage: Bool {
        droppedInspectionImage != nil
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
        if let droppedInspectionImage {
            return droppedInspectionImage
        }

        if isSearching {
            return displayImages.first { $0.id == searchSelectedImageID } ?? displayImages.first
        }

        guard let selectedImageID = library.selectedImageID else {
            return library.selectedCategory?.images.first
        }

        return library.selectedCategory?.images.first(where: { $0.id == selectedImageID })
            ?? library.selectedCategory?.images.first
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
        if droppedInspectionImage != nil {
            clearDroppedInspection()
        }

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
        relinquishSearchFocus()
        clearDroppedInspection()

        if isSearching {
            searchSelectedImageID = image.id
        } else {
            library.selectImage(image)
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        if event.type == .keyUp, isHandledNavigationKeyUp(event) {
            return true
        }

        guard
            event.type == .keyDown,
            event.window === hostWindow,
            !previewController.isPresented
        else {
            return false
        }

        if let previewEventResult = handlePreviewHotkey(event) {
            if let favoriteEventResult = handleFavoriteHotkey(previewEventResult) {
                return handleNavigationHotkey(favoriteEventResult) == nil
            }

            return true
        }

        return true
    }

    private func isHandledNavigationKeyUp(_ event: NSEvent) -> Bool {
        guard event.window === hostWindow else {
            return false
        }

        if navigationKey(for: event) != nil {
            return true
        }

        if event.keyCode == 49 && shouldHandlePreviewHotkey(event) {
            return true
        }

        return isFavoriteHotkey(event) && shouldHandleFavoriteHotkey(event)
    }

    private func handlePreviewHotkey(_ event: NSEvent) -> NSEvent? {
        guard shouldHandlePreviewHotkey(event) else {
            return event
        }

        togglePreview()
        return nil
    }

    private func handleFavoriteHotkey(_ event: NSEvent) -> NSEvent? {
        guard isFavoriteHotkey(event), shouldHandleFavoriteHotkey(event) else {
            return event
        }

        if let image = displayedSelectedImage {
            library.toggleFavorite(image)
        }

        return nil
    }

    private func shouldHandlePreviewHotkey(_ event: NSEvent) -> Bool {
        guard
            event.keyCode == 49,
            displayedSelectedImage != nil
        else {
            return false
        }

        let disallowedModifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard disallowedModifiers.isEmpty else {
            return false
        }

        return !isSearchFieldFocused && !(hostWindow?.firstResponder is NSTextView)
    }

    private func handleNavigationHotkey(_ event: NSEvent) -> NSEvent? {
        guard let navigationKey = navigationKey(for: event), shouldHandleNavigationHotkey(event) else {
            return event
        }

        let columns = gridLayoutMetrics.columns
        let pageStep = gridLayoutMetrics.pageStep

        let delta: Int?
        let absoluteIndex: Int?

        switch navigationKey {
        case .down:
            delta = columns
            absoluteIndex = nil
        case .up:
            delta = -columns
            absoluteIndex = nil
        case .pageUp:
            delta = -pageStep
            absoluteIndex = nil
        case .pageDown:
            delta = pageStep
            absoluteIndex = nil
        case .home:
            delta = nil
            absoluteIndex = 0
        case .end:
            delta = nil
            absoluteIndex = max(displayImages.count - 1, 0)
        case .left:
            delta = -1
            absoluteIndex = nil
        case .right:
            delta = 1
            absoluteIndex = nil
        }

        let scrollBehavior: GridScrollBehavior
        switch navigationKey {
        case .left, .right, .up, .down:
            scrollBehavior = .followSelection
        case .pageUp:
            scrollBehavior = .jumpToEdge(.top)
        case .pageDown:
            scrollBehavior = .jumpToEdge(.bottom)
        case .home:
            scrollBehavior = .jumpToEdge(.top)
        case .end:
            scrollBehavior = .jumpToEdge(.bottom)
        }

        moveSelection(delta: delta, absoluteIndex: absoluteIndex, scrollBehavior: scrollBehavior)
        return nil
    }

    private func shouldHandleFavoriteHotkey(_ event: NSEvent) -> Bool {
        guard displayedSelectedImage != nil, !isInspectingDroppedImage else {
            return false
        }

        let disallowedModifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard disallowedModifiers.isEmpty else {
            return false
        }

        return !isSearchFieldFocused && !(hostWindow?.firstResponder is NSTextView)
    }

    private func shouldHandleNavigationHotkey(_ event: NSEvent) -> Bool {
        guard !displayImages.isEmpty else {
            return false
        }

        let disallowedModifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard disallowedModifiers.isEmpty else {
            return false
        }

        return !isSearchFieldFocused && !(hostWindow?.firstResponder is NSTextView)
    }

    private func moveSelection(delta: Int?, absoluteIndex: Int?, scrollBehavior: GridScrollBehavior) {
        let images = displayImages
        guard !images.isEmpty else { return }

        let currentID = displayedSelectedImage?.id
        let currentIndex = currentID.flatMap { id in
            images.firstIndex { $0.id == id }
        } ?? 0

        let targetIndex: Int
        if let absoluteIndex {
            targetIndex = min(max(absoluteIndex, 0), images.count - 1)
        } else if let delta {
            let proposedIndex = currentIndex + delta
            guard images.indices.contains(proposedIndex) else {
                return
            }
            targetIndex = proposedIndex
        } else {
            return
        }

        guard images.indices.contains(targetIndex) else { return }
        let targetImage = images[targetIndex]
        switch scrollBehavior {
        case .selectionOnly:
            break
        case .followSelection:
            pendingScrollRequest = GridScrollRequest(targetID: targetImage.id, anchor: nil, animated: true)
        case .jumpToEdge(let anchor):
            pendingScrollRequest = GridScrollRequest(targetID: targetImage.id, anchor: anchor, animated: false)
        }
        selectImage(targetImage)
    }

    private var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(.fixed(thumbnailSize), spacing: 16),
            count: gridLayoutMetrics.columns
        )
    }

    private func updateGridLayoutMetrics(from size: CGSize) {
        guard size != .zero else {
            return
        }

        let availableWidth = max(size.width - 40, thumbnailSize)
        let approximateCellWidth = thumbnailSize + 16
        let columns = max(Int((availableWidth + 16) / approximateCellWidth), 1)

        let availableHeight = max(size.height - 40, thumbnailSize)
        let approximateRowHeight = thumbnailSize + 44
        let rows = max(Int((availableHeight + 16) / approximateRowHeight), 1)
        let metrics = GridLayoutMetrics(columns: columns, pageStep: max(columns * rows, 1))

        guard metrics != gridLayoutMetrics else {
            return
        }

        gridLayoutMetrics = metrics
    }

    private func navigationKey(for event: NSEvent) -> NavigationKey? {
        switch Int(event.keyCode) {
        case 123:
            return .left
        case 124:
            return .right
        case 125:
            return .down
        case 126:
            return .up
        case 116:
            return .pageUp
        case 121:
            return .pageDown
        case 115:
            return .home
        case 119:
            return .end
        default:
            return nil
        }
    }

    private func isFavoriteHotkey(_ event: NSEvent) -> Bool {
        event.keyCode == 3
    }

    private func relinquishSearchFocus() {
        guard isSearchFieldFocused || hostWindow?.firstResponder is NSTextView else {
            return
        }

        isSearchFieldFocused = false
        hostWindow?.makeFirstResponder(nil)
    }

    private func syncPreviewSession() {
        guard previewController.isPresented else {
            return
        }

        previewController.update(session: previewOverlaySession())
    }

    private func togglePreview() {
        if previewController.isPresented {
            previewController.dismiss()
            return
        }

        presentPreview()
    }

    private func presentPreview() {
        guard displayedSelectedImage != nil else {
            return
        }

        schedulePreviewPresentation()
    }

    private func openPreview(for image: ImageItem) {
        selectImage(image)
        presentPreview()
    }

    private func schedulePreviewPresentation() {
        DispatchQueue.main.async {
            previewController.present(
                session: previewOverlaySession(),
                from: hostWindow
            )
        }
    }

    private func previewOverlaySession() -> PreviewOverlaySession {
        let isDroppedInspection = isInspectingDroppedImage
        let images = displayImages
        let currentID = displayedSelectedImage?.id
        let currentIndex = currentID.flatMap { id in
            images.firstIndex { $0.id == id }
        }
        let hasPrevious = !isDroppedInspection && (currentIndex ?? 0) > 0
        let hasNext = !isDroppedInspection && (currentIndex ?? -1) >= 0 && (currentIndex ?? -1) < images.count - 1

        return PreviewOverlaySession(
            image: displayedSelectedImage,
            capabilities: PreviewOverlayCapabilities(
                supportsNavigation: !isDroppedInspection,
                supportsFavorite: !isDroppedInspection,
                supportsMetadata: false
            ),
            isFavorite: !isDroppedInspection && (displayedSelectedImage.map { library.isFavorite($0) } ?? false),
            canNavigatePrevious: hasPrevious,
            canNavigateNext: hasNext,
            onNavigate: isDroppedInspection ? nil : { action in
                handlePreviewNavigation(action)
            },
            onToggleFavorite: isDroppedInspection ? nil : {
                guard let image = displayedSelectedImage else { return }
                library.toggleFavorite(image)
                syncPreviewSession()
            }
        )
    }

    private func handlePreviewNavigation(_ action: PreviewOverlayNavigationAction) {
        let scrollBehavior: GridScrollBehavior = .selectionOnly

        switch action {
        case .previous:
            moveSelection(delta: -1, absoluteIndex: nil, scrollBehavior: scrollBehavior)
        case .next:
            moveSelection(delta: 1, absoluteIndex: nil, scrollBehavior: scrollBehavior)
        case .up:
            moveSelection(delta: -gridLayoutMetrics.columns, absoluteIndex: nil, scrollBehavior: scrollBehavior)
        case .down:
            moveSelection(delta: gridLayoutMetrics.columns, absoluteIndex: nil, scrollBehavior: scrollBehavior)
        case .pageUp:
            moveSelection(delta: -gridLayoutMetrics.pageStep, absoluteIndex: nil, scrollBehavior: scrollBehavior)
        case .pageDown:
            moveSelection(delta: gridLayoutMetrics.pageStep, absoluteIndex: nil, scrollBehavior: scrollBehavior)
        case .home:
            moveSelection(delta: nil, absoluteIndex: 0, scrollBehavior: scrollBehavior)
        case .end:
            moveSelection(delta: nil, absoluteIndex: max(displayImages.count - 1, 0), scrollBehavior: scrollBehavior)
        }
    }

    private var temporaryInspectionBanner: some View {
        HStack(spacing: 12) {
            Label("Temporary PNG inspection", systemImage: "photo.badge.arrow.down")
                .font(.subheadline.weight(.semibold))

            Spacer(minLength: 12)

            Button("Return to Library") {
                clearDroppedInspection()
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.14 : 0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(colorScheme == .dark ? 0.28 : 0.18), lineWidth: 1)
        )
    }

    private var dropTargetOverlay: some View {
        ZStack {
            Color.black.opacity(colorScheme == .dark ? 0.20 : 0.12)
                .ignoresSafeArea()

            Rectangle()
                .strokeBorder(
                    Color.accentColor.opacity(colorScheme == .dark ? 0.90 : 0.75),
                    lineWidth: 3
                )
                .ignoresSafeArea()

            VStack(spacing: 10) {
                Image(systemName: "photo.badge.arrow.down")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.white)

                Text("Drop a PNG to inspect it temporarily")
                    .font(.headline)
                    .foregroundStyle(Color.white)

                Text("The file opens in the existing inspector and preview flow without being added to the library.")
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.88))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(colorScheme == .dark ? 0.22 : 0.35), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.18), radius: 18, y: 8)
            .padding(24)
        }
        .allowsHitTesting(false)
    }

    private func handleDroppedFileProviders(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { provider in
            provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }

        guard !fileProviders.isEmpty else {
            return false
        }

        loadFirstDroppedPNG(from: fileProviders, at: 0)
        return true
    }

    private func loadFirstDroppedPNG(from providers: [NSItemProvider], at index: Int) {
        guard providers.indices.contains(index) else {
            return
        }

        providers[index].loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            guard let data else {
                loadFirstDroppedPNG(from: providers, at: index + 1)
                return
            }

            guard let fileURL = URL(dataRepresentation: data, relativeTo: nil) else {
                loadFirstDroppedPNG(from: providers, at: index + 1)
                return
            }

            Task { @MainActor in
                if !openDroppedInspection(for: fileURL) {
                    loadFirstDroppedPNG(from: providers, at: index + 1)
                }
            }
        }
    }

    @MainActor
    private func openDroppedInspection(for fileURL: URL) -> Bool {
        guard let image = library.temporaryInspectionImage(for: fileURL) else {
            return false
        }

        relinquishSearchFocus()
        showInspector = true
        droppedInspectionImage = image

        if previewController.isPresented {
            syncPreviewSession()
        }

        return true
    }

    private func clearDroppedInspection() {
        guard droppedInspectionImage != nil else {
            return
        }

        droppedInspectionImage = nil
        if previewController.isPresented {
            syncPreviewSession()
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

private final class DisplayImageCache: ObservableObject {
    private struct CacheKey: Equatable {
        let categoryID: Category.ID
        let sortOrder: ImageSortOrder
        let imageCount: Int
        let firstImageID: ImageItem.ID?
        let lastImageID: ImageItem.ID?
    }

    private var cachedKey: CacheKey?
    private var cachedImages: [ImageItem] = []

    func images(for category: Category, order: ImageSortOrder) -> [ImageItem] {
        let key = CacheKey(
            categoryID: category.id,
            sortOrder: order,
            imageCount: category.images.count,
            firstImageID: category.images.first?.id,
            lastImageID: category.images.last?.id
        )

        if cachedKey == key {
            return cachedImages
        }

        cachedKey = key
        cachedImages = category.images.sorted { lhs, rhs in
            let comparison = lhs.displayLabel.localizedCaseInsensitiveCompare(rhs.displayLabel)

            switch order {
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

        return cachedImages
    }
}

private struct GridLayoutMetrics: Equatable {
    let columns: Int
    let pageStep: Int
}

private struct GridScrollRequest: Equatable {
    let targetID: ImageItem.ID
    let anchor: UnitPoint?
    let animated: Bool
}

private enum GridScrollBehavior {
    case selectionOnly
    case followSelection
    case jumpToEdge(UnitPoint)
}

private enum NavigationKey {
    case left
    case right
    case up
    case down
    case pageUp
    case pageDown
    case home
    case end
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
    @Binding var isInspectorResizing: Bool
    let minPrimaryWidth: CGFloat
    let minInspectorWidth: CGFloat
    let primary: Primary
    let inspector: Inspector

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isInspectorVisible: $isInspectorVisible,
            inspectorWidth: $inspectorWidth,
            isInspectorResizing: $isInspectorResizing
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
        @Binding var isInspectorResizing: Bool
        weak var controller: SplitViewController?

        init(
            isInspectorVisible: Binding<Bool>,
            inspectorWidth: Binding<Double>,
            isInspectorResizing: Binding<Bool>
        ) {
            self._isInspectorVisible = isInspectorVisible
            self._inspectorWidth = inspectorWidth
            self._isInspectorResizing = isInspectorResizing
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
        private var pendingInspectorWidthSyncTask: DispatchWorkItem?
        private var pendingResizeStateResetTask: DispatchWorkItem?

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
                !inspectorItem.isCollapsed,
                !splitView.inLiveResize
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

            if splitView.inLiveResize {
                markInspectorResizeInProgress()
            }

            let width = max(inspectorHostingController.view.frame.width, minInspectorWidth)
            syncInspectorWidthAfterResize(width)
        }

        private func syncInspectorWidthAfterResize(_ width: CGFloat) {
            pendingInspectorWidth = width
            pendingInspectorWidthSyncTask?.cancel()

            let syncTask = DispatchWorkItem { [weak self] in
                guard let self, let width = self.pendingInspectorWidth else { return }

                if abs(self.coordinator.inspectorWidth - width) > 0.5 {
                    self.coordinator.inspectorWidth = width
                }
            }

            pendingInspectorWidthSyncTask = syncTask
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24, execute: syncTask)
        }

        private func markInspectorResizeInProgress() {
            if !coordinator.isInspectorResizing {
                coordinator.isInspectorResizing = true
            }
            pendingResizeStateResetTask?.cancel()

            let resetTask = DispatchWorkItem { [weak self] in
                self?.coordinator.isInspectorResizing = false
            }

            pendingResizeStateResetTask = resetTask
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24, execute: resetTask)
        }
    }
}

private struct ThumbnailCell: View {
    @Environment(\.colorScheme) private var colorScheme
    let image: ImageItem
    let isSelected: Bool
    let thumbnailHeight: Double
    let isFavorite: Bool
    let suspendThumbnailLoading: Bool
    let onSelect: () -> Void
    let onOpenPreview: () -> Void
    let onToggleFavorite: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                ThumbnailImage(
                    imageURL: image.fileURL,
                    maximumPixelDimension: max(Int((thumbnailHeight * 2.2).rounded()), 160),
                    isSuspended: suspendThumbnailLoading
                )
                    .frame(height: thumbnailHeight)
                    .frame(maxWidth: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                Button(action: onToggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.headline)
                        .foregroundStyle(isFavorite ? favoriteStarColor : Color.white)
                        .padding(8)
                        .background(.black.opacity(0.35), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(8)
            }

            Text(image.displayLabel)
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
        .onTapGesture {
            onSelect()
        }
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded {
                    onOpenPreview()
                }
        )
    }

    private var cardFillColor: Color {
        if isSelected {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.14 : 0.24)
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

    private var favoriteStarColor: Color {
        Color(
            red: 255.0 / 255.0,
            green: 218.0 / 255.0,
            blue: 107.0 / 255.0
        )
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
    let maximumPixelDimension: Int
    let isSuspended: Bool
    @State private var loadResult: SafeImageLoader.LoadResult?

    var body: some View {
        Group {
            switch loadResult {
            case .success(let nsImage):
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            case .blocked:
                PlaceholderView(title: "", systemImage: "shield")
            case .failed:
                PlaceholderView(title: "No Preview", systemImage: "photo")
            case .none:
                Color.clear
            }
        }
        .onAppear {
            if loadResult == nil,
               let cachedImage = SafeImageLoader.cachedImage(
                for: imageURL,
                maximumThumbnailDimension: maximumPixelDimension
               ) {
                loadResult = .success(cachedImage)
            }
        }
        .task(id: "\(imageURL.path)#\(maximumPixelDimension)#\(isSuspended)") {
            if isSuspended {
                if loadResult == nil,
                   let cachedImage = SafeImageLoader.cachedImage(
                    for: imageURL,
                    maximumThumbnailDimension: maximumPixelDimension
                   ) {
                    loadResult = .success(cachedImage)
                }
                return
            }

            if let cachedImage = SafeImageLoader.cachedImage(
                for: imageURL,
                maximumThumbnailDimension: maximumPixelDimension
            ) {
                loadResult = .success(cachedImage)
                return
            }

            let result = await SafeImageLoader.loadImageAsync(
                for: imageURL,
                maximumThumbnailDimension: maximumPixelDimension
            )
            guard !Task.isCancelled else { return }

            loadResult = result
        }
    }
}

private struct LargePreview: View {
    let imageURL: URL
    @State private var loadResult: SafeImageLoader.LoadResult?

    var body: some View {
        Group {
            switch loadResult {
            case .success(let nsImage):
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            case .blocked(let reason):
                PlaceholderView(title: reason.title, systemImage: "shield", description: reason.message)
                    .frame(height: 260)
            case .failed:
                PlaceholderView(title: "No Preview", systemImage: "photo")
                    .frame(height: 260)
            case .none:
                Color.clear
                    .frame(height: 260)
            }
        }
        .onAppear {
            if loadResult == nil,
               let cachedImage = SafeImageLoader.cachedImage(
                for: imageURL,
                maximumThumbnailDimension: 2_048
               ) {
                loadResult = .success(cachedImage)
            }
        }
        .task(id: imageURL.path) {
            if let cachedImage = SafeImageLoader.cachedImage(
                for: imageURL,
                maximumThumbnailDimension: 2_048
            ) {
                loadResult = .success(cachedImage)
                return
            }

            let result = await SafeImageLoader.loadImageAsync(
                for: imageURL,
                maximumThumbnailDimension: 2_048
            )
            guard !Task.isCancelled else { return }

            loadResult = result
        }
    }
}

struct PlaceholderView: View {
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
