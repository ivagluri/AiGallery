import AppKit
import Foundation

final class LibraryStore: ObservableObject {

    // MARK: - Published state

    @Published var rootURLs: [URL] = []
    @Published var categories: [Category] = []
    @Published var selectedCategoryID: Category.ID?
    @Published var selectedImageID: ImageItem.ID?
    @Published var errorMessage: String?
    @Published var isLoading = false
    @Published private(set) var loadedRootURLs: Set<URL> = []
    @Published private(set) var loadingRootURLs: Set<URL> = []
    @Published private(set) var indexProgressByRoot: [URL: Double] = [:]
    @Published var activeMetadataFilters: [MetadataFilter] = []
    @Published var smartFilters: [SmartFilter] = []

    // MARK: - Private state

    private let fileManager = FileManager.default
    private let userDefaults: UserDefaults
    private var pngInfoCache: [String: ImageMetadata?] = [:]
    private var folderMetadataCache: [String: ImageMetadata?] = [:]
    private var sourceCategoriesByRoot: [URL: [Category]] = [:]
    private var searchIndexByRoot: [URL: [ImageItem]] = [:]
    private var metadataIndexes: [URL: MetadataIndex] = [:]
    private var indexScanTasksByRoot: [URL: Task<Void, Never>] = [:]
    private var reloadTask: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?
    private var smartFilterTask: Task<Void, Never>?
    private var favoriteImageIDs: Set<String>
    @Published private(set) var filteredImagePaths: Set<String> = []
    private var smartFilterResults: [UUID: [ImageItem]] = [:]

    // MARK: - Derived

    var sourceCategories: [Category] { sourceCategoriesByRoot.values.flatMap { $0 } }
    private var searchIndex: [ImageItem] { searchIndexByRoot.values.flatMap { $0 } }
    var hasChosenRoot: Bool { !rootURLs.isEmpty }
    var indexProgress: Double {
        guard !indexProgressByRoot.isEmpty else { return 0 }
        return indexProgressByRoot.values.reduce(0, +) / Double(indexProgressByRoot.count)
    }
    var hasAnyMetadataIndex: Bool { !metadataIndexes.isEmpty }

    // MARK: - UserDefaults keys

    private static let rootURLsDefaultsKey = "selectedRootURLs"
    private static let rootURLDefaultsKey = "selectedRootURL"               // legacy migration
    private static let selectedCategoryDefaultsKey = "selectedCategoryID"
    private static let favoriteImageIDsDefaultsKey = "favoriteImageIDsByRoot"
    private static let legacyFavoriteImageIDsDefaultsKey = "favoriteImageIDs"
    private static let globalSmartFiltersDefaultsKey = "globalSmartFilters"
    private static let smartFiltersDefaultsKey = "smartFiltersByRoot"        // legacy migration
    private static let rootCategoryID = "__root__"
    private static let favoritesID = "__favorites__"
    private static let filteredID = "__filtered__"
    static let smartFiltersGroupID = "__smart_filters__"

    static func smartFilterCategoryID(for filterID: UUID) -> String {
        "__smart_\(filterID.uuidString)__"
    }

    // MARK: - Init

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        let persistedURLs = Self.persistedRootURLs(from: userDefaults)
        self.rootURLs = persistedURLs
        self.selectedCategoryID = userDefaults.string(forKey: Self.selectedCategoryDefaultsKey)

        // Favorites: union across all roots
        var combinedFavorites = Set<String>()
        for url in persistedURLs {
            combinedFavorites.formUnion(Self.loadFavoriteImageIDsStatic(for: url, userDefaults: userDefaults))
        }
        self.favoriteImageIDs = combinedFavorites

        // Smart filters: global key with per-root migration
        self.smartFilters = Self.loadGlobalSmartFilters(from: userDefaults, rootURLs: persistedURLs)

        // Eagerly load the root that owns the saved selectedCategoryID, or the first root.
        let activeURL = Self.rootURLForSavedCategory(
            selectedCategoryID: selectedCategoryID,
            rootURLs: persistedURLs
        ) ?? persistedURLs.first

        if let url = activeURL {
            // Load off the main thread so the window activation event isn't dropped
            // while the filesystem scan runs.
            isLoading = true
            Task { [weak self] in
                await self?.performInitialLoad(activeURL: url, allURLs: persistedURLs)
            }
        } else {
            categories = []
            persistSelectedCategoryID(nil)
            selectedImageID = nil
        }

        // Background-index non-active roots immediately; active root is indexed
        // after performInitialLoad populates its searchIndex.
        for url in persistedURLs where url != activeURL {
            startBackgroundIndexing(for: url)
        }
    }

    private func performInitialLoad(activeURL: URL, allURLs: [URL]) async {
        let profile = GeneralLibraryProfile()
        do {
            let (loaded, index) = try await Task.detached(priority: .userInitiated) {
                try Self.buildLibrary(rootURL: activeURL, profile: profile)
            }.value
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.sourceCategoriesByRoot[activeURL] = loaded
                self.searchIndexByRoot[activeURL] = index
                self.loadedRootURLs = [activeURL]
                self.pruneFavoritesToExistingImages()
                self.rebuildCategories()
                self.selectedCategoryID = Self.validCategoryID(current: self.selectedCategoryID, categories: self.categories)
                self.selectedImageID = Self.validImageID(
                    current: self.selectedImageID,
                    categories: self.categories,
                    selectedCategoryID: self.selectedCategoryID
                )
                self.isLoading = false
                self.startBackgroundIndexing(for: activeURL)
            }
        } catch {
            await MainActor.run { [weak self] in
                self?.isLoading = false
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Computed navigation

    var selectedCategory: Category? {
        categories.first { $0.id == selectedCategoryID } ?? categories.first
    }

    var categoryGroups: [CategoryGroup] {
        // Build groups from loaded categories
        var groups: [CategoryGroup] = Dictionary(grouping: categories, by: \.rootGroupID)
            .values
            .map { groupedCategories in
                let sorted = groupedCategories.sorted { lhs, rhs in
                    lhs.pathParts.map { $0.lowercased() }.joined(separator: "/")
                        .localizedCaseInsensitiveCompare(
                            rhs.pathParts.map { $0.lowercased() }.joined(separator: "/")
                        ) == .orderedAscending
                }
                let first = sorted[0]
                return CategoryGroup(
                    id: first.rootGroupID,
                    name: first.rootGroupName,
                    categories: sorted,
                    isSynthetic: first.isSynthetic,
                    sourceRootURL: first.sourceRootURL
                )
            }

        // Add placeholder groups for registered-but-unloaded roots
        let loadedGroupIDs = Set(groups.map(\.id))
        for url in rootURLs {
            let hash = rootURLHash(url)
            guard !loadedGroupIDs.contains(hash) else { continue }
            groups.append(CategoryGroup(
                id: hash,
                name: url.lastPathComponent,
                categories: [],
                isSynthetic: false,
                sourceRootURL: url
            ))
        }

        return groups.sorted { lhs, rhs in
            if lhs.isSynthetic != rhs.isSynthetic { return lhs.isSynthetic }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    var selectedImage: ImageItem? {
        guard let category = selectedCategory else { return nil }
        return category.images.first { $0.id == selectedImageID } ?? category.images.first
    }

    var allImages: [ImageItem] {
        sourceCategories.flatMap(\.images)
    }

    // MARK: - Reload

    func reload() {
        reloadTask?.cancel()
        let urlsToReload = Array(loadedRootURLs)
        guard !urlsToReload.isEmpty else { return }
        let profile = GeneralLibraryProfile()
        isLoading = true

        reloadTask = Task {
            do {
                var collected: [(url: URL, cats: [Category], idx: [ImageItem])] = []
                for url in urlsToReload {
                    let (cats, idx) = try await Task.detached(priority: .userInitiated) {
                        try Self.buildLibrary(rootURL: url, profile: profile)
                    }.value
                    try Task.checkCancellation()
                    collected.append((url, cats, idx))
                }
                let finalCats = Dictionary(uniqueKeysWithValues: collected.map { ($0.url, $0.cats) })
                let finalIdx  = Dictionary(uniqueKeysWithValues: collected.map { ($0.url, $0.idx) })

                await MainActor.run {
                    sourceCategoriesByRoot = finalCats
                    searchIndexByRoot = finalIdx
                    pngInfoCache.removeAll()
                    folderMetadataCache.removeAll()
                    pruneFavoritesToExistingImages()
                    rebuildCategories()
                    selectedCategoryID = Self.validCategoryID(current: selectedCategoryID, categories: categories)
                    persistSelectedCategoryID(selectedCategoryID)
                    selectedImageID = Self.validImageID(
                        current: selectedImageID, categories: categories, selectedCategoryID: selectedCategoryID
                    )
                    errorMessage = nil
                    isLoading = false
                    for url in urlsToReload { startBackgroundIndexing(for: url) }
                }
            } catch is CancellationError {
                // superseded by a newer reload
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    // MARK: - Lazy root loading

    func loadRoot(_ url: URL) {
        guard !loadedRootURLs.contains(url), !loadingRootURLs.contains(url) else { return }
        loadingRootURLs.insert(url)
        let profile = GeneralLibraryProfile()

        Task {
            do {
                let (cats, idx) = try await Task.detached(priority: .userInitiated) {
                    try Self.buildLibrary(rootURL: url, profile: profile)
                }.value
                try Task.checkCancellation()

                await MainActor.run {
                    sourceCategoriesByRoot[url] = cats
                    searchIndexByRoot[url] = idx
                    loadedRootURLs.insert(url)
                    loadingRootURLs.remove(url)
                    pruneFavoritesToExistingImages()
                    rebuildCategories()
                    // Don't reset selectedCategoryID — user may have navigated via search
                    startBackgroundIndexing(for: url)
                }
            } catch {
                Task { @MainActor [weak self] in self?.loadingRootURLs.remove(url) }
            }
        }
    }

    // MARK: - Add / remove root folders

    func addRootFolder(completion: ((Bool) -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose one or more folders containing your image folders."

        panel.begin { [weak self] result in
            guard let self else { return }
            guard result == .OK, !panel.urls.isEmpty else { completion?(false); return }

            var added = false
            for url in panel.urls {
                let standardized = url.standardizedFileURL
                guard !self.rootURLs.contains(where: { $0.standardizedFileURL == standardized }) else { continue }
                self.rootURLs.append(standardized)
                added = true
            }

            if added {
                self.persistRootURLs()
                // Background-index new roots immediately; category load is lazy
                for url in panel.urls {
                    let standardized = url.standardizedFileURL
                    if !self.loadedRootURLs.contains(standardized) {
                        self.startBackgroundIndexing(for: standardized)
                    }
                }
                // Trigger rebuildCategories so placeholder groups appear
                self.rebuildCategories()
            }
            completion?(added)
        }
    }

    func removeRootFolder(_ url: URL) {
        let standardized = url.standardizedFileURL
        rootURLs.removeAll { $0.standardizedFileURL == standardized }
        loadedRootURLs.remove(standardized)
        loadingRootURLs.remove(standardized)
        sourceCategoriesByRoot.removeValue(forKey: standardized)
        searchIndexByRoot.removeValue(forKey: standardized)
        indexScanTasksByRoot[standardized]?.cancel()
        indexScanTasksByRoot.removeValue(forKey: standardized)
        metadataIndexes.removeValue(forKey: standardized)
        indexProgressByRoot.removeValue(forKey: standardized)
        persistRootURLs()
        // Evict stale smart filter results from this root, then re-resolve against remaining indexes.
        smartFilterTask?.cancel()
        smartFilterResults = [:]
        rebuildCategories()
        selectedCategoryID = Self.validCategoryID(current: selectedCategoryID, categories: categories)
        persistSelectedCategoryID(selectedCategoryID)
        selectedImageID = Self.validImageID(
            current: selectedImageID, categories: categories, selectedCategoryID: selectedCategoryID
        )
        // Re-run filters/smart-filters against remaining indexes.
        if !activeMetadataFilters.isEmpty { applyMetadataFilters() }
        smartFilterTask = Task { await resolveSmartFilters() }
    }

    // MARK: - Category / image selection

    func selectCategory(_ category: Category?) {
        selectedCategoryID = category?.id
        persistSelectedCategoryID(selectedCategoryID)
        selectedImageID = category?.images.first?.id
    }

    func selectImage(_ image: ImageItem?) {
        selectedImageID = image?.id
    }

    // MARK: - Favorites

    func isFavorite(_ image: ImageItem) -> Bool {
        favoriteImageIDs.contains(image.id)
    }

    func toggleFavorite(_ image: ImageItem) {
        if favoriteImageIDs.contains(image.id) {
            favoriteImageIDs.remove(image.id)
        } else {
            favoriteImageIDs.insert(image.id)
        }
        persistFavoriteImageIDs()
        rebuildCategories()
        selectedCategoryID = Self.validCategoryID(current: selectedCategoryID, categories: categories)
        persistSelectedCategoryID(selectedCategoryID)
        selectedImageID = Self.validImageID(
            current: selectedImageID, categories: categories, selectedCategoryID: selectedCategoryID
        )
    }

    // MARK: - Trash

    func trashImage(_ image: ImageItem) {
        try? FileManager.default.trashItem(at: image.fileURL, resultingItemURL: nil)

        for (rootURL, cats) in sourceCategoriesByRoot {
            sourceCategoriesByRoot[rootURL] = cats.map { cat in
                Category(
                    id: cat.id, name: cat.name, shortName: cat.shortName,
                    pathParts: cat.pathParts, rootGroupID: cat.rootGroupID, rootGroupName: cat.rootGroupName,
                    folderURL: cat.folderURL, images: cat.images.filter { $0.id != image.id },
                    isSynthetic: cat.isSynthetic, sourceRootURL: cat.sourceRootURL
                )
            }
        }
        for (rootURL, idx) in searchIndexByRoot {
            searchIndexByRoot[rootURL] = idx.filter { $0.id != image.id }
        }

        favoriteImageIDs.remove(image.id)
        persistFavoriteImageIDs()
        rebuildCategories()
        selectedCategoryID = Self.validCategoryID(current: selectedCategoryID, categories: categories)
        persistSelectedCategoryID(selectedCategoryID)
        selectedImageID = Self.validImageID(
            current: selectedImageID, categories: categories, selectedCategoryID: selectedCategoryID
        )
    }

    func trashImages(_ images: [ImageItem]) {
        guard !images.isEmpty else { return }
        let ids = Set(images.map(\.id))
        for image in images {
            try? FileManager.default.trashItem(at: image.fileURL, resultingItemURL: nil)
        }
        for (rootURL, cats) in sourceCategoriesByRoot {
            sourceCategoriesByRoot[rootURL] = cats.map { cat in
                Category(
                    id: cat.id, name: cat.name, shortName: cat.shortName,
                    pathParts: cat.pathParts, rootGroupID: cat.rootGroupID, rootGroupName: cat.rootGroupName,
                    folderURL: cat.folderURL, images: cat.images.filter { !ids.contains($0.id) },
                    isSynthetic: cat.isSynthetic, sourceRootURL: cat.sourceRootURL
                )
            }
        }
        for (rootURL, idx) in searchIndexByRoot {
            searchIndexByRoot[rootURL] = idx.filter { !ids.contains($0.id) }
        }
        favoriteImageIDs.subtract(ids)
        persistFavoriteImageIDs()
        rebuildCategories()
        selectedCategoryID = Self.validCategoryID(current: selectedCategoryID, categories: categories)
        persistSelectedCategoryID(selectedCategoryID)
        selectedImageID = Self.validImageID(
            current: selectedImageID, categories: categories, selectedCategoryID: selectedCategoryID
        )
    }

    // MARK: - Metadata filters

    func setMetadataFilter(_ filter: MetadataFilter) {
        activeMetadataFilters.removeAll { $0.field == filter.field }
        activeMetadataFilters.append(filter)
        applyMetadataFilters()
    }

    func removeMetadataFilter(field: MetadataField) {
        activeMetadataFilters.removeAll { $0.field == field }
        applyMetadataFilters()
    }

    func clearMetadataFilters() {
        activeMetadataFilters = []
        filteredImagePaths = []
        filterTask?.cancel()
    }

    // MARK: - Metadata info

    func pngInfo(for image: ImageItem) -> ImageMetadata? {
        if let cached = pngInfoCache[image.id] { return cached }
        let info = PNGInfoReader.read(from: image.fileURL)
        pngInfoCache[image.id] = info
        return info
    }

    func inspectorMetadata(for image: ImageItem) -> ImageMetadata? {
        let pngInfo = pngInfo(for: image)
        let folderMeta = folderMetadata(for: image)

        let prompt = pngInfo?.prompt ?? folderMeta?.prompt
        let negativePrompt = pngInfo?.negativePrompt ?? folderMeta?.negativePrompt
        let promptStatusMessage = prompt == nil
            ? (pngInfo?.promptStatusMessage ?? folderMeta?.promptStatusMessage)
            : nil
        let generationParameters = mergeEntries(
            primary: pngInfo?.generationParameters ?? [],
            fallback: folderMeta?.generationParameters ?? []
        )
        let textEntries = mergeEntries(
            primary: pngInfo?.textEntries ?? [],
            fallback: folderMeta?.textEntries ?? []
        )
        let metadata = ImageMetadata(
            prompt: prompt, negativePrompt: negativePrompt,
            promptStatusMessage: promptStatusMessage,
            generationParameters: generationParameters, textEntries: textEntries
        )
        return metadata.hasVisibleContent ? metadata : nil
    }

    func kinMatches(for image: ImageItem) async -> [KinMatch] {
        guard !metadataIndexes.isEmpty else { return [] }

        // Source context: prompt from PNG (most accurate), index row for model/seed/dims/modDate.
        let sourceMeta = inspectorMetadata(for: image)
        var sourceRow: IndexedImageRow? = nil
        for index in metadataIndexes.values {
            if let r = await index.metadata(for: image.id) { sourceRow = r; break }
        }

        let context = KinService.SourceContext(
            item: image,
            prompt: sourceMeta?.prompt,
            row: sourceRow
        )

        // Build a path → item lookup once.
        let itemsByPath = Dictionary(uniqueKeysWithValues: allImages.map { ($0.id, $0) })

        // 1. Same-folder candidates (always included, no index needed).
        let folderPath = image.fileURL.deletingLastPathComponent().path
        let sameFolderItems = allImages.filter {
            $0.id != image.id
                && $0.fileURL.deletingLastPathComponent().path == folderPath
        }
        var candidatePaths = Set(sameFolderItems.map(\.id))
        let sameFolderPaths = candidatePaths

        // 2. Same-seed candidates (cross-library, capped at 30 new).
        if let seed = sourceRow?.seed, !seed.isEmpty {
            var seedPaths = Set<String>()
            for index in metadataIndexes.values {
                seedPaths.formUnion(await index.imagePaths(withSeed: seed))
            }
            let novel = Array(seedPaths.subtracting(candidatePaths).subtracting([image.id])).prefix(30)
            candidatePaths.formUnion(novel)
        }

        // 3. Same-model candidates (cross-library, capped at 30 new).
        if let model = sourceRow?.model, !model.isEmpty {
            var modelPaths = Set<String>()
            for index in metadataIndexes.values {
                modelPaths.formUnion(await index.imagePaths(matching: [MetadataFilter(field: .model, value: model)]))
            }
            let novel = Array(modelPaths.subtracting(candidatePaths).subtracting([image.id])).prefix(30)
            candidatePaths.formUnion(novel)
        }

        // 4. Prompt-keyword candidates — most distinctive word (length > 4), capped at 20 new.
        if let prompt = sourceMeta?.prompt, !prompt.isEmpty {
            let keyword = prompt
                .components(separatedBy: .whitespacesAndNewlines)
                .first { $0.count > 4 }
            if let keyword {
                var promptPaths = Set<String>()
                for index in metadataIndexes.values {
                    promptPaths.formUnion(await index.imagePathsWherePromptContains(keyword))
                }
                let novel = Array(promptPaths.subtracting(candidatePaths).subtracting([image.id])).prefix(20)
                candidatePaths.formUnion(novel)
            }
        }

        // Score all candidates.
        let profile = GeneralLibraryProfile()
        var matches: [KinMatch] = []
        for path in candidatePaths {
            let url = URL(fileURLWithPath: path)
            guard let item = itemsByPath[path]
                ?? (Self.isSupportedImage(url) ? Self.makeImageItem(from: url, profile: profile) : nil)
            else { continue }

            var candidateRow: IndexedImageRow? = nil
            for index in metadataIndexes.values {
                if let r = await index.metadata(for: path) { candidateRow = r; break }
            }

            let input = KinService.CandidateInput(
                item: item,
                row: candidateRow,
                isSameFolder: sameFolderPaths.contains(path)
            )
            if let match = KinService.evaluate(input, source: context) {
                matches.append(match)
            }
        }

        return Array(matches.sorted { $0.score > $1.score }.prefix(KinService.maxResults))
    }

    func temporaryInspectionImage(for fileURL: URL) -> ImageItem? {
        guard fileURL.pathExtension.lowercased() == "png", Self.isSupportedImage(fileURL) else { return nil }
        return Self.makeImageItem(from: fileURL, profile: GeneralLibraryProfile())
    }

    // MARK: - Search

    func searchTags(matching query: String, limit: Int) -> SearchResult {
        GeneralLibraryProfile().search(matching: query, in: searchIndex, limit: limit)
    }

    func searchWithMetadata(matching query: String, limit: Int, limitToFolder: URL? = nil) async -> SearchResult {
        let effectiveSearchIndex: [ImageItem]
        let effectiveMetaIndexes: [URL: MetadataIndex]
        let folderPathPrefix: String?
        if let folder = limitToFolder {
            let prefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
            let root = rootURLs.first(where: { folder.path.hasPrefix($0.path) })
            let rootImages = root.flatMap { searchIndexByRoot[$0] } ?? searchIndex
            effectiveSearchIndex = rootImages.filter { $0.fileURL.path.hasPrefix(prefix) }
            effectiveMetaIndexes = root.flatMap { r in metadataIndexes[r].map { [r: $0] } } ?? metadataIndexes
            folderPathPrefix = prefix
        } else {
            effectiveSearchIndex = searchIndex
            effectiveMetaIndexes = metadataIndexes
            folderPathPrefix = nil
        }

        let filenameResult = GeneralLibraryProfile().search(matching: query, in: effectiveSearchIndex, limit: limit)
        guard !effectiveMetaIndexes.isEmpty else { return filenameResult }

        let parsedQuery = parseSearchQuery(query)
        guard !parsedQuery.isEmpty else { return filenameResult }

        var metadataExcludedPaths = Set<String>()
        for term in parsedQuery.excludedTerms {
            metadataExcludedPaths.formUnion(await metadataPaths(containing: term, in: effectiveMetaIndexes))
        }

        let filenameImages = metadataExcludedPaths.isEmpty
            ? filenameResult.images
            : filenameResult.images.filter { !metadataExcludedPaths.contains($0.id) }
        let filenamePathSet = Set(filenameImages.map(\.id))

        // AND across required terms, union across effective indexes.
        var matchingMetadataPaths: Set<String>? = nil
        if parsedQuery.requiredTerms.isEmpty, !parsedQuery.excludedTerms.isEmpty {
            var allPaths = Set<String>()
            for index in effectiveMetaIndexes.values {
                allPaths.formUnion(await index.allImagePaths())
            }
            matchingMetadataPaths = allPaths
        } else {
            for term in parsedQuery.requiredTerms {
                let termPaths = await metadataPaths(containing: term, in: effectiveMetaIndexes)
                if var accumulated = matchingMetadataPaths {
                    accumulated.formIntersection(termPaths)
                    matchingMetadataPaths = accumulated
                } else {
                    matchingMetadataPaths = termPaths
                }
            }
        }

        let duplicatePathSet = parsedQuery.requiredTerms.isEmpty
            ? Set(effectiveSearchIndex.map(\.id))
            : filenamePathSet
        var newMetadataPaths = (matchingMetadataPaths ?? [])
            .subtracting(duplicatePathSet)
            .subtracting(metadataExcludedPaths)
        if let prefix = folderPathPrefix {
            newMetadataPaths = newMetadataPaths.filter { $0.hasPrefix(prefix) }
        }

        // Resolve paths: use in-memory item if available, otherwise build lightweight item from path.
        let loadedItems = Dictionary(uniqueKeysWithValues: searchIndex.map { ($0.id, $0) })
        let profile = GeneralLibraryProfile()
        let metadataImages: [ImageItem] = newMetadataPaths.compactMap { path in
            if let item = loadedItems[path] { return item }
            let url = URL(fileURLWithPath: path)
            guard Self.isSupportedImage(url) else { return nil }
            return Self.makeImageItem(from: url, profile: profile)
        }

        let excludedVisibleFilenameCount = filenameResult.images.count - filenameImages.count
        let adjustedFilenameTotal = max(0, filenameResult.totalMatches - excludedVisibleFilenameCount)
        let combined = filenameImages + metadataImages
        return SearchResult(
            images: Array(combined.prefix(limit)),
            totalMatches: adjustedFilenameTotal + metadataImages.count
        )
    }

    private func metadataPaths(containing term: String, in indexes: [URL: MetadataIndex]) async -> Set<String> {
        var termPaths = Set<String>()
        for index in indexes.values {
            for field in MetadataField.allCases {
                termPaths.formUnion(await index.imagePaths(where: field, contains: term))
            }
            termPaths.formUnion(await index.imagePathsWherePromptContains(term))
        }
        return termPaths
    }

    func facetValues(for field: MetadataField, scopedToFolder folderURL: URL? = nil) async -> [(value: String, count: Int)] {
        var merged: [String: Int] = [:]
        if let folder = folderURL {
            let prefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
            let root = rootURLs.first { folder.path.hasPrefix($0.path) }
            let relevantIndexes: [MetadataIndex] = root.flatMap { metadataIndexes[$0] }.map { [$0] }
                ?? Array(metadataIndexes.values)
            for index in relevantIndexes {
                for (value, count) in await index.facetValues(for: field, withinFolderPrefix: prefix) {
                    merged[value, default: 0] += count
                }
            }
        } else {
            for index in metadataIndexes.values {
                for (value, count) in await index.facetValues(for: field) {
                    merged[value, default: 0] += count
                }
            }
        }
        return merged.sorted { $0.value > $1.value }.map { (value: $0.key, count: $0.value) }
    }

    // MARK: - Private helpers

    private static func loadImages(in folderURL: URL, profile: any LibraryProfile) throws -> [ImageItem] {
        let imageURLs = try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter(isSupportedImage)
        .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        return imageURLs.map { makeImageItem(from: $0, profile: profile) }
    }

    private func folderMetadata(for image: ImageItem) -> ImageMetadata? {
        let folderPath = image.fileURL.deletingLastPathComponent().path
        if let cached = folderMetadataCache[folderPath] { return cached }
        let info = FolderMetadataReader.read(from: image.fileURL.deletingLastPathComponent())
        folderMetadataCache[folderPath] = info
        return info
    }

    private func mergeEntries(primary: [PNGTextEntry], fallback: [PNGTextEntry]) -> [PNGTextEntry] {
        var merged = primary
        let existingKeys = Set(primary.map { $0.keyword.lowercased() })
        for entry in fallback where !existingKeys.contains(entry.keyword.lowercased()) {
            merged.append(entry)
        }
        return merged
    }

    private func applyMetadataFilters() {
        filterTask?.cancel()
        guard !activeMetadataFilters.isEmpty, !metadataIndexes.isEmpty else {
            filteredImagePaths = []
            return
        }
        let filters = activeMetadataFilters
        let indexes = Array(metadataIndexes.values)
        filterTask = Task {
            var acc = Set<String>()
            for index in indexes {
                acc.formUnion(await index.imagePaths(matching: filters))
            }
            guard !Task.isCancelled else { return }
            let finalPaths = acc
            await MainActor.run { [weak self] in
                self?.filteredImagePaths = finalPaths
            }
        }
    }

    // MARK: - Smart Filters

    func addSmartFilter(name: String, query: String, scopeFolderURL: URL? = nil) {
        let filter = SmartFilter(name: name, query: query, scopeFolderURL: scopeFolderURL)
        smartFilters.append(filter)
        persistSmartFilters()
        smartFilterTask?.cancel()
        smartFilterTask = Task { await resolveSmartFilters() }
    }

    func removeSmartFilter(id: UUID) {
        smartFilters.removeAll { $0.id == id }
        smartFilterResults.removeValue(forKey: id)
        persistSmartFilters()
        rebuildCategories()
    }

    func renameSmartFilter(id: UUID, name: String) {
        guard let idx = smartFilters.firstIndex(where: { $0.id == id }) else { return }
        smartFilters[idx].name = name
        persistSmartFilters()
        rebuildCategories()
    }

    private func persistSmartFilters() {
        if let data = try? JSONEncoder().encode(smartFilters) {
            userDefaults.set(data, forKey: Self.globalSmartFiltersDefaultsKey)
        }
    }

    private static func loadGlobalSmartFilters(from userDefaults: UserDefaults, rootURLs: [URL]) -> [SmartFilter] {
        // Try global key first
        if let data = userDefaults.data(forKey: globalSmartFiltersDefaultsKey),
           let filters = try? JSONDecoder().decode([SmartFilter].self, from: data) {
            return filters
        }
        // Migration: merge per-root smart filters into global list
        var merged: [SmartFilter] = []
        var seenIDs = Set<UUID>()
        for url in rootURLs {
            let key = favoriteImageIDsStorageKey(for: url)
            guard
                let byRoot = userDefaults.dictionary(forKey: smartFiltersDefaultsKey) as? [String: Data],
                let data = byRoot[key],
                let filters = try? JSONDecoder().decode([SmartFilter].self, from: data)
            else { continue }
            for f in filters where !seenIDs.contains(f.id) {
                merged.append(f)
                seenIDs.insert(f.id)
            }
        }
        return merged
    }

    private func resolveSmartFilters() async {
        let filters = smartFilters
        guard !filters.isEmpty else { return }
        var newResults: [UUID: [ImageItem]] = [:]
        for filter in filters {
            let result = await searchWithMetadata(matching: filter.query, limit: 10_000, limitToFolder: filter.scopeFolderURL)
            newResults[filter.id] = result.images
        }
        let resolvedResults = newResults
        await MainActor.run { [weak self] in
            guard let self else { return }
            self.smartFilterResults = resolvedResults
            self.rebuildCategories()
            self.selectedCategoryID = Self.validCategoryID(
                current: self.selectedCategoryID, categories: self.categories
            )
        }
    }

    // MARK: - Background indexing

    private func startBackgroundIndexing(for url: URL) {
        indexScanTasksByRoot[url]?.cancel()
        indexProgressByRoot[url] = 0
        let profile = GeneralLibraryProfile()

        indexScanTasksByRoot[url] = Task {
            do {
                let index = try MetadataIndex(rootURL: url)
                await MainActor.run { [weak self] in self?.metadataIndexes[url] = index }
                guard !Task.isCancelled else { return }

                // Use in-memory search index if loaded; otherwise light-scan the filesystem.
                let inMemory = await MainActor.run(resultType: [ImageItem].self) { [weak self] in
                    self?.searchIndexByRoot[url] ?? []
                }
                let images: [ImageItem]
                if !inMemory.isEmpty {
                    images = inMemory
                } else {
                    images = (try? await Task.detached(priority: .background) {
                        try Self.buildLibrary(rootURL: url, profile: profile).searchIndex
                    }.value) ?? []
                    // Make the scan visible to search and smart-filter resolution without
                    // fully loading the root into categories. Guard against a concurrent
                    // loadRoot that may have populated the same key already.
                    if !images.isEmpty {
                        await MainActor.run { [weak self] in
                            guard let self, !self.loadedRootURLs.contains(url) else { return }
                            self.searchIndexByRoot[url] = images
                        }
                    }
                }

                guard !Task.isCancelled else { return }
                await index.scan(images: images) { @Sendable [weak self] progress in
                    Task { @MainActor [weak self] in self?.indexProgressByRoot[url] = progress }
                }
                guard !Task.isCancelled else { return }
                await resolveSmartFilters()
            } catch {
                // Best-effort
            }
        }
    }

    // MARK: - Category rebuilding

    private func rebuildCategories() {
        let allSourceImages = sourceCategories.flatMap(\.images)
        let favoriteImages = allSourceImages
            .filter { favoriteImageIDs.contains($0.id) }
            .sorted { $0.displayLabel.localizedCaseInsensitiveCompare($1.displayLabel) == .orderedAscending }

        var syntheticCategories: [Category] = []
        let placeholder = URL(fileURLWithPath: "/")

        if !favoriteImages.isEmpty {
            syntheticCategories.append(Category(
                id: Self.favoritesID, name: "Favorites", shortName: "Saved Images",
                pathParts: ["Favorites"], rootGroupID: Self.favoritesID, rootGroupName: "Favorites",
                folderURL: placeholder, images: favoriteImages, isSynthetic: true, sourceRootURL: nil
            ))
        }

        var smartCategories: [Category] = []
        for filter in smartFilters {
            let images = smartFilterResults[filter.id] ?? []
            smartCategories.append(Category(
                id: Self.smartFilterCategoryID(for: filter.id), name: filter.name, shortName: filter.name,
                pathParts: [filter.name], rootGroupID: Self.smartFiltersGroupID, rootGroupName: "Smart Filters",
                folderURL: placeholder, images: images, isSynthetic: true, sourceRootURL: nil
            ))
        }

        categories = syntheticCategories + smartCategories + sourceCategories
    }

    private func pruneFavoritesToExistingImages() {
        let validImageIDs = Set(sourceCategories.flatMap(\.images).map(\.id))
        let filtered = favoriteImageIDs.intersection(validImageIDs)
        guard filtered != favoriteImageIDs else { return }
        favoriteImageIDs = filtered
        persistFavoriteImageIDs()
    }

    // MARK: - Persistence

    private func persistSelectedCategoryID(_ categoryID: Category.ID?) {
        selectedCategoryID = categoryID
        if let categoryID {
            userDefaults.set(categoryID, forKey: Self.selectedCategoryDefaultsKey)
        } else {
            userDefaults.removeObject(forKey: Self.selectedCategoryDefaultsKey)
        }
    }

    private func persistRootURLs() {
        userDefaults.set(rootURLs.map(\.standardizedFileURL.path), forKey: Self.rootURLsDefaultsKey)
    }

    private func persistFavoriteImageIDs() {
        var favoritesByRoot = userDefaults.dictionary(forKey: Self.favoriteImageIDsDefaultsKey) as? [String: [String]] ?? [:]
        for url in rootURLs {
            let key = Self.favoriteImageIDsStorageKey(for: url)
            let rootPath = url.standardizedFileURL.path
            let rootFavorites = favoriteImageIDs.filter { $0.hasPrefix(rootPath + "/") || $0 == rootPath }
            favoritesByRoot[key] = rootFavorites.sorted()
        }
        userDefaults.set(favoritesByRoot, forKey: Self.favoriteImageIDsDefaultsKey)
    }

    private static func loadFavoriteImageIDsStatic(for rootURL: URL, userDefaults: UserDefaults) -> Set<String> {
        let storageKey = favoriteImageIDsStorageKey(for: rootURL)
        let byRoot = userDefaults.dictionary(forKey: favoriteImageIDsDefaultsKey) as? [String: [String]] ?? [:]
        if let ids = byRoot[storageKey] { return Set(ids) }

        // Legacy migration: single-root format
        let legacyIDs = Set(userDefaults.stringArray(forKey: legacyFavoriteImageIDsDefaultsKey) ?? [])
        guard !legacyIDs.isEmpty else { return [] }
        var migrated = byRoot
        migrated[storageKey] = Array(legacyIDs).sorted()
        userDefaults.set(migrated, forKey: favoriteImageIDsDefaultsKey)
        userDefaults.removeObject(forKey: legacyFavoriteImageIDsDefaultsKey)
        return legacyIDs
    }

    private func loadFavoriteImageIDs(for rootURL: URL) -> Set<String> {
        Self.loadFavoriteImageIDsStatic(for: rootURL, userDefaults: userDefaults)
    }

    private static func persistedRootURLs(from userDefaults: UserDefaults) -> [URL] {
        // Try new array key
        if let paths = userDefaults.stringArray(forKey: rootURLsDefaultsKey), !paths.isEmpty {
            return paths.compactMap { path -> URL? in
                let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
        }
        // Migration: single legacy key
        if let path = userDefaults.string(forKey: rootURLDefaultsKey) {
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            if FileManager.default.fileExists(atPath: url.path) {
                let urls = [url]
                userDefaults.set(urls.map(\.path), forKey: rootURLsDefaultsKey)
                return urls
            }
        }
        return []
    }

    private static func favoriteImageIDsStorageKey(for rootURL: URL) -> String {
        rootURL.standardizedFileURL.path
    }

    // MARK: - Library building

    private static func discoverCategoryFolders(
        rootURL: URL,
        profile: any LibraryProfile
    ) throws -> [(folderURL: URL, images: [ImageItem])] {
        var result: [(folderURL: URL, images: [ImageItem])] = []

        let rootImages = try loadImages(in: rootURL, profile: profile)
        if !rootImages.isEmpty { result.append((rootURL, rootImages)) }

        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return result }

        for case let url as URL in enumerator {
            guard isDirectory(url) else { continue }
            let images = try loadImages(in: url, profile: profile)
            result.append((url, images))
        }

        return result.sorted {
            categorySortKey(for: $0.folderURL, relativeTo: rootURL, profile: profile)
                .localizedCaseInsensitiveCompare(
                    categorySortKey(for: $1.folderURL, relativeTo: rootURL, profile: profile)
                ) == .orderedAscending
        }
    }

    private static func buildLibrary(
        rootURL: URL,
        profile: any LibraryProfile
    ) throws -> (categories: [Category], searchIndex: [ImageItem]) {
        let folders = try discoverCategoryFolders(rootURL: rootURL, profile: profile)
        let hash = rootURLHash(rootURL)
        let loadedCategories = folders.map { folderURL, images in
            let pathParts = profile.categoryPathParts(for: folderURL, relativeTo: rootURL)
            let rawID = categoryID(for: folderURL, relativeTo: rootURL)
            return Category(
                id: "\(hash)/\(rawID)",
                name: categoryName(for: pathParts),
                shortName: subcategoryName(for: pathParts),
                pathParts: pathParts,
                rootGroupID: hash,
                rootGroupName: rootURL.lastPathComponent,
                folderURL: folderURL,
                images: images,
                isSynthetic: false,
                sourceRootURL: rootURL
            )
        }
        return (loadedCategories, makeSearchIndex(from: loadedCategories))
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func isSupportedImage(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "webp"].contains(url.pathExtension.lowercased())
    }

    private static func makeImageItem(from url: URL, profile: any LibraryProfile) -> ImageItem {
        let displayName = url.deletingPathExtension().lastPathComponent
        let createdAt = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        return ImageItem(
            id: url.path,
            fileURL: url,
            displayName: displayName,
            displayLabel: profile.displayLabel(for: displayName),
            createdAt: createdAt
        )
    }

    private static func makeSearchIndex(from categories: [Category]) -> [ImageItem] {
        categories.flatMap(\.images).sorted { lhs, rhs in
            let cmp = lhs.displayLabel.localizedCaseInsensitiveCompare(rhs.displayLabel)
            if cmp == .orderedSame {
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            return cmp == .orderedAscending
        }
    }

    // MARK: - ID helpers

    private static func humanize(_ slug: String) -> String {
        slug.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func categoryID(for folderURL: URL, relativeTo rootURL: URL) -> String {
        if folderURL.standardizedFileURL == rootURL.standardizedFileURL { return rootCategoryID }
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let folderComponents = folderURL.standardizedFileURL.pathComponents
        return folderComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private static func categoryName(for pathParts: [String]) -> String {
        pathParts.map(humanize).joined(separator: " / ")
    }

    private static func subcategoryName(for pathParts: [String]) -> String {
        guard pathParts.count > 1 else { return "Overview" }
        return pathParts.dropFirst().map(humanize).joined(separator: " / ")
    }

    private static func categorySortKey(
        for folderURL: URL,
        relativeTo rootURL: URL,
        profile: any LibraryProfile
    ) -> String {
        profile.categoryPathParts(for: folderURL, relativeTo: rootURL)
            .map { $0.lowercased() }.joined(separator: "/")
    }

    private static func validCategoryID(current: String?, categories: [Category]) -> String? {
        guard let current, categories.contains(where: { $0.id == current }) else {
            return categories.first?.id
        }
        return current
    }

    private static func validImageID(
        current: String?,
        categories: [Category],
        selectedCategoryID: String?
    ) -> String? {
        guard
            let selectedCategoryID,
            let category = categories.first(where: { $0.id == selectedCategoryID })
        else { return nil }
        guard let current, category.images.contains(where: { $0.id == current }) else {
            return category.images.first?.id
        }
        return current
    }

    private static func rootURLForSavedCategory(selectedCategoryID: String?, rootURLs: [URL]) -> URL? {
        guard let id = selectedCategoryID else { return nil }
        // New format: "[hash]/..." — extract hash prefix
        let hashPart = String(id.prefix(16))
        guard hashPart.count == 16 else { return nil }
        return rootURLs.first { rootURLHash($0) == hashPart }
    }

}
