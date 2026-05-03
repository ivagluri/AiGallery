import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
@Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var library: LibraryStore
    @AppStorage("showInspector") private var showInspector = true
    @AppStorage("imageSortOrder") private var imageSortOrderRawValue = ImageSortOrder.alphabeticalAscending.rawValue
    @AppStorage("imageSortToggleMode") private var imageSortToggleModeRawValue = ImageSortToggleMode.cycleAll.rawValue
    @AppStorage("thumbnailSizeIndex") private var thumbnailSizeIndex = 2
    @AppStorage("squareCropThumbnails") private var squareCropThumbnails = false
    @AppStorage("inspectorPanelWidth") private var inspectorPanelWidth = 360.0
    @FocusState private var isSearchFieldFocused: Bool
    @State private var searchText = ""
    @State private var activeSearchText = ""
    @State private var expandedGroupIDs: Set<String> = {
        Set(UserDefaults.standard.stringArray(forKey: "expandedGroupIDs") ?? [])
    }()
    @State private var isInfoExpanded = true
    @State private var isPositivePromptExpanded = true
    @State private var isNegativePromptExpanded = true
    @State private var copiedInspectorValue: String?
    @State private var copiedInspectorResetTask: DispatchWorkItem?
    @State private var savedBrowseSelection: BrowseSelection?
    @State private var searchSelectedImageID: ImageItem.ID?
    @State private var pendingSearchTask: Task<Void, Never>?
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
    @State private var showFilterBar = false
    @State private var facetValues: [MetadataField: [(value: String, count: Int)]] = [:]
    @State private var isAddingSmartFilter = false
    @State private var newSmartFilterName = ""
    @State private var newSmartFilterQuery = ""
    @State private var smartFilterRenameID: UUID?
    @State private var smartFilterRenameDraft = ""
    @State private var isKinActive = false
    @State private var kinMatches: [KinMatch] = []
    @State private var isKinLoading = false
    @State private var kinSourceImage: ImageItem?
    @State private var kinHistory: [ImageItem] = []
    @State private var diffAnchorImage: ImageItem?
    @State private var multiSelectedImageIDs: Set<ImageItem.ID> = []
    @AppStorage("suppressMultiDeleteConfirm") private var suppressMultiDeleteConfirm = false
    @State private var searchScopeCurrentRootOnly = false
    @StateObject private var slideshowCoordinator = SlideshowCoordinator.shared
    @AppStorage("showHiddenFolders") private var showHiddenFolders: Bool = false
    @State private var hiddenNodeIDs: Set<String> = {
        Set(UserDefaults.standard.stringArray(forKey: "hiddenNodeIDs") ?? [])
    }()
    @State private var hiddenImageIDs: Set<String> = {
        Set(UserDefaults.standard.stringArray(forKey: "hiddenImageIDs") ?? [])
    }()
    @State private var pendingNavigationRootURL: URL?

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
                    library.addRootFolder()
                } label: {
                    Label("Add Folder", systemImage: "folder.badge.plus")
                }
                .labelStyle(.iconOnly)
                .help("Add Root Folder")

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
            pushExcludedPaths()
        }
        .onChange(of: library.loadedRootURLs) { _ in
            expandAllGroupsIfNeeded()
            pushExcludedPaths()
            if let pendingURL = pendingNavigationRootURL,
               library.loadedRootURLs.contains(pendingURL) {
                let rootCategory = library.categoryGroups
                    .first { $0.sourceRootURL?.standardizedFileURL == pendingURL.standardizedFileURL }?
                    .categories
                    .first { $0.folderURL.standardizedFileURL == $0.sourceRootURL?.standardizedFileURL }
                if let rootCategory { library.selectCategory(rootCategory) }
                pendingNavigationRootURL = nil
            }
        }
        .onChange(of: hiddenNodeIDs) { _ in pushExcludedPaths() }
        .onChange(of: hiddenImageIDs) { _ in pushExcludedPaths() }
        .onChange(of: showHiddenFolders) { _ in pushExcludedPaths() }
        .onChange(of: library.rootURLs) { _ in
            clearDroppedInspection()
            facetValues = [:]
            // Re-run active search so results from a removed root are evicted.
            let query = trimmedActiveSearchText
            if !query.isEmpty {
                let scopeFolder = searchScopeCurrentRootOnly ? activeScopeFolderURL : nil
                pendingSearchTask?.cancel()
                pendingSearchTask = Task { @MainActor in
                    activeSearchResults = await library.searchWithMetadata(
                        matching: query,
                        limit: Self.maximumSearchResults,
                        limitToFolder: scopeFolder
                    )
                }
            }
        }
        .onChange(of: library.indexProgress) { progress in
            if progress >= 1.0 {
                Task { await loadFacetValues() }
            }
        }
        .task(id: facetLoadID) {
            guard showFilterBar else { return }
            await loadFacetValues()
        }
        .onChange(of: searchText) { newValue in
            handleSearchTextChange(newValue)
        }
        .onChange(of: displayedSelectedImage?.id) { _ in
            syncPreviewSession()
        }
        .onChange(of: slideshowCoordinator.launchRequested) { requested in
            guard requested else { return }
            slideshowCoordinator.launchRequested = false
            launchSlideshow()
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
        .background(
            KeyAwareView(isActive: isSearching) { event in
                guard event.type == .keyDown, event.keyCode == 53 else { return false }
                if diffAnchorImage != nil {
                    withAnimation(.easeOut(duration: 0.18)) { endDiffMode(restoreAnchorSelection: true) }
                }
                clearSearch()
                return true
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

    private var filterBarToggleButton: some View {
        let hasActive = !library.activeMetadataFilters.isEmpty
        let icon = (showFilterBar || hasActive)
            ? "line.3.horizontal.decrease.circle.fill"
            : "line.3.horizontal.decrease.circle"
        return Button {
            relinquishSearchFocus()
            showFilterBar.toggle()
        } label: {
            toolbarIconLabel(showFilterBar ? "Hide Filters" : "Show Filters", systemImage: icon)
        }
        .help(showFilterBar ? "Hide Filter Bar" : "Show Filter Bar")
        .foregroundStyle(hasActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary))
    }

    private var activeScopeFolderURL: URL? {
        guard let cat = library.categories.first(where: { $0.id == library.selectedCategoryID }),
              !cat.isSynthetic else { return nil }
        return cat.folderURL
    }

    private var effectiveFilterScopeURL: URL? {
        activeScopeFolderURL
    }

    private var facetLoadID: String {
        guard showFilterBar else { return "" }
        return effectiveFilterScopeURL?.path ?? "global"
    }

    private var toolbarSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .focused($isSearchFieldFocused)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    activeSearchText = ""
                    pendingSearchTask?.cancel()
                    isSearchFieldFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear Search")
            }

            if library.rootURLs.count > 1 {
                Button {
                    searchScopeCurrentRootOnly.toggle()
                    if !searchText.isEmpty { handleSearchTextChange(searchText) }
                } label: {
                    Image(systemName: searchScopeCurrentRootOnly ? "folder.fill" : "folder")
                        .foregroundStyle(searchScopeCurrentRootOnly ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("l", modifiers: [.command, .option])
                .help(searchScopeCurrentRootOnly
                    ? "Searching current folder only — click or ⌘⌥L to search all folders"
                    : "Searching all folders — click or ⌘⌥L to limit to current folder")
                .disabled(!searchScopeCurrentRootOnly && activeScopeFolderURL == nil)
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
        let mainGroups = library.categoryGroups.filter { $0.id != LibraryStore.smartFiltersGroupID }
        return List {
            ForEach(Array(mainGroups.enumerated()), id: \.element.id) { index, group in
                if group.isSynthetic, let category = group.categories.first, group.categories.count == 1 {
                    let icon = group.id == LibraryStore.smartFiltersGroupID ? "line.3.horizontal.decrease.circle" : "star.fill"
                    categoryRow(category, title: category.name, systemImage: icon)
                        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                        .listRowBackground(sidebarStripeFill(for: index))
                        .overlay(alignment: .top) {
                            sidebarGroupDividerOverlay(isVisible: index > 0)
                        }
                } else {
                    sidebarGroupHeader(group, stripeIndex: index)

                    if isGroupExpanded(group.id) {
                        ForEach(flatVisibleNodes(sidebarNodes(for: group), level: 1), id: \.node.id) { item in
                            sidebarNodeRow(item.node, level: item.level)
                                .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                                .listRowBackground(sidebarStripeFill(for: index))
                                .listRowSeparator(.hidden)
                                .contextMenu {
                                    if hiddenNodeIDs.contains(item.node.id) {
                                        Button("Unhide Folder") {
                                            hiddenNodeIDs.remove(item.node.id)
                                            UserDefaults.standard.set(Array(hiddenNodeIDs), forKey: "hiddenNodeIDs")
                                        }
                                    } else {
                                        Button("Hide Folder") {
                                            hiddenNodeIDs.insert(item.node.id)
                                            UserDefaults.standard.set(Array(hiddenNodeIDs), forKey: "hiddenNodeIDs")
                                        }
                                    }
                                }
                        }
                    }
                }
            }
            smartFiltersSidebarSection
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
        .navigationSplitViewColumnWidth(min: 180, ideal: 260, max: 420)
    }

    @ViewBuilder
    private var smartFiltersSidebarSection: some View {
        let stripeIndex = library.categoryGroups.filter { $0.id != LibraryStore.smartFiltersGroupID }.count
        Section {
            ForEach(library.smartFilters) { filter in
                let categoryID = LibraryStore.smartFilterCategoryID(for: filter.id)
                let category = library.categories.first { $0.id == categoryID }

                if smartFilterRenameID == filter.id {
                    // Inline rename field
                    HStack(spacing: 6) {
                        TextField("Name", text: $smartFilterRenameDraft)
                            .textFieldStyle(.plain)
                            .font(.body)
                            .onSubmit {
                                if !smartFilterRenameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    library.renameSmartFilter(id: filter.id, name: smartFilterRenameDraft.trimmingCharacters(in: .whitespacesAndNewlines))
                                }
                                smartFilterRenameID = nil
                            }
                        Button {
                            smartFilterRenameID = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                } else if let category {
                    let filterTitle = filter.scopeFolderURL.map { "\(filter.name) [\($0.lastPathComponent)]" } ?? filter.name
                    categoryRow(category, title: filterTitle, systemImage: "line.3.horizontal.decrease.circle")
                        .contextMenu {
                            Button("Rename…") {
                                smartFilterRenameDraft = filter.name
                                smartFilterRenameID = filter.id
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                library.removeSmartFilter(id: filter.id)
                            }
                        }
                } else {
                    // Results not yet resolved — show a spinner row
                    let filterTitle = filter.scopeFolderURL.map { "\(filter.name) [\($0.lastPathComponent)]" } ?? filter.name
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .foregroundStyle(.secondary)
                        Text(filterTitle)
                            .foregroundStyle(.secondary)
                        Spacer()
                        ProgressView().scaleEffect(0.6)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contextMenu {
                        Button("Rename…") {
                            smartFilterRenameDraft = filter.name
                            smartFilterRenameID = filter.id
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            library.removeSmartFilter(id: filter.id)
                        }
                    }
                }
            }

            if isAddingSmartFilter {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Name", text: $newSmartFilterName)
                        .textFieldStyle(.plain)
                        .font(.body)
                    TextField("Query", text: $newSmartFilterQuery)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Add") {
                            let name = newSmartFilterName.trimmingCharacters(in: .whitespacesAndNewlines)
                            let query = newSmartFilterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !name.isEmpty && !query.isEmpty {
                                library.addSmartFilter(name: name, query: query)
                            }
                            newSmartFilterName = ""
                            newSmartFilterQuery = ""
                            isAddingSmartFilter = false
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(
                            newSmartFilterName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            newSmartFilterQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                        Button("Cancel") {
                            newSmartFilterName = ""
                            newSmartFilterQuery = ""
                            isAddingSmartFilter = false
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        } header: {
            HStack {
                Text("Smart Filters")
                    .font(.headline)
                Spacer()
                Button {
                    isAddingSmartFilter.toggle()
                    if isAddingSmartFilter {
                        newSmartFilterName = ""
                        newSmartFilterQuery = ""
                    }
                } label: {
                    Image(systemName: isAddingSmartFilter ? "xmark" : "plus")
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .help(isAddingSmartFilter ? "Cancel" : "Add Smart Filter")
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
        }
        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
        .listRowBackground(sidebarStripeFill(for: stripeIndex))
        .overlay(alignment: .top) {
            sidebarGroupDividerOverlay(isVisible: !library.categoryGroups.filter { $0.id != LibraryStore.smartFiltersGroupID }.isEmpty)
        }
    }

    private func isGroupHeaderActive(_ group: CategoryGroup) -> Bool {
        guard let selected = library.selectedCategory, selected.rootGroupID == group.id else { return false }
        return selected.folderURL.standardizedFileURL == selected.sourceRootURL?.standardizedFileURL
    }

    private func sidebarGroupHeader(_ group: CategoryGroup, stripeIndex: Int) -> some View {
        let rootCategory = group.categories.first {
            $0.folderURL.standardizedFileURL == $0.sourceRootURL?.standardizedFileURL
        }
        let hasChildren = !sidebarNodes(for: group).isEmpty
        let isLoadingRoot = group.sourceRootURL.map { library.loadingRootURLs.contains($0) } ?? false
        let isUnloaded = !group.isSynthetic && group.categories.isEmpty && !isLoadingRoot
            && (group.sourceRootURL.map { !library.loadedRootURLs.contains($0) } ?? false)
        return HStack(spacing: 0) {
            // Chevron — only when there are children, still loading, or not yet loaded
            if hasChildren || isLoadingRoot || isUnloaded {
                Button {
                    guard !isLoadingRoot else { return }
                    toggleGroupExpansion(group.id)
                    if isUnloaded, isGroupExpanded(group.id), let rootURL = group.sourceRootURL {
                        library.loadRoot(rootURL)
                    }
                } label: {
                    Group {
                        if isLoadingRoot {
                            ProgressView().scaleEffect(0.6)
                        } else {
                            Image(systemName: isGroupExpanded(group.id) ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 12, height: 12)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Color.clear
                    .frame(width: 12, height: 12)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }

            // Title — navigate only
            Button {
                if isUnloaded, let rootURL = group.sourceRootURL {
                    if !isGroupExpanded(group.id) { toggleGroupExpansion(group.id) }
                    library.loadRoot(rootURL)
                    pendingNavigationRootURL = rootURL
                }
                if let rootCategory { library.selectCategory(rootCategory) }
            } label: {
                HStack(spacing: 8) {
                    Text(group.name)
                        .font(.headline)
                    Spacer()
                    if !isLoadingRoot {
                        Text("\(group.imageCount)")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                .padding(.trailing, 8)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isGroupHeaderActive(group) ? Color.accentColor.opacity(0.14) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
        .listRowBackground(sidebarStripeFill(for: stripeIndex))
        .overlay(alignment: .top) {
            sidebarGroupDividerOverlay(isVisible: stripeIndex > 0)
        }
        .contextMenu {
            if let rootURL = group.sourceRootURL {
                Button("Remove Folder", role: .destructive) {
                    library.removeRootFolder(rootURL)
                }
            }
        }
    }

    private func sidebarNodeRow(_ node: SidebarNode, level: Int) -> some View {
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
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, CGFloat(level) * 14)
        .opacity(hiddenNodeIDs.contains(node.id) ? 0.45 : 1.0)
    }

    private func categoryRow(
        _ category: Category,
        title: String,
        systemImage: String?,
        isActiveOverride: Bool = false
    ) -> some View {
        Button {
            if isSearching { clearSearch() }
            if isKinActive { isKinActive = false; kinHistory = [] }
            if diffAnchorImage != nil { endDiffMode(restoreAnchorSelection: false) }
            clearMultiSelection()
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

    private var kinTaskID: String {
        guard isKinActive else { return "" }
        return kinSourceImage?.id ?? ""
    }

    private var thumbnailGrid: some View {
        Group {
            if isKinActive {
                kinView
            } else if isSearching {
                VStack(spacing: 0) {
                    gridControls(title: "Search Results", subtitle: searchResultsSummary, showSaveSearch: true)
                    if showFilterBar { filterBar }

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
                    if showFilterBar { filterBar }
                    if displayImages.isEmpty && !library.activeMetadataFilters.isEmpty {
                        PlaceholderView(
                            title: "No Matches",
                            systemImage: "line.3.horizontal.decrease.circle",
                            description: "No images in this folder match the active filters."
                        )
                    } else {
                        imageGrid(images: displayImages)
                    }
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
            } else if library.rootURLs.isEmpty {
                PlaceholderView(
                    title: "No Folders Added",
                    systemImage: "photo.on.rectangle.angled",
                    description: "Click the folder button above or use File → Add Root Folder to load your images."
                )
            } else {
                PlaceholderView(title: "Choose a Category", systemImage: "photo.on.rectangle")
            }
        }
        .task(id: kinTaskID) {
            guard isKinActive, let image = kinSourceImage else {
                kinMatches = []
                return
            }
            isKinLoading = true
            kinMatches = await library.kinMatches(for: image)
            isKinLoading = false
        }
        .overlay(alignment: .bottom) {
            if isKinActive || isSearching || library.selectedCategory != nil {
                viewportBottomBar
                    .padding(.bottom, 16)
            }
        }
    }

    private var inspector: some View {
        ScrollView {
            if let image = displayedSelectedImage {
                let metadata = library.inspectorMetadata(for: image)
                let hasPrompts = (metadata?.prompt?.isEmpty == false)
                    || (metadata?.negativePrompt?.isEmpty == false)
                    || (metadata?.promptStatusMessage?.isEmpty == false)
                let additionalMetadataEntries = metadata.map { metadata in
                    metadata.textEntries.filter { entry in
                        shouldDisplayMetadataEntry(
                            entry,
                            hasStructuredMetadata: metadata.prompt != nil
                                || metadata.negativePrompt != nil
                                || !metadata.generationParameters.isEmpty
                        )
                    }
                } ?? []
                let hasInfoContent = isInspectingDroppedImage
                    || hasPrompts
                    || !(metadata?.generationParameters.isEmpty ?? true)
                    || !additionalMetadataEntries.isEmpty

                VStack(alignment: .leading, spacing: 16) {
                    if isInspectingDroppedImage {
                        temporaryInspectionBanner
                    }

                    imageActionStrip(for: image)

                    inspectorPreview(for: image)

                    if let anchor = diffAnchorImage, anchor.id != image.id {
                        diffBanner(anchor: anchor, current: image, currentMetadata: metadata)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if hasInfoContent {
                        InspectorSection("Info", isExpanded: $isInfoExpanded) {
                            if isInspectingDroppedImage {
                                inspectorRow("Source", "Dropped PNG (temporary)")
                            }

                            if hasPrompts {
                                promptsCard(
                                    prompt: metadata?.prompt,
                                    negativePrompt: metadata?.negativePrompt,
                                    promptStatusMessage: metadata?.promptStatusMessage
                                )
                            }

                            if let metadata {
                                ForEach(metadata.generationParameters) { parameter in
                                    inspectorRow(parameter.keyword, parameter.value)
                                }

                                ForEach(additionalMetadataEntries) { entry in
                                    CollapsibleInspectorRow(
                                        label: humanReadablePNGLabel(for: entry.keyword),
                                        value: entry.value
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(20)
                .animation(.easeOut(duration: 0.22), value: diffComparisonAnimationID(for: image))
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

    private func diffComparisonAnimationID(for image: ImageItem) -> String {
        guard let anchor = diffAnchorImage else {
            return "none"
        }

        return "\(anchor.id)->\(image.id)"
    }

    private func endDiffMode(restoreAnchorSelection: Bool) {
        let anchor = diffAnchorImage
        diffAnchorImage = nil

        guard restoreAnchorSelection, let anchor else {
            return
        }

        if isSearching {
            searchSelectedImageID = anchor.id
        } else {
            if library.selectedCategory?.images.contains(where: { $0.id == anchor.id }) != true,
               let anchorCategory = library.categories.first(where: { $0.images.contains { $0.id == anchor.id } }) {
                library.selectCategory(anchorCategory)
            }
            library.selectImage(anchor)
        }

        pendingScrollRequest = GridScrollRequest(targetID: anchor.id, anchor: .center, animated: true)
    }

    @ViewBuilder
    private func inspectorPreview(for image: ImageItem) -> some View {
        if let anchor = diffAnchorImage, anchor.id != image.id {
            comparisonPreview(anchor: anchor, current: image)
        } else {
            standaloneInspectorPreview(for: image)
        }
    }

    private func standaloneInspectorPreview(for image: ImageItem) -> some View {
        LargePreview(imageURL: image.fileURL)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topTrailing) {
                if !isInspectingDroppedImage {
                    previewFavoriteButton(for: image)
                        .padding(12)
                }
            }
    }

    private func comparisonPreview(anchor: ImageItem, current: ImageItem) -> some View {
        ZStack(alignment: .topLeading) {
            LargePreview(imageURL: anchor.fileURL)
                .frame(maxWidth: .infinity)
                .offset(x: 18, y: 14)
                .opacity(0.72)
                .shadow(color: Color.black.opacity(0.16), radius: 8, x: 2, y: 3)
                .allowsHitTesting(false)

            LargePreview(imageURL: current.fileURL)
                .frame(maxWidth: .infinity)
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.accentColor.opacity(0.55), lineWidth: 1)
                }
                .shadow(color: Color.black.opacity(0.24), radius: 12, x: -4, y: 5)
                .overlay(alignment: .topTrailing) {
                    if !isInspectingDroppedImage {
                        previewFavoriteButton(for: current)
                            .padding(12)
                    }
                }
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .opacity
                    )
                )
                .id("diff-front-\(current.id)")
        }
        .padding(.bottom, 16)
        .padding(.trailing, 22)
    }

    private func imageActionStrip(for image: ImageItem) -> some View {
        let isCompareModeActive = diffAnchorImage != nil

        return HStack(spacing: 6) {
            Button { revealInFinder(image.fileURL) } label: {
                Image(systemName: "folder")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(InspectorActionButtonStyle())
            .help("Reveal in Finder")

            Button { copyInspectorValue(image.fileURL.path) } label: {
                Image(systemName: copiedInspectorValue == image.fileURL.path ? "checkmark" : "doc.on.doc")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(copiedInspectorValue == image.fileURL.path ? Color.accentColor : Color.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(InspectorActionButtonStyle())
            .help("Copy Path")

            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    if isCompareModeActive {
                        endDiffMode(restoreAnchorSelection: true)
                    } else {
                        diffAnchorImage = image
                    }
                }
            } label: {
                Image(systemName: "square.split.2x1")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isCompareModeActive ? Color.accentColor : Color.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(InspectorActionButtonStyle())
            .help(isCompareModeActive ? "Stop Comparing" : "Compare with Another Image")

            Button { library.trashImage(image) } label: {
                Image(systemName: "trash")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.red.opacity(0.7))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(InspectorActionButtonStyle())
            .help("Move to Trash")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 2)
    }

    private func promptsCard(prompt: String?, negativePrompt: String?, promptStatusMessage: String?) -> some View {
        PromptInspectorCard(
            isPositiveExpanded: $isPositivePromptExpanded,
            isNegativeExpanded: $isNegativePromptExpanded,
            prompt: prompt,
            negativePrompt: negativePrompt,
            promptStatusMessage: promptStatusMessage,
            copiedValue: copiedInspectorValue,
            onCopy: copyInspectorValue
        )
    }

    private func copyInspectorValue(_ value: String) {
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

    // MARK: - Diff Banner

    private func diffBanner(anchor: ImageItem, current: ImageItem, currentMetadata: ImageMetadata?) -> some View {
        let anchorMetadata = library.inspectorMetadata(for: anchor)
        let diff = PromptDiffService.diff(a: anchorMetadata, b: currentMetadata)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "square.split.2x1")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(anchor.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(current.displayName)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        endDiffMode(restoreAnchorSelection: true)
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if !diff.promptTokens.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Positive Prompt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    DiffTagFlowView(tokens: diff.promptTokens)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            if !diff.negativeTokens.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Negative Prompt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    DiffTagFlowView(tokens: diff.negativeTokens)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            if !diff.parameterDiffs.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    Text("Parameters")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                    ForEach(Array(diff.parameterDiffs.enumerated()), id: \.offset) { _, row in
                        let changed = row.aValue != row.bValue
                        HStack(spacing: 8) {
                            Text(row.key)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 60, alignment: .leading)
                            Text(row.aValue ?? "—")
                                .font(.caption)
                                .foregroundStyle(changed ? Color.red.opacity(0.8) : Color.primary)
                            if changed {
                                Image(systemName: "arrow.right")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(row.bValue ?? "—")
                                    .font(.caption)
                                    .foregroundStyle(Color.green.opacity(0.9))
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 3)
                        .background(changed ? Color.accentColor.opacity(0.08) : Color.clear)
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var imageSortOrder: ImageSortOrder {
        get { ImageSortOrder(rawValue: imageSortOrderRawValue) ?? .alphabeticalAscending }
        nonmutating set { imageSortOrderRawValue = newValue.rawValue }
    }

    private var imageSortToggleMode: ImageSortToggleMode {
        get { ImageSortToggleMode(rawValue: imageSortToggleModeRawValue) ?? .cycleAll }
        nonmutating set { imageSortToggleModeRawValue = newValue.rawValue }
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

    private var saveSearchButton: some View {
        let scope = searchScopeCurrentRootOnly ? activeScopeFolderURL : nil
        let alreadySaved = library.smartFilters.contains { $0.query == activeSearchText && $0.scopeFolderURL == scope }
        return Button {
            guard !alreadySaved else { return }
            library.addSmartFilter(name: activeSearchText, query: activeSearchText, scopeFolderURL: scope)
        } label: {
            Label("Save Search", systemImage: alreadySaved ? "bookmark.fill" : "bookmark")
                .labelStyle(.iconOnly)
        }
        .help(alreadySaved ? "Already saved as Smart Filter" : "Save as Smart Filter")
        .disabled(alreadySaved)
    }

    private func gridControls(title: String, subtitle: String?, showSaveSearch: Bool = false) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                if showSaveSearch { saveSearchButton }
                categoryHeader(title: title, subtitle: subtitle)

                Spacer(minLength: 12)

                previewButton
                slideshowButton
                kinButton
                filterBarToggleButton
                sortButton
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    if showSaveSearch { saveSearchButton }
                    categoryHeader(title: title, subtitle: subtitle)
                }

                HStack(spacing: 16) {
                    previewButton
                    slideshowButton
                    kinButton
                    filterBarToggleButton
                    sortButton
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    if showSaveSearch { saveSearchButton }
                    categoryHeader(title: title, subtitle: subtitle)
                }

                previewButton
                slideshowButton
                kinButton
                filterBarToggleButton
                sortButton
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

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if library.indexProgress < 1.0 {
                    ProgressView()
                        .scaleEffect(0.7)
                        .help("Indexing metadata…")
                }

                ForEach(MetadataField.allCases, id: \.self) { field in
                    let values = facetValues[field] ?? []
                    let active = library.activeMetadataFilters.first { $0.field == field }

                    Menu {
                        if active != nil {
                            Button("Clear \(field.displayName)") {
                                library.removeMetadataFilter(field: field)
                            }
                            Divider()
                        }
                        ForEach(values, id: \.value) { item in
                            Button {
                                library.setMetadataFilter(MetadataFilter(field: field, value: item.value))
                            } label: {
                                Text("\(item.value)  (\(item.count))")
                            }
                        }
                        if values.isEmpty {
                            Text("No values indexed yet")
                                .foregroundStyle(.secondary)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(active?.value ?? field.displayName)
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .imageScale(.small)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(active != nil
                                    ? Color.accentColor.opacity(0.15)
                                    : Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(active != nil
                                    ? Color.accentColor.opacity(0.4)
                                    : Color.primary.opacity(0.08),
                                    lineWidth: 1)
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                if !library.activeMetadataFilters.isEmpty {
                    Button {
                        library.clearMetadataFilters()
                    } label: {
                        Label("Clear Filters", systemImage: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(controlStripBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(controlStripDivider)
                .frame(height: 1)
        }
    }

    private func loadFacetValues() async {
        guard library.hasAnyMetadataIndex else { return }
        let scopeURL = effectiveFilterScopeURL
        var result: [MetadataField: [(value: String, count: Int)]] = [:]
        for field in MetadataField.allCases {
            guard !Task.isCancelled else { return }
            result[field] = await library.facetValues(for: field, scopedToFolder: scopeURL)
        }
        guard !Task.isCancelled else { return }
        facetValues = result
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
                        let effectiveMultiCount: Int = {
                            var ids = multiSelectedImageIDs
                            if let pid = primarySelectedImageID { ids.insert(pid) }
                            return ids.count
                        }()
                        ForEach(images) { image in
                            ThumbnailCell(
                                image: image,
                                isSelected: image.id == selectedImageID,
                                isMultiSelected: multiSelectedImageIDs.contains(image.id),
                                thumbnailHeight: thumbnailSize,
                                squareCrop: squareCropThumbnails,
                                isFavorite: library.isFavorite(image),
                                multiSelectedCount: effectiveMultiCount,
                                suspendThumbnailLoading: isInspectorResizing,
                                isHidden: hiddenImageIDs.contains(image.id),
                                onSelect: {
                                    handleThumbnailTap(image)
                                },
                                onOpenPreview: {
                                    openPreview(for: image)
                                },
                                onStartSlideshow: {
                                    launchSlideshow(startingAt: image)
                                },
                                onToggleFavorite: {
                                    handleThumbnailFavorite(image)
                                },
                                onToggleHidden: {
                                    toggleImageHidden(image)
                                },
                                onTrash: {
                                    handleThumbnailTrash(image)
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
            imageSortOrder = imageSortToggleMode.nextOrder(after: imageSortOrder)
        } label: {
            toolbarIconLabel(imageSortOrder.helpText, systemImage: imageSortOrder.systemImage)
        }
        .fixedSize()
        .help("\(imageSortOrder.helpText). \(imageSortToggleMode.helpText)")
        .contextMenu {
            Button("Cycle All Sort Modes") {
                imageSortToggleMode = .cycleAll
            }

            Divider()

            ForEach(ImageSortOrder.allCases) { order in
                Button {
                    imageSortOrder = order
                    imageSortToggleMode = ImageSortToggleMode.explicitMode(for: order)
                } label: {
                    Label(order.menuTitle, systemImage: order == imageSortOrder ? "checkmark" : order.systemImage)
                }
            }
        }
    }

    private var previewButton: some View {
        Button {
            presentPreview()
        } label: {
            toolbarIconLabel("Open Preview", systemImage: "arrow.up.left.and.arrow.down.right")
        }
        .help("Open Large Preview")
        .disabled(displayedSelectedImage == nil)
    }

    private var viewportBottomBar: some View {
        HStack(spacing: 12) {
            Button {
                squareCropThumbnails.toggle()
            } label: {
                Image(systemName: squareCropThumbnails
                    ? "square.fill"
                    : "rectangle.and.arrow.up.right.and.arrow.down.left")
                    .foregroundStyle(squareCropThumbnails ? Color.accentColor : Color.primary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help(squareCropThumbnails ? "Switch to natural aspect ratio" : "Switch to square crop")

            Divider()
                .frame(height: 16)

            Image(systemName: "square.grid.3x3.fill")
                .font(.caption)
                .foregroundStyle(.secondary)

            Slider(
                value: thumbnailSizeSliderBinding,
                in: 0...Double(Self.thumbnailSizes.count - 1),
                step: 1
            )
            .frame(width: 120)

            Image(systemName: "square.grid.2x2")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
    }

    private var kinButton: some View {
        Button {
            if !isKinActive {
                kinSourceImage = displayedSelectedImage
                kinHistory = []
            }
            isKinActive.toggle()
        } label: {
            toolbarIconLabel("Kin", systemImage: "point.3.connected.trianglepath.dotted")
        }
        .help(isKinActive ? "Exit Kin View" : "Show Kin")
        .disabled(displayedSelectedImage == nil && !isKinActive)
        .foregroundStyle(isKinActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary))
    }

    private var slideshowButton: some View {
        Button {
            launchSlideshow()
        } label: {
            toolbarIconLabel("Slideshow", systemImage: "play.circle")
        }
        .help("Start Slideshow")
        .disabled(displayImages.isEmpty)
    }

    private func toolbarIconLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.iconOnly)
    }

    @ViewBuilder
    private var kinView: some View {
        VStack(spacing: 0) {
            kinControls
            if isKinLoading {
                ProgressView("Finding kin…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if kinMatches.isEmpty {
                PlaceholderView(
                    title: "No Kin Found",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: "No related images were found for this image."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24, pinnedViews: []) {
                        ForEach(groupedKinMatches, id: \.0.displayName) { relationship, matches in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(relationship.displayName)
                                    .font(.headline)
                                    .padding(.horizontal, 20)

                                LazyVGrid(columns: gridColumns, spacing: 16) {
                                    ForEach(matches) { match in
                                        kinThumbnail(for: match)
                                    }
                                }
                                .padding(.horizontal, 20)
                            }
                        }
                    }
                    .padding(.vertical, 20)
                }
            }
        }
    }

    private var kinControls: some View {
        HStack(spacing: 12) {
            Button {
                if let prev = kinHistory.popLast() {
                    kinSourceImage = prev
                } else {
                    isKinActive = false
                }
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .labelStyle(.iconOnly)
            .help(kinHistory.isEmpty ? "Return to Library" : "Back")

            if let image = kinSourceImage {
                Text("Kin: \(image.displayName)")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Kin")
                    .font(.headline)
            }

            Spacer()

            // Pivot: show kin of the currently inspected image (if different from source).
            Button {
                if let current = displayedSelectedImage, current.id != kinSourceImage?.id {
                    if let src = kinSourceImage { kinHistory.append(src) }
                    kinSourceImage = current
                }
            } label: {
                Label("Kin of This Image", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .labelStyle(.iconOnly)
            .help("Show kin of the inspected image")
            .disabled(displayedSelectedImage == nil
                || displayedSelectedImage?.id == kinSourceImage?.id)

            previewButton
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

    private var groupedKinMatches: [(KinRelationship, [KinMatch])] {
        let order: [KinRelationship] = [.sibling, .variant, .upscale, .related]
        return order.compactMap { rel in
            let group = kinMatches.filter { $0.relationship == rel }
            return group.isEmpty ? nil : (rel, group)
        }
    }

    private func kinThumbnail(for match: KinMatch) -> some View {
        ThumbnailCell(
            image: match.image,
            isSelected: match.image.id == displayedSelectedImage?.id,
            isMultiSelected: false,
            thumbnailHeight: thumbnailSize,
            squareCrop: squareCropThumbnails,
            isFavorite: library.isFavorite(match.image),
            multiSelectedCount: 1,
            suspendThumbnailLoading: false,
            isHidden: hiddenImageIDs.contains(match.image.id),
            onSelect: { selectKinMatch(match.image) },
            onOpenPreview: { openPreview(for: match.image) },
            onStartSlideshow: { launchSlideshow(startingAt: match.image) },
            onToggleFavorite: { library.toggleFavorite(match.image) },
            onToggleHidden: { toggleImageHidden(match.image) },
            onTrash: { library.trashImage(match.image) }
        )
        .help(match.reasons.map(\.rawValue).joined(separator: " · "))
    }

    private func selectKinMatch(_ image: ImageItem) {
        let category = library.categories.first { $0.images.contains { $0.id == image.id } }
        if let category {
            library.selectCategory(category)
            library.selectImage(image)
        }
    }

    private func sortedImages(for category: Category) -> [ImageItem] {
        displayImageCache.images(for: category, order: imageSortOrder)
    }

    private func sortedImages(_ items: [ImageItem]) -> [ImageItem] {
        items.sorted { lhs, rhs in
            switch imageSortOrder {
            case .alphabeticalAscending:
                return DisplayImageCache.isNameBefore(lhs, rhs, ascending: true)
            case .alphabeticalDescending:
                return DisplayImageCache.isNameBefore(lhs, rhs, ascending: false)
            case .createdNewestFirst:
                return DisplayImageCache.isDateBefore(lhs.createdAt, rhs.createdAt, ascending: false)
                    ?? DisplayImageCache.isNameBefore(lhs, rhs, ascending: true)
            case .createdOldestFirst:
                return DisplayImageCache.isDateBefore(lhs.createdAt, rhs.createdAt, ascending: true)
                    ?? DisplayImageCache.isNameBefore(lhs, rhs, ascending: true)
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
            // Root-level category is represented by the group header itself — skip.
            guard category.folderURL.standardizedFileURL != category.sourceRootURL?.standardizedFileURL
            else { continue }

            insertSidebarNode(
                category: category,
                remainingParts: category.pathParts,
                accumulatedPath: [group.id],
                nodes: &nodes
            )
        }

        return sortSidebarNodes(nodes)
    }

    private func flatVisibleNodes(_ nodes: [SidebarNode], level: Int) -> [(node: SidebarNode, level: Int)] {
        nodes.flatMap { node -> [(node: SidebarNode, level: Int)] in
            let isHidden = hiddenNodeIDs.contains(node.id)
            if isHidden && !showHiddenFolders { return [] }
            var result: [(node: SidebarNode, level: Int)] = [(node, level)]
            if !isHidden && node.hasChildren && isGroupExpanded(node.id) {
                result += flatVisibleNodes(node.children, level: level + 1)
            }
            return result
        }
    }

    private func isGroupExpanded(_ groupID: String) -> Bool {
        expandedGroupIDs.contains(groupID)
    }

private func isCollapsedActiveNode(_ node: SidebarNode) -> Bool {
        guard node.hasChildren, !isGroupExpanded(node.id), let selectedCategory = library.selectedCategory else {
            return false
        }

        if node.category?.id == selectedCategory.id {
            return false
        }

        // node.pathParts is prefixed with the root group ID (hash); drop it to get the category-relative path.
        let nodeCategoryParts = node.pathParts.count > 1 ? Array(node.pathParts.dropFirst()) : node.pathParts
        return selectedCategory.pathParts.starts(with: nodeCategoryParts)
    }

    private func pushExcludedPaths() {
        if showHiddenFolders {
            library.updateExcludedPaths(folderPaths: [], imagePaths: [])
            return
        }
        var folderPaths = Set<String>()
        for nodeID in hiddenNodeIDs {
            guard let slash = nodeID.firstIndex(of: "/") else { continue }
            let rootHash = String(nodeID[nodeID.startIndex..<slash])
            let relativePath = String(nodeID[nodeID.index(after: slash)...])
            guard let rootURL = library.categoryGroups
                .first(where: { $0.id == rootHash })?.sourceRootURL else { continue }
            folderPaths.insert(rootURL.appendingPathComponent(relativePath).standardizedFileURL.path)
        }
        library.updateExcludedPaths(folderPaths: folderPaths, imagePaths: hiddenImageIDs)
    }

    private func toggleImageHidden(_ image: ImageItem) {
        if hiddenImageIDs.contains(image.id) {
            hiddenImageIDs.remove(image.id)
        } else {
            hiddenImageIDs.insert(image.id)
        }
        UserDefaults.standard.set(Array(hiddenImageIDs), forKey: "hiddenImageIDs")
        pushExcludedPaths()
    }

    private func toggleGroupExpansion(_ groupID: String) {
        if expandedGroupIDs.contains(groupID) {
            expandedGroupIDs.remove(groupID)
        } else {
            expandedGroupIDs.insert(groupID)
        }
        UserDefaults.standard.set(Array(expandedGroupIDs), forKey: "expandedGroupIDs")
    }

    private func expandAllGroupsIfNeeded() {
        let expandableNodeIDs = Set(allExpandableNodeIDs())
        expandedGroupIDs = expandedGroupIDs.intersection(expandableNodeIDs)

        let topLevelGroupIDs = Set(library.categoryGroups.filter { !$0.isSynthetic }.map(\.id))
        if expandedGroupIDs.isEmpty || expandedGroupIDs.intersection(topLevelGroupIDs).isEmpty {
            expandedGroupIDs = expandableNodeIDs
        }
        UserDefaults.standard.set(Array(expandedGroupIDs), forKey: "expandedGroupIDs")
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
        let sorted = nodes.map { node -> SidebarNode in
            var updated = node
            updated.children = sortSidebarNodes(node.children)
            return updated
        }
        return sorted.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
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
        let images: [ImageItem]
        if isSearching {
            images = sortedImages(activeSearchResults.images)
        } else {
            guard let category = library.selectedCategory else { return [] }
            let base = sortedImages(for: category)
            images = library.activeMetadataFilters.isEmpty ? base : base.filter { library.filteredImagePaths.contains($0.id) }
        }
        guard !showHiddenFolders && !hiddenImageIDs.isEmpty else { return images }
        return images.filter { !hiddenImageIDs.contains($0.id) }
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

    private var primarySelectedImageID: ImageItem.ID? {
        isSearching ? searchSelectedImageID : library.selectedImageID
    }

    private var searchResultsSummary: String {
        let resultCount = activeSearchResults.totalMatches
        let visibleCount = activeSearchResults.images.count
        let matchLabel = resultCount == 1 ? "match" : "matches"
        let scopeSuffix: String
        if searchScopeCurrentRootOnly, let root = activeScopeFolderURL {
            scopeSuffix = " in \(root.lastPathComponent)"
        } else {
            scopeSuffix = ""
        }

        if resultCount > visibleCount {
            return "Showing first \(visibleCount) of \(resultCount) \(matchLabel) for \"\(trimmedActiveSearchText)\"\(scopeSuffix)"
        }

        return "\(resultCount) \(matchLabel) for \"\(trimmedActiveSearchText)\"\(scopeSuffix)"
    }

    private var searchPlaceholderDescription: String {
        if trimmedSearchText.count < Self.minimumSearchLength {
            let characterLabel = Self.minimumSearchLength == 1 ? "character" : "characters"
            return "Type at least \(Self.minimumSearchLength) \(characterLabel) to search."
        }

        return "No results matched \"\(trimmedActiveSearchText)\"."
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
            clearMultiSelection()
            savedBrowseSelection = BrowseSelection(
                categoryID: library.selectedCategory?.id,
                imageID: library.selectedImage?.id
            )
        }

        pendingSearchTask?.cancel()

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

        let scopeFolder = searchScopeCurrentRootOnly ? activeScopeFolderURL : nil
        pendingSearchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            activeSearchText = trimmedValue
            activeSearchResults = await library.searchWithMetadata(
                matching: trimmedValue,
                limit: Self.maximumSearchResults,
                limitToFolder: scopeFolder
            )
            guard !Task.isCancelled else { return }
            if let searchSelectedImageID, activeSearchResults.images.contains(where: { $0.id == searchSelectedImageID }) {
                return
            }
            searchSelectedImageID = activeSearchResults.images.first?.id
        }
    }

    private func clearSearch() {
        clearMultiSelection()
        pendingSearchTask?.cancel()
        savedBrowseSelection = nil   // prevent handleSearchTextChange from restoring old selection
        activeSearchText = ""
        activeSearchResults = .empty
        searchSelectedImageID = nil
        isSearchFieldFocused = false
        searchText = ""
    }

    private func clearSearchForRootChange() {
        guard !searchText.isEmpty || !activeSearchText.isEmpty || savedBrowseSelection != nil else {
            return
        }
        clearSearch()
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
        pendingSearchTask?.cancel()
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

    // MARK: - Multi-select helpers

    private func clearMultiSelection() {
        guard !multiSelectedImageIDs.isEmpty else { return }
        multiSelectedImageIDs = []
    }

    private func handleThumbnailTap(_ image: ImageItem) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        let isCmd = flags.contains(.command)
        let isShift = flags.contains(.shift)

        if isCmd {
            handleCmdClick(image)
        } else if isShift {
            handleShiftClick(image)
        } else {
            clearMultiSelection()
            selectImage(image)
        }
    }

    private func handleCmdClick(_ image: ImageItem) {
        let primaryID = primarySelectedImageID
        if let primaryID { multiSelectedImageIDs.insert(primaryID) }
        if multiSelectedImageIDs.contains(image.id) {
            multiSelectedImageIDs.remove(image.id)
        } else {
            multiSelectedImageIDs.insert(image.id)
        }
        selectImage(image)
    }

    private func handleShiftClick(_ image: ImageItem) {
        let images = displayImages
        guard !images.isEmpty else { selectImage(image); return }
        let anchorID = primarySelectedImageID
        let anchorIndex = anchorID.flatMap { id in images.firstIndex { $0.id == id } } ?? 0
        guard let targetIndex = images.firstIndex(where: { $0.id == image.id }) else {
            selectImage(image); return
        }
        let lo = min(anchorIndex, targetIndex)
        let hi = max(anchorIndex, targetIndex)
        multiSelectedImageIDs = Set(images[lo...hi].map(\.id))
        selectImage(image)
    }

    private func handleThumbnailFavorite(_ image: ImageItem) {
        let primaryID = primarySelectedImageID
        let isInGroup = multiSelectedImageIDs.contains(image.id) || image.id == primaryID
        guard !multiSelectedImageIDs.isEmpty && isInGroup else {
            library.toggleFavorite(image)
            return
        }
        var ids = multiSelectedImageIDs
        if let pid = primaryID { ids.insert(pid) }
        let images = displayImages.filter { ids.contains($0.id) }
        let allFavorited = images.allSatisfy { library.isFavorite($0) }
        library.setFavorites(images, favorited: !allFavorited)
    }

    private func handleThumbnailTrash(_ image: ImageItem) {
        let primaryID = primarySelectedImageID
        let isInGroup = multiSelectedImageIDs.contains(image.id) || image.id == primaryID
        if !multiSelectedImageIDs.isEmpty && isInGroup {
            confirmAndTrashMultiSelection()
        } else {
            library.trashImage(image)
        }
    }

    private func confirmAndTrashMultiSelection() {
        var ids = multiSelectedImageIDs
        if let pid = primarySelectedImageID { ids.insert(pid) }
        let images = displayImages.filter { ids.contains($0.id) }
        guard images.count > 1 else {
            if let single = images.first { library.trashImage(single) }
            return
        }
        if suppressMultiDeleteConfirm {
            performMultiDelete(images)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Move \(images.count) Images to Trash?"
        alert.informativeText = "This will move \(images.count) selected images to the Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        guard let window = hostWindow else { performMultiDelete(images); return }
        alert.beginSheetModal(for: window) { [self] response in
            if alert.suppressionButton?.state == .on { suppressMultiDeleteConfirm = true }
            if response == .alertFirstButtonReturn { performMultiDelete(images) }
        }
    }

    private func performMultiDelete(_ images: [ImageItem]) {
        clearMultiSelection()
        library.trashImages(images)
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

        // keyCode 53 = Escape — clear diff anchor / multi-select without consuming the event
        if event.keyCode == 53 {
            if diffAnchorImage != nil {
                withAnimation(.easeOut(duration: 0.18)) {
                    endDiffMode(restoreAnchorSelection: true)
                }
            }
            clearMultiSelection()
        }

        // keyCode 0 = 'a' — Cmd+A selects all images in current view
        if event.keyCode == 0,
           event.modifierFlags.contains(.command),
           !isSearchFieldFocused,
           !(hostWindow?.firstResponder is NSTextView) {
            multiSelectedImageIDs = Set(displayImages.map(\.id))
            return true
        }

        if let previewEventResult = handlePreviewHotkey(event) {
            if let favoriteEventResult = handleFavoriteHotkey(previewEventResult) {
                if let trashEventResult = handleTrashHotkey(favoriteEventResult) {
                    return handleNavigationHotkey(trashEventResult) == nil
                }
                return true
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
            || event.keyCode == 51 && shouldHandleTrashHotkey(event)
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
            handleThumbnailFavorite(image)
        }

        return nil
    }

    private func canHandleHotkey(_ event: NSEvent) -> Bool {
        let disallowedModifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard disallowedModifiers.isEmpty else { return false }
        return !isSearchFieldFocused && !(hostWindow?.firstResponder is NSTextView)
    }

    private func shouldHandlePreviewHotkey(_ event: NSEvent) -> Bool {
        event.keyCode == 49 && displayedSelectedImage != nil && canHandleHotkey(event)
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

        if event.modifierFlags.contains(.shift) {
            extendMultiSelection(delta: delta, absoluteIndex: absoluteIndex, scrollBehavior: scrollBehavior)
        } else {
            clearMultiSelection()
            moveSelection(delta: delta, absoluteIndex: absoluteIndex, scrollBehavior: scrollBehavior)
        }
        return nil
    }

    private func extendMultiSelection(delta: Int?, absoluteIndex: Int?, scrollBehavior: GridScrollBehavior) {
        let images = displayImages
        guard !images.isEmpty else { return }
        let currentID = displayedSelectedImage?.id
        let currentIndex = currentID.flatMap { id in images.firstIndex { $0.id == id } } ?? 0
        let targetIndex: Int
        if let absoluteIndex {
            targetIndex = min(max(absoluteIndex, 0), images.count - 1)
        } else if let delta {
            let proposed = currentIndex + delta
            guard images.indices.contains(proposed) else { return }
            targetIndex = proposed
        } else { return }
        guard images.indices.contains(targetIndex) else { return }
        if let currentID { multiSelectedImageIDs.insert(currentID) }
        multiSelectedImageIDs.insert(images[targetIndex].id)
        moveSelection(delta: delta, absoluteIndex: absoluteIndex, scrollBehavior: scrollBehavior)
    }

    private func shouldHandleFavoriteHotkey(_ event: NSEvent) -> Bool {
        displayedSelectedImage != nil && !isInspectingDroppedImage && canHandleHotkey(event)
    }

    private func handleTrashHotkey(_ event: NSEvent) -> NSEvent? {
        guard event.keyCode == 51, shouldHandleTrashHotkey(event) else {
            return event
        }

        if !multiSelectedImageIDs.isEmpty {
            confirmAndTrashMultiSelection()
        } else if let image = displayedSelectedImage {
            library.trashImage(image)
        }

        return nil
    }

    private func shouldHandleTrashHotkey(_ event: NSEvent) -> Bool {
        shouldHandleFavoriteHotkey(event)
    }

    private func shouldHandleNavigationHotkey(_ event: NSEvent) -> Bool {
        !displayImages.isEmpty && canHandleHotkey(event)
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

    func launchSlideshow(startingAt startImage: ImageItem? = nil) {
        guard !displayImages.isEmpty else { return }
        previewController.dismiss()
        let images = displayImages
        let anchor = startImage ?? displayedSelectedImage
        let idx = anchor.flatMap { img in images.firstIndex { $0.id == img.id } } ?? 0
        SlideshowWindowController.shared.present(
            images: images,
            startIndex: idx,
            settings: SlideshowSettings.shared.snapshot(),
            metadataSource: library
        )
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

        let sessionMetadata = displayedSelectedImage.flatMap { library.inspectorMetadata(for: $0) }

        return PreviewOverlaySession(
            image: displayedSelectedImage,
            capabilities: PreviewOverlayCapabilities(
                supportsNavigation: !isDroppedInspection,
                supportsFavorite: !isDroppedInspection,
                supportsMetadata: false,
                supportsSlideshow: !isDroppedInspection
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
            },
            onStartSlideshow: isDroppedInspection ? nil : {
                launchSlideshow(startingAt: displayedSelectedImage)
            },
            metadata: sessionMetadata
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
    private static let thumbnailSizes: [Double] = [100, 125, 155, 195, 240, 300, 375]
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
            switch order {
            case .alphabeticalAscending:
                return Self.isNameBefore(lhs, rhs, ascending: true)
            case .alphabeticalDescending:
                return Self.isNameBefore(lhs, rhs, ascending: false)
            case .createdNewestFirst:
                return Self.isDateBefore(lhs.createdAt, rhs.createdAt, ascending: false)
                    ?? Self.isNameBefore(lhs, rhs, ascending: true)
            case .createdOldestFirst:
                return Self.isDateBefore(lhs.createdAt, rhs.createdAt, ascending: true)
                    ?? Self.isNameBefore(lhs, rhs, ascending: true)
            }
        }

        return cachedImages
    }

    static func isNameBefore(_ lhs: ImageItem, _ rhs: ImageItem, ascending: Bool) -> Bool {
        let comparison = lhs.displayLabel.localizedCaseInsensitiveCompare(rhs.displayLabel)
        if comparison == .orderedSame {
            let fallback = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            return ascending ? fallback == .orderedAscending : fallback == .orderedDescending
        }
        return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
    }

    static func isDateBefore(_ lhs: Date?, _ rhs: Date?, ascending: Bool) -> Bool? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            guard lhs != rhs else { return nil }
            return ascending ? lhs < rhs : lhs > rhs
        case (nil, nil):
            return nil
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        }
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

private struct InspectorActionButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.primary.opacity(
                        configuration.isPressed ? 0.12 : (isHovered ? 0.08 : 0.04)
                    ))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .onHover { isHovered = $0 }
    }
}

private struct ThumbnailCell: View {
    @Environment(\.colorScheme) private var colorScheme
    private let cardInset: CGFloat = 5.5
    private let labelHeight: CGFloat = 34
    let image: ImageItem
    let isSelected: Bool
    let isMultiSelected: Bool
    let thumbnailHeight: Double
    let squareCrop: Bool
    let isFavorite: Bool
    let multiSelectedCount: Int
    let suspendThumbnailLoading: Bool
    let isHidden: Bool
    let onSelect: () -> Void
    let onOpenPreview: () -> Void
    let onStartSlideshow: () -> Void
    let onToggleFavorite: () -> Void
    let onToggleHidden: () -> Void
    let onTrash: () -> Void

    private var cellWidth: CGFloat {
        CGFloat(thumbnailHeight)
    }

    private var thumbnailSideLength: CGFloat {
        max(cellWidth - (cardInset * 2), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                ThumbnailImage(
                    imageURL: image.fileURL,
                    maximumPixelDimension: max(Int((thumbnailHeight * 2.2).rounded()), 160),
                    isSuspended: suspendThumbnailLoading,
                    squareCrop: squareCrop
                )
                    .frame(
                        width: squareCrop ? thumbnailSideLength : nil,
                        height: squareCrop ? thumbnailSideLength : CGFloat(thumbnailHeight)
                    )
                    .frame(maxWidth: squareCrop ? nil : .infinity)
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
                .frame(maxWidth: .infinity, minHeight: labelHeight, alignment: .topLeading)
        }
        .padding(cardInset)
        .frame(width: cellWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(cardFillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(cardBorderColor, lineWidth: (isSelected || isMultiSelected) ? 1.2 : 1)
        )
        .shadow(
            color: colorScheme == .dark ? .clear : Color.black.opacity((isSelected || isMultiSelected) ? 0.10 : 0.06),
            radius: colorScheme == .dark ? 0 : 8,
            y: colorScheme == .dark ? 0 : 2
        )
        .opacity(isHidden ? 0.45 : 1.0)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            onSelect()
        }
        .contextMenu {
            Group {
                Button {
                    onSelect()
                    onOpenPreview()
                } label: {
                    Label("Open", systemImage: "photo")
                }

                Button {
                    onSelect()
                    onStartSlideshow()
                } label: {
                    Label("Start Slideshow from Here", systemImage: "play.circle")
                }
            }

            Divider()

            Button {
                onSelect()
                onToggleFavorite()
            } label: {
                if multiSelectedCount > 1 {
                    Label("Favorite \(multiSelectedCount) Images", systemImage: "star")
                } else {
                    Label(
                        isFavorite ? "Remove from Favorites" : "Add to Favorites",
                        systemImage: isFavorite ? "star.fill" : "star"
                    )
                }
            }

            Divider()

            Button {
                onSelect()
                revealInFinder()
            } label: {
                Label("Reveal in Finder", systemImage: "finder")
            }

            Divider()

            Group {
                Button {
                    onSelect()
                    if let nsImage = NSImage(contentsOf: image.fileURL) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([nsImage])
                    }
                } label: {
                    Label("Copy Image", systemImage: "doc.on.doc")
                }

                Button {
                    onSelect()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(image.fileURL.path, forType: .string)
                } label: {
                    Label("Copy File Path", systemImage: "doc.on.clipboard")
                }

                Divider()

                Button {
                    onToggleHidden()
                } label: {
                    Label(isHidden ? "Unhide Image" : "Hide Image", systemImage: isHidden ? "eye" : "eye.slash")
                }
            }

            Divider()

            Button(role: .destructive) {
                onTrash()
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
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
        if isMultiSelected {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.08 : 0.14)
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
        if isMultiSelected {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.5 : 0.45)
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

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([image.fileURL])
    }
}

enum ImageSortOrder: String, CaseIterable, Identifiable {
    case alphabeticalAscending
    case alphabeticalDescending
    case createdNewestFirst
    case createdOldestFirst

    var id: String { rawValue }

    var helpText: String {
        switch self {
        case .alphabeticalAscending:
            return "Sort: A to Z"
        case .alphabeticalDescending:
            return "Sort: Z to A"
        case .createdNewestFirst:
            return "Sort: Date Created, Newest First"
        case .createdOldestFirst:
            return "Sort: Date Created, Oldest First"
        }
    }

    var menuTitle: String {
        switch self {
        case .alphabeticalAscending:
            return "Name A to Z"
        case .alphabeticalDescending:
            return "Name Z to A"
        case .createdNewestFirst:
            return "Date Created Newest"
        case .createdOldestFirst:
            return "Date Created Oldest"
        }
    }

    var systemImage: String {
        switch self {
        case .alphabeticalAscending:
            return "arrow.down.circle"
        case .alphabeticalDescending:
            return "arrow.up.circle"
        case .createdNewestFirst:
            return "calendar.badge.clock"
        case .createdOldestFirst:
            return "calendar"
        }
    }

    var next: ImageSortOrder {
        switch self {
        case .alphabeticalAscending:
            return .alphabeticalDescending
        case .alphabeticalDescending:
            return .createdNewestFirst
        case .createdNewestFirst:
            return .createdOldestFirst
        case .createdOldestFirst:
            return .alphabeticalAscending
        }
    }
}

enum ImageSortToggleMode: String {
    case cycleAll
    case alphabetical
    case createdDate

    var helpText: String {
        switch self {
        case .cycleAll:
            return "Click to cycle all modes, or right-click to choose."
        case .alphabetical:
            return "Click to toggle name direction, or right-click to choose."
        case .createdDate:
            return "Click to toggle date direction, or right-click to choose."
        }
    }

    static func explicitMode(for order: ImageSortOrder) -> ImageSortToggleMode {
        switch order {
        case .alphabeticalAscending, .alphabeticalDescending:
            return .alphabetical
        case .createdNewestFirst, .createdOldestFirst:
            return .createdDate
        }
    }

    func nextOrder(after order: ImageSortOrder) -> ImageSortOrder {
        switch self {
        case .cycleAll:
            return order.next
        case .alphabetical:
            return order == .alphabeticalAscending ? .alphabeticalDescending : .alphabeticalAscending
        case .createdDate:
            return order == .createdNewestFirst ? .createdOldestFirst : .createdNewestFirst
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

private struct PromptInspectorCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var isPositiveExpanded: Bool
    @Binding var isNegativeExpanded: Bool
    let prompt: String?
    let negativePrompt: String?
    let promptStatusMessage: String?
    let copiedValue: String?
    let onCopy: (String) -> Void

    var body: some View {
        let showsPositivePrompt = prompt?.isEmpty == false
        let showsNegativePrompt = negativePrompt?.isEmpty == false
        let showsPromptStatusMessage = promptStatusMessage?.isEmpty == false

        VStack(alignment: .leading, spacing: 12) {
            if let prompt, !prompt.isEmpty {
                PromptDisclosureBlock(
                    title: "Positive Prompt",
                    value: prompt,
                    isExpanded: $isPositiveExpanded,
                    isCopied: copiedValue == prompt,
                    onCopy: { onCopy(prompt) }
                )
            }

            if showsPositivePrompt && (showsNegativePrompt || showsPromptStatusMessage) {
                Rectangle()
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08))
                    .frame(height: 1)
            }

            if let promptStatusMessage, !promptStatusMessage.isEmpty {
                Text(promptStatusMessage)
                    .font(.system(.caption, design: .default))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showsPromptStatusMessage && showsNegativePrompt {
                Rectangle()
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08))
                    .frame(height: 1)
            }

            if let negativePrompt, !negativePrompt.isEmpty {
                PromptDisclosureBlock(
                    title: "Negative Prompt",
                    value: negativePrompt,
                    isExpanded: $isNegativeExpanded,
                    isCopied: copiedValue == negativePrompt,
                    onCopy: { onCopy(negativePrompt) }
                )
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    Color.accentColor.opacity(colorScheme == .dark ? 0.10 : 0.08)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    Color.accentColor.opacity(colorScheme == .dark ? 0.20 : 0.16),
                    lineWidth: 1
                )
        )
    }
}

private struct PromptDisclosureBlock: View {
    let title: String
    let value: String
    @Binding var isExpanded: Bool
    let isCopied: Bool
    let onCopy: () -> Void

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
        } label: {
            HStack(spacing: 0) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onCopy) {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(isCopied ? Color.accentColor : Color.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Copy \(title)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

    private func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

private struct ThumbnailImage: View {
    let imageURL: URL
    let maximumPixelDimension: Int
    let isSuspended: Bool
    let squareCrop: Bool
    @State private var loadResult: SafeImageLoader.LoadResult?

    var body: some View {
        Group {
            switch loadResult {
            case .success(let nsImage):
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: squareCrop ? .fill : .fit)
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

private struct CollapsibleInspectorRow: View {
    let label: String
    let value: String

    private static let collapseThreshold = 200

    @State private var isExpanded = false

    var body: some View {
        if value.count > Self.collapseThreshold {
            DisclosureGroup(isExpanded: $isExpanded) {
                Text(value)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            } label: {
                Text(label)
                    .font(.subheadline.weight(.semibold))
            }
        } else {
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

// MARK: - Diff Tag Views

private struct DiffTagFlowView: View {
    let tokens: [DiffToken]

    var body: some View {
        DiffFlowLayout(spacing: 4) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                DiffTagChip(token: token)
            }
        }
    }
}

private struct DiffTagChip: View {
    let token: DiffToken

    var body: some View {
        switch token {
        case .unchanged(let text):
            chip(text, bg: Color.primary.opacity(0.06), fg: Color.secondary, strikethrough: false)
        case .added(let text):
            chip(text, bg: Color.green.opacity(0.15), fg: Color.green, strikethrough: false)
        case .removed(let text):
            chip(text, bg: Color.red.opacity(0.10), fg: Color.red.opacity(0.8), strikethrough: true)
        }
    }

    private func chip(_ text: String, bg: Color, fg: Color, strikethrough: Bool) -> some View {
        Text(text)
            .strikethrough(strikethrough, color: fg)
            .font(.caption)
            .foregroundStyle(fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(bg))
    }
}

private struct DiffFlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? CGFloat.greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0; y += rowH + spacing; rowH = 0
            }
            x += size.width + spacing
            usedWidth = max(usedWidth, x - spacing)
            rowH = max(rowH, size.height)
        }
        // Return the actual used width, never infinity.
        return CGSize(width: min(usedWidth, maxWidth), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowH: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX; y += rowH + spacing; rowH = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}
