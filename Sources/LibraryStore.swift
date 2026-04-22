import AppKit
import Foundation

final class LibraryStore: ObservableObject {
    @Published var rootURL: URL
    @Published var categories: [Category] = []
    @Published var selectedCategoryID: Category.ID?
    @Published var selectedImageID: ImageItem.ID?
    @Published var errorMessage: String?
    @Published var isLoading = false

    private let fileManager = FileManager.default
    private let appSettings: AppSettings
    private let userDefaults: UserDefaults
    private var pngInfoCache: [String: ImageMetadata?] = [:]
    private var folderMetadataCache: [String: ImageMetadata?] = [:]
    private var sourceCategories: [Category] = []
    private var searchIndex: [ImageItem] = []
    private var favoriteImageIDs: Set<String>
    private var reloadTask: Task<Void, Never>?
    private var indexScanTask: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?
    private(set) var metadataIndex: MetadataIndex?
    @Published var indexProgress: Double = 0
    @Published var activeMetadataFilters: [MetadataFilter] = []
    @Published private(set) var hasChosenRoot: Bool = false
    private var filteredImagePaths: Set<String> = []
    @Published var smartFilters: [SmartFilter] = []
    private var smartFilterResults: [UUID: [ImageItem]] = [:]
    private var smartFilterTask: Task<Void, Never>?

    private static let rootURLDefaultsKey = "selectedRootURL"
    private static let selectedCategoryDefaultsKey = "selectedCategoryID"
    private static let favoriteImageIDsDefaultsKey = "favoriteImageIDsByRoot"
    private static let legacyFavoriteImageIDsDefaultsKey = "favoriteImageIDs"
    private static let smartFiltersDefaultsKey = "smartFiltersByRoot"
    private static let rootCategoryID = "__root__"
    private static let favoritesID = "__favorites__"
    private static let filteredID = "__filtered__"
    static let smartFiltersGroupID = "__smart_filters__"

    static func smartFilterCategoryID(for filterID: UUID) -> String {
        "__smart_\(filterID.uuidString)__"
    }

    init(appSettings: AppSettings, userDefaults: UserDefaults = .standard) {
        self.appSettings = appSettings
        self.userDefaults = userDefaults
        let defaultRootURL = Self.persistedRootURL(from: userDefaults) ?? Self.profile(for: appSettings.appMode).suggestedInitialRootURL(
            fileManager: FileManager.default,
            bundleURL: Bundle.main.bundleURL,
            sourceFilePath: #filePath
        )
        let fallbackRootURL = FileManager.default.homeDirectoryForCurrentUser
        self.rootURL = defaultRootURL ?? fallbackRootURL
        self.selectedCategoryID = userDefaults.string(forKey: Self.selectedCategoryDefaultsKey)
        self.favoriteImageIDs = []
        self.favoriteImageIDs = loadFavoriteImageIDs(for: self.rootURL)

        self.hasChosenRoot = defaultRootURL != nil
        self.smartFilters = Self.loadSmartFilters(for: self.rootURL, userDefaults: userDefaults)

        if defaultRootURL != nil {
            // Synchronous on init so the window only appears once content is ready.
            if let (loaded, index) = try? Self.buildLibrary(
                rootURL: self.rootURL,
                profile: Self.profile(for: appSettings.appMode)
            ) {
                sourceCategories = loaded
                searchIndex = index
            }
            pruneFavoritesToExistingImages()
            rebuildCategories()
            selectedCategoryID = Self.validCategoryID(current: selectedCategoryID, categories: categories)
            selectedImageID = Self.validImageID(current: selectedImageID, categories: categories, selectedCategoryID: selectedCategoryID)
            startBackgroundIndexing()
        } else {
            categories = []
            sourceCategories = []
            persistSelectedCategoryID(nil)
            selectedImageID = nil
            errorMessage = nil
        }

    }

    var selectedCategory: Category? {
        categories.first { $0.id == selectedCategoryID } ?? categories.first
    }

    var categoryGroups: [CategoryGroup] {
        Dictionary(grouping: categories, by: \.rootGroupID)
            .values
            .map { groupedCategories in
                let sortedCategories = groupedCategories.sorted(by: { lhs, rhs in
                    lhs.pathParts.map { $0.lowercased() }.joined(separator: "/")
                        .localizedCaseInsensitiveCompare(rhs.pathParts.map { $0.lowercased() }.joined(separator: "/")) == .orderedAscending
                })
                let firstCategory = sortedCategories[0]
                return CategoryGroup(
                    id: firstCategory.rootGroupID,
                    name: firstCategory.rootGroupName,
                    categories: sortedCategories,
                    isSynthetic: firstCategory.isSynthetic
                )
            }
            .sorted { lhs, rhs in
                if lhs.isSynthetic != rhs.isSynthetic {
                    return lhs.isSynthetic
                }
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

    func reload() {
        reloadTask?.cancel()
        let capturedRootURL = rootURL
        let capturedProfile = Self.profile(for: appSettings.appMode)
        isLoading = true

        reloadTask = Task {
            do {
                let (loadedCategories, loadedSearchIndex) = try await Task.detached(priority: .userInitiated) {
                    try Self.buildLibrary(rootURL: capturedRootURL, profile: capturedProfile)
                }.value

                try Task.checkCancellation()

                await MainActor.run {
                    sourceCategories = loadedCategories
                    searchIndex = loadedSearchIndex
                    pngInfoCache.removeAll()
                    folderMetadataCache.removeAll()
                    pruneFavoritesToExistingImages()
                    rebuildCategories()
                    selectedCategoryID = Self.validCategoryID(current: selectedCategoryID, categories: categories)
                    persistSelectedCategoryID(selectedCategoryID)
                    selectedImageID = Self.validImageID(current: selectedImageID, categories: categories, selectedCategoryID: selectedCategoryID)
                    errorMessage = nil
                    isLoading = false
                    startBackgroundIndexing()
                }
            } catch is CancellationError {
                // superseded by a newer reload — leave isLoading for the replacement task to clear
            } catch {
                await MainActor.run {
                    categories = []
                    sourceCategories = []
                    persistSelectedCategoryID(nil)
                    selectedImageID = nil
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    func selectCategory(_ category: Category?) {
        selectedCategoryID = category?.id
        persistSelectedCategoryID(selectedCategoryID)
        selectedImageID = category?.images.first?.id
    }

    func selectImage(_ image: ImageItem?) {
        selectedImageID = image?.id
    }

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
        selectedImageID = Self.validImageID(current: selectedImageID, categories: categories, selectedCategoryID: selectedCategoryID)
    }

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
        rebuildCategories()
        selectedCategoryID = Self.validCategoryID(current: selectedCategoryID, categories: categories)
        persistSelectedCategoryID(selectedCategoryID)
    }

    func pngInfo(for image: ImageItem) -> ImageMetadata? {
        if let cached = pngInfoCache[image.id] {
            return cached
        }

        let info = PNGInfoReader.read(from: image.fileURL)
        pngInfoCache[image.id] = info
        return info
    }

    func inspectorMetadata(for image: ImageItem) -> ImageMetadata? {
        let pngInfo = pngInfo(for: image)
        let folderMetadata = folderMetadata(for: image)

        let prompt = pngInfo?.prompt ?? folderMetadata?.prompt
        let negativePrompt = pngInfo?.negativePrompt ?? folderMetadata?.negativePrompt
        let promptStatusMessage = prompt == nil
            ? (pngInfo?.promptStatusMessage ?? folderMetadata?.promptStatusMessage)
            : nil
        let generationParameters = mergeEntries(
            primary: pngInfo?.generationParameters ?? [],
            fallback: folderMetadata?.generationParameters ?? []
        )
        let textEntries = mergeEntries(
            primary: pngInfo?.textEntries ?? [],
            fallback: folderMetadata?.textEntries ?? []
        )

        let metadata = ImageMetadata(
            prompt: prompt,
            negativePrompt: negativePrompt,
            promptStatusMessage: promptStatusMessage,
            generationParameters: generationParameters,
            textEntries: textEntries
        )

        return metadata.hasVisibleContent ? metadata : nil
    }

    func temporaryInspectionImage(for fileURL: URL) -> ImageItem? {
        guard fileURL.pathExtension.lowercased() == "png", Self.isSupportedImage(fileURL) else {
            return nil
        }

        return Self.makeImageItem(from: fileURL, profile: Self.profile(for: appSettings.appMode))
    }

    func chooseRootFolder(completion: ((Bool) -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose the folder that contains your image folders or nested category folders."

        panel.begin { [weak self] result in
            guard let self else { return }
            if result == .OK, let url = panel.url {
                self.rootURL = url
                self.hasChosenRoot = true
                self.persistRootURL(url)
                self.favoriteImageIDs = self.loadFavoriteImageIDs(for: url)
                self.smartFilters = Self.loadSmartFilters(for: url, userDefaults: self.userDefaults)
                self.smartFilterResults = [:]
                self.reload()
                completion?(true)
            } else {
                completion?(false)
            }
        }
    }

    func searchTags(matching query: String, limit: Int) -> SearchResult {
        Self.profile(for: appSettings.appMode).search(matching: query, in: searchIndex, limit: limit)
    }

    func searchWithMetadata(matching query: String, limit: Int) async -> SearchResult {
        let filenameResult = searchTags(matching: query, limit: limit)

        guard let index = metadataIndex else { return filenameResult }

        // Parse into terms (respects "quoted phrases") and AND them on the metadata side.
        let terms = parseSearchTerms(query)
        guard !terms.isEmpty else { return filenameResult }

        // For each term, collect all paths that match any metadata field or prompt.
        // Then intersect across terms so only images matching ALL terms are included.
        var metadataPaths: Set<String>? = nil
        for term in terms {
            var termPaths = Set<String>()
            for field in MetadataField.allCases {
                let paths = await index.imagePaths(where: field, contains: term)
                termPaths.formUnion(paths)
            }
            let promptPaths = await index.imagePathsWherePromptContains(term)
            termPaths.formUnion(promptPaths)

            if var accumulated = metadataPaths {
                accumulated.formIntersection(termPaths)
                metadataPaths = accumulated
            } else {
                metadataPaths = termPaths
            }
        }

        let filenamePathSet = Set(filenameResult.images.map(\.id))
        let newMetadataPaths = (metadataPaths ?? []).subtracting(filenamePathSet)
        guard !newMetadataPaths.isEmpty else { return filenameResult }

        let metadataImages = searchIndex.filter { newMetadataPaths.contains($0.id) }
        let combined = filenameResult.images + metadataImages
        return SearchResult(
            images: Array(combined.prefix(limit)),
            totalMatches: filenameResult.totalMatches + metadataImages.count
        )
    }

    func setAppMode(_ mode: AppMode) {
        guard appSettings.appMode != mode else { return }
        appSettings.appMode = mode
        handleAppModeChange()
    }

    private func handleAppModeChange() {
        if let persistedRootURL = Self.persistedRootURL(from: userDefaults) {
            rootURL = persistedRootURL
            favoriteImageIDs = loadFavoriteImageIDs(for: persistedRootURL)
            reload()
            return
        }

        if let suggestedRootURL = Self.profile(for: appSettings.appMode).suggestedInitialRootURL(
            fileManager: fileManager,
            bundleURL: Bundle.main.bundleURL,
            sourceFilePath: #filePath
        ) {
            rootURL = suggestedRootURL
            favoriteImageIDs = loadFavoriteImageIDs(for: suggestedRootURL)
            reload()
            return
        }

        reloadTask?.cancel()
        indexScanTask?.cancel()
        filterTask?.cancel()
        smartFilterTask?.cancel()
        indexScanTask = nil
        filterTask = nil
        smartFilterTask = nil
        metadataIndex = nil
        indexProgress = 0
        activeMetadataFilters = []
        filteredImagePaths = []
        rootURL = fileManager.homeDirectoryForCurrentUser
        favoriteImageIDs = loadFavoriteImageIDs(for: rootURL)
        pngInfoCache.removeAll()
        folderMetadataCache.removeAll()
        searchIndex = []
        sourceCategories = []
        categories = []
        persistSelectedCategoryID(nil)
        selectedImageID = nil
        errorMessage = nil
        isLoading = false
    }

    private static func loadImages(in folderURL: URL, profile: any LibraryProfile) throws -> [ImageItem] {
        let imageURLs = try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter(isSupportedImage)
        .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }

        return imageURLs.map { makeImageItem(from: $0, profile: profile) }
    }

    private func folderMetadata(for image: ImageItem) -> ImageMetadata? {
        let folderPath = image.fileURL.deletingLastPathComponent().path
        if let cached = folderMetadataCache[folderPath] {
            return cached
        }

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
        guard !activeMetadataFilters.isEmpty, let index = metadataIndex else {
            filteredImagePaths = []
            rebuildCategories()
            selectedCategoryID = Self.validCategoryID(current: selectedCategoryID, categories: categories)
            persistSelectedCategoryID(selectedCategoryID)
            return
        }
        let filters = activeMetadataFilters
        filterTask = Task {
            let paths = await index.imagePaths(matching: filters)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.filteredImagePaths = paths
                self.rebuildCategories()
                self.selectedCategoryID = Self.validCategoryID(
                    current: Self.filteredID,
                    categories: self.categories
                )
                self.persistSelectedCategoryID(self.selectedCategoryID)
            }
        }
    }

    // MARK: - Smart Filters

    func addSmartFilter(name: String, query: String) {
        let filter = SmartFilter(name: name, query: query)
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
        var byRoot = userDefaults.dictionary(forKey: Self.smartFiltersDefaultsKey) as? [String: Data] ?? [:]
        let key = Self.favoriteImageIDsStorageKey(for: rootURL)
        byRoot[key] = try? JSONEncoder().encode(smartFilters)
        userDefaults.set(byRoot, forKey: Self.smartFiltersDefaultsKey)
    }

    private static func loadSmartFilters(for rootURL: URL, userDefaults: UserDefaults) -> [SmartFilter] {
        let key = favoriteImageIDsStorageKey(for: rootURL)
        guard
            let byRoot = userDefaults.dictionary(forKey: smartFiltersDefaultsKey) as? [String: Data],
            let data = byRoot[key],
            let filters = try? JSONDecoder().decode([SmartFilter].self, from: data)
        else { return [] }
        return filters
    }

    private func resolveSmartFilters() async {
        let filters = smartFilters
        guard !filters.isEmpty else { return }

        var newResults: [UUID: [ImageItem]] = [:]
        for filter in filters {
            let result = await searchWithMetadata(matching: filter.query, limit: 10_000)
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

    private func startBackgroundIndexing() {
        indexScanTask?.cancel()
        let images = searchIndex
        let url = rootURL
        guard !images.isEmpty else { return }
        indexProgress = 0

        indexScanTask = Task {
            do {
                let index = try MetadataIndex(rootURL: url)
                await MainActor.run { [weak self] in self?.metadataIndex = index }
                guard !Task.isCancelled else { return }
                await index.scan(images: images) { @Sendable [weak self] progress in
                    Task { @MainActor [weak self] in self?.indexProgress = progress }
                }
                guard !Task.isCancelled else { return }
                await resolveSmartFilters()
            } catch {
                // Indexing is a best-effort enhancement; the app works fine without it.
            }
        }
    }

    private func rebuildCategories() {
        let favoriteImages = sourceCategories
            .flatMap(\.images)
            .filter { favoriteImageIDs.contains($0.id) }
            .sorted { $0.displayLabel.localizedCaseInsensitiveCompare($1.displayLabel) == .orderedAscending }

        var syntheticCategories: [Category] = []

        if !filteredImagePaths.isEmpty {
            let filteredImages = sourceCategories
                .flatMap(\.images)
                .filter { filteredImagePaths.contains($0.id) }
                .sorted { $0.displayLabel.localizedCaseInsensitiveCompare($1.displayLabel) == .orderedAscending }

            if !filteredImages.isEmpty {
                syntheticCategories.append(Category(
                    id: Self.filteredID,
                    name: "Filtered",
                    shortName: "Filtered",
                    pathParts: ["Filtered"],
                    rootGroupID: Self.filteredID,
                    rootGroupName: "Filtered",
                    folderURL: rootURL,
                    images: filteredImages,
                    isSynthetic: true
                ))
            }
        }

        if !favoriteImages.isEmpty {
            syntheticCategories.append(Category(
                id: Self.favoritesID,
                name: "Favorites",
                shortName: "Saved Images",
                pathParts: ["Favorites"],
                rootGroupID: Self.favoritesID,
                rootGroupName: "Favorites",
                folderURL: rootURL,
                images: favoriteImages,
                isSynthetic: true
            ))
        }

        // Smart filter synthetic categories (one per filter that has resolved results)
        var smartCategories: [Category] = []
        for filter in smartFilters {
            let images = smartFilterResults[filter.id] ?? []
            smartCategories.append(Category(
                id: Self.smartFilterCategoryID(for: filter.id),
                name: filter.name,
                shortName: filter.name,
                pathParts: [filter.name],
                rootGroupID: Self.smartFiltersGroupID,
                rootGroupName: "Smart Filters",
                folderURL: rootURL,
                images: images,
                isSynthetic: true
            ))
        }

        categories = syntheticCategories + smartCategories + sourceCategories
    }

    private func pruneFavoritesToExistingImages() {
        let validImageIDs = Set(sourceCategories.flatMap(\.images).map(\.id))
        let filteredFavoriteImageIDs = favoriteImageIDs.intersection(validImageIDs)

        guard filteredFavoriteImageIDs != favoriteImageIDs else { return }
        favoriteImageIDs = filteredFavoriteImageIDs
        persistFavoriteImageIDs()
    }

    private func persistSelectedCategoryID(_ categoryID: Category.ID?) {
        selectedCategoryID = categoryID

        if let categoryID {
            userDefaults.set(categoryID, forKey: Self.selectedCategoryDefaultsKey)
        } else {
            userDefaults.removeObject(forKey: Self.selectedCategoryDefaultsKey)
        }
    }

    private func persistRootURL(_ rootURL: URL) {
        userDefaults.set(rootURL.standardizedFileURL.path, forKey: Self.rootURLDefaultsKey)
    }

    private func persistFavoriteImageIDs() {
        var favoritesByRoot = userDefaults.dictionary(forKey: Self.favoriteImageIDsDefaultsKey) as? [String: [String]] ?? [:]
        favoritesByRoot[Self.favoriteImageIDsStorageKey(for: rootURL)] = Array(favoriteImageIDs).sorted()
        userDefaults.set(favoritesByRoot, forKey: Self.favoriteImageIDsDefaultsKey)
    }

    private func loadFavoriteImageIDs(for rootURL: URL) -> Set<String> {
        let storageKey = Self.favoriteImageIDsStorageKey(for: rootURL)
        let favoritesByRoot = userDefaults.dictionary(forKey: Self.favoriteImageIDsDefaultsKey) as? [String: [String]] ?? [:]

        if let favoriteImageIDs = favoritesByRoot[storageKey] {
            return Set(favoriteImageIDs)
        }

        let legacyFavoriteImageIDs = Set(userDefaults.stringArray(forKey: Self.legacyFavoriteImageIDsDefaultsKey) ?? [])
        guard !legacyFavoriteImageIDs.isEmpty else {
            return []
        }

        var migratedFavoritesByRoot = favoritesByRoot
        migratedFavoritesByRoot[storageKey] = Array(legacyFavoriteImageIDs).sorted()
        userDefaults.set(migratedFavoritesByRoot, forKey: Self.favoriteImageIDsDefaultsKey)
        userDefaults.removeObject(forKey: Self.legacyFavoriteImageIDsDefaultsKey)
        return legacyFavoriteImageIDs
    }

    private static func discoverCategoryFolders(
        rootURL: URL,
        profile: any LibraryProfile
    ) throws -> [(folderURL: URL, images: [ImageItem])] {
        var result: [(folderURL: URL, images: [ImageItem])] = []

        let rootImages = try loadImages(in: rootURL, profile: profile)
        if !rootImages.isEmpty {
            result.append((rootURL, rootImages))
        }

        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return result
        }

        for case let url as URL in enumerator {
            guard isDirectory(url) else { continue }
            let images = try loadImages(in: url, profile: profile)
            if !images.isEmpty {
                result.append((url, images))
            }
        }

        return result.sorted {
            categorySortKey(for: $0.folderURL, relativeTo: rootURL, profile: profile)
                .localizedCaseInsensitiveCompare(categorySortKey(for: $1.folderURL, relativeTo: rootURL, profile: profile)) == .orderedAscending
        }
    }

    private static func buildLibrary(
        rootURL: URL,
        profile: any LibraryProfile
    ) throws -> (categories: [Category], searchIndex: [ImageItem]) {
        let folders = try discoverCategoryFolders(rootURL: rootURL, profile: profile)
        let loadedCategories = folders.map { folderURL, images in
            let pathParts = profile.categoryPathParts(for: folderURL, relativeTo: rootURL)
            return Category(
                id: categoryID(for: folderURL, relativeTo: rootURL),
                name: categoryName(for: pathParts),
                shortName: subcategoryName(for: pathParts),
                pathParts: pathParts,
                rootGroupID: rootGroupID(for: pathParts),
                rootGroupName: rootGroupName(for: pathParts),
                folderURL: folderURL,
                images: images,
                isSynthetic: false
            )
        }
        return (loadedCategories, makeSearchIndex(from: loadedCategories))
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func isSupportedImage(_ url: URL) -> Bool {
        let supportedExtensions = ["png", "jpg", "jpeg", "webp"]
        return supportedExtensions.contains(url.pathExtension.lowercased())
    }

    private static func makeImageItem(from url: URL, profile: any LibraryProfile) -> ImageItem {
        let displayName = url.deletingPathExtension().lastPathComponent
        let displayLabel = profile.displayLabel(for: displayName)

        return ImageItem(
            id: url.path,
            fileURL: url,
            displayName: displayName,
            displayLabel: displayLabel
        )
    }

    private static func makeSearchIndex(from categories: [Category]) -> [ImageItem] {
        categories
            .flatMap(\.images)
            .sorted { lhs, rhs in
                let comparison = lhs.displayLabel.localizedCaseInsensitiveCompare(rhs.displayLabel)
                if comparison == .orderedSame {
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }
                return comparison == .orderedAscending
            }
    }

    private static func persistedRootURL(from userDefaults: UserDefaults) -> URL? {
        guard let path = userDefaults.string(forKey: Self.rootURLDefaultsKey) else {
            return nil
        }

        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            userDefaults.removeObject(forKey: Self.rootURLDefaultsKey)
            return nil
        }

        return url
    }

    private static func favoriteImageIDsStorageKey(for rootURL: URL) -> String {
        rootURL.standardizedFileURL.path
    }

    private static func humanize(_ slug: String) -> String {
        slug
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func categoryID(for folderURL: URL, relativeTo rootURL: URL) -> String {
        if folderURL.standardizedFileURL == rootURL.standardizedFileURL {
            return rootCategoryID
        }

        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let folderComponents = folderURL.standardizedFileURL.pathComponents
        let relativeComponents = folderComponents.dropFirst(rootComponents.count)
        return relativeComponents.joined(separator: "/")
    }

    private static func categoryName(for pathParts: [String]) -> String {
        pathParts
            .map(humanize)
            .joined(separator: " / ")
    }

    private static func rootGroupID(for pathParts: [String]) -> String {
        pathParts.first ?? ""
    }

    private static func rootGroupName(for pathParts: [String]) -> String {
        humanize(rootGroupID(for: pathParts))
    }

    private static func subcategoryName(for pathParts: [String]) -> String {
        let parts = pathParts
        if parts.count <= 1 {
            return "Overview"
        }

        return parts.dropFirst()
            .map(humanize)
            .joined(separator: " / ")
    }

    private static func categorySortKey(
        for folderURL: URL,
        relativeTo rootURL: URL,
        profile: any LibraryProfile
    ) -> String {
        profile.categoryPathParts(for: folderURL, relativeTo: rootURL)
            .map { $0.lowercased() }
            .joined(separator: "/")
    }

    private static func validCategoryID(current: String?, categories: [Category]) -> String? {
        guard let current, categories.contains(where: { $0.id == current }) else {
            return categories.first?.id
        }
        return current
    }

    private static func validImageID(current: String?, categories: [Category], selectedCategoryID: String?) -> String? {
        guard
            let selectedCategoryID,
            let category = categories.first(where: { $0.id == selectedCategoryID })
        else {
            return nil
        }

        guard let current, category.images.contains(where: { $0.id == current }) else {
            return category.images.first?.id
        }
        return current
    }

    private static func profile(for mode: AppMode) -> any LibraryProfile {
        switch mode {
        case .general:
            return GeneralLibraryProfile()
        case .tagExplorerLegacy:
            return TagExplorerLegacyProfile()
        }
    }

}
