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
    private(set) var metadataIndex: MetadataIndex?
    @Published var indexProgress: Double = 0
    private static let rootURLDefaultsKey = "selectedRootURL"
    private static let selectedCategoryDefaultsKey = "selectedCategoryID"
    private static let favoriteImageIDsDefaultsKey = "favoriteImageIDsByRoot"
    private static let legacyFavoriteImageIDsDefaultsKey = "favoriteImageIDs"
    private static let rootCategoryID = "__root__"
    private static let favoritesID = "__favorites__"

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

    @discardableResult
    func chooseRootFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose the folder that contains your image folders or nested category folders."

        if panel.runModal() == .OK, let url = panel.url {
            rootURL = url
            persistRootURL(url)
            favoriteImageIDs = loadFavoriteImageIDs(for: url)
            reload()
            return true
        }

        return false
    }

    func searchTags(matching query: String, limit: Int) -> SearchResult {
        Self.profile(for: appSettings.appMode).search(matching: query, in: searchIndex, limit: limit)
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
        indexScanTask = nil
        metadataIndex = nil
        indexProgress = 0
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

        if favoriteImages.isEmpty {
            categories = sourceCategories
            return
        }

        let favoritesCategory = Category(
            id: Self.favoritesID,
            name: "Favorites",
            shortName: "Saved Images",
            pathParts: ["Favorites"],
            rootGroupID: Self.favoritesID,
            rootGroupName: "Favorites",
            folderURL: rootURL,
            images: favoriteImages,
            isSynthetic: true
        )

        categories = [favoritesCategory] + sourceCategories
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
