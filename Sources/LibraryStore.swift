import AppKit
import Foundation

final class LibraryStore: ObservableObject {
    @Published var rootURL: URL
    @Published var categories: [Category] = []
    @Published var selectedCategoryID: Category.ID?
    @Published var selectedImageID: ImageItem.ID?
    @Published var errorMessage: String?

    private let fileManager = FileManager.default
    private let userDefaults: UserDefaults
    private var pngInfoCache: [String: PNGInfo?] = [:]
    private var folderMetadataCache: [String: FolderMetadata?] = [:]
    private var sourceCategories: [Category] = []
    private var searchIndex: [ImageItem] = []
    private var favoriteImageIDs: Set<String>
    private static let selectedCategoryDefaultsKey = "selectedCategoryID"
    private static let favoriteImageIDsDefaultsKey = "favoriteImageIDs"
    private static let favoritesCategoryID = "__favorites__"
    private static let favoritesGroupID = "__favorites__"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let defaultRootURL = Self.defaultRootURL()
        let fallbackRootURL = FileManager.default.homeDirectoryForCurrentUser
        self.rootURL = defaultRootURL ?? fallbackRootURL
        self.selectedCategoryID = userDefaults.string(forKey: Self.selectedCategoryDefaultsKey)
        self.favoriteImageIDs = Set(userDefaults.stringArray(forKey: Self.favoriteImageIDsDefaultsKey) ?? [])

        if defaultRootURL != nil {
            reload()
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
                let sortedCategories = groupedCategories.sorted {
                    $0.shortName.localizedCaseInsensitiveCompare($1.shortName) == .orderedAscending
                }
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
        do {
            let categoryFolders = try discoverCategoryFolders()

            let loadedCategories = try categoryFolders.map { folderURL in
                let images = try self.loadImages(in: folderURL)
                let categoryID = Self.categoryID(for: folderURL, relativeTo: rootURL)
                let pathParts = Self.categoryPathParts(for: folderURL, relativeTo: rootURL)

                return Category(
                    id: categoryID,
                    name: Self.categoryName(for: pathParts),
                    shortName: Self.subcategoryName(for: pathParts),
                    rootGroupID: Self.rootGroupID(for: pathParts),
                    rootGroupName: Self.rootGroupName(for: pathParts),
                    folderURL: folderURL,
                    images: images,
                    isSynthetic: false
                )
            }
            .filter { !$0.images.isEmpty }

            sourceCategories = loadedCategories
            searchIndex = Self.makeSearchIndex(from: loadedCategories)
            pngInfoCache.removeAll()
            folderMetadataCache.removeAll()
            pruneFavoritesToExistingImages()
            rebuildCategories()
            selectedCategoryID = Self.validCategoryID(current: selectedCategoryID, categories: categories)
            persistSelectedCategoryID(selectedCategoryID)
            selectedImageID = Self.validImageID(current: selectedImageID, categories: categories, selectedCategoryID: selectedCategoryID)
            errorMessage = nil
        } catch {
            categories = []
            sourceCategories = []
            persistSelectedCategoryID(nil)
            selectedImageID = nil
            errorMessage = error.localizedDescription
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

    func pngInfo(for image: ImageItem) -> PNGInfo? {
        if let cached = pngInfoCache[image.id] {
            return cached
        }

        let info = PNGInfoReader.read(from: image.fileURL)
        pngInfoCache[image.id] = info
        return info
    }

    func inspectorMetadata(for image: ImageItem) -> InspectorMetadata? {
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

        let metadata = InspectorMetadata(
            prompt: prompt,
            negativePrompt: negativePrompt,
            generationParameters: generationParameters,
            textEntries: textEntries
        )

        return metadata.hasVisibleContent ? metadata : nil
    }

    func chooseRootFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose the folder that contains your image folders or nested category folders."

        if panel.runModal() == .OK, let url = panel.url {
            rootURL = url
            reload()
        }
    }

    func searchTags(matching query: String, limit: Int) -> TagSearchResult {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return .empty
        }

        let normalizedQuery = trimmedQuery.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let safeLimit = max(limit, 1)

        var matches: [ImageItem] = []
        matches.reserveCapacity(min(safeLimit, 64))

        var totalMatches = 0

        for image in searchIndex {
            let normalizedTag = image.inferredTag.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            guard normalizedTag.contains(normalizedQuery) else {
                continue
            }

            totalMatches += 1
            if matches.count < safeLimit {
                matches.append(image)
            }
        }

        return TagSearchResult(images: matches, totalMatches: totalMatches)
    }

    private func loadImages(in folderURL: URL) throws -> [ImageItem] {
        let imageURLs = try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter(Self.isSupportedImage)
        .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }

        return imageURLs.map { url in
            let displayName = url.deletingPathExtension().lastPathComponent
            let inferredTag = Self.inferTag(from: displayName)
            return ImageItem(
                id: url.path,
                fileURL: url,
                displayName: displayName,
                inferredTag: inferredTag
            )
        }
    }

    private func folderMetadata(for image: ImageItem) -> FolderMetadata? {
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

    private func rebuildCategories() {
        let favoriteImages = sourceCategories
            .flatMap(\.images)
            .filter { favoriteImageIDs.contains($0.id) }
            .sorted { $0.inferredTag.localizedCaseInsensitiveCompare($1.inferredTag) == .orderedAscending }

        if favoriteImages.isEmpty {
            categories = sourceCategories
            return
        }

        let favoritesCategory = Category(
            id: Self.favoritesCategoryID,
            name: "Favorites",
            shortName: "Saved Images",
            rootGroupID: Self.favoritesGroupID,
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

    private func persistFavoriteImageIDs() {
        userDefaults.set(Array(favoriteImageIDs).sorted(), forKey: Self.favoriteImageIDsDefaultsKey)
    }

    private func discoverCategoryFolders() throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var categoryFolders: [URL] = []

        for case let url as URL in enumerator {
            guard Self.isDirectory(url) else { continue }

            let images = try loadImages(in: url)
            if !images.isEmpty {
                categoryFolders.append(url)
            }
        }

        return categoryFolders.sorted {
            Self.categorySortKey(for: $0, relativeTo: rootURL)
                .localizedCaseInsensitiveCompare(Self.categorySortKey(for: $1, relativeTo: rootURL)) == .orderedAscending
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func isSupportedImage(_ url: URL) -> Bool {
        let supportedExtensions = ["png", "jpg", "jpeg", "webp"]
        return supportedExtensions.contains(url.pathExtension.lowercased())
    }

    private static func makeSearchIndex(from categories: [Category]) -> [ImageItem] {
        categories
            .flatMap(\.images)
            .sorted { lhs, rhs in
                let comparison = lhs.inferredTag.localizedCaseInsensitiveCompare(rhs.inferredTag)
                if comparison == .orderedSame {
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }
                return comparison == .orderedAscending
            }
    }

    private static func inferTag(from displayName: String) -> String {
        let cleaned = displayName.replacingOccurrences(of: "_00001_", with: "")
        return cleaned.replacingOccurrences(of: "_", with: " ")
    }

    private static func humanize(_ slug: String) -> String {
        slug
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func categoryID(for folderURL: URL, relativeTo rootURL: URL) -> String {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let folderComponents = folderURL.standardizedFileURL.pathComponents
        let relativeComponents = folderComponents.dropFirst(rootComponents.count)
        return relativeComponents.joined(separator: "/")
    }

    private static func categoryPathParts(for folderURL: URL, relativeTo rootURL: URL) -> [String] {
        let relativePath = categoryID(for: folderURL, relativeTo: rootURL)
        let components = relativePath
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }

        if components.count <= 1, let first = components.first {
            return folderNameParts(for: first)
        }

        return components
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

    private static func folderNameParts(for slug: String) -> [String] {
        let normalized = slug.replacingOccurrences(of: "_-_", with: " - ")
        let separator = " - "

        if normalized.contains(separator) {
            return normalized
                .components(separatedBy: separator)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        return [slug]
    }

    private static func categorySortKey(for folderURL: URL, relativeTo rootURL: URL) -> String {
        categoryPathParts(for: folderURL, relativeTo: rootURL)
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

    private static func defaultRootURL() -> URL? {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let gensURL = repoRoot.appendingPathComponent("gens", isDirectory: true)
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: gensURL.path) {
            return gensURL
        }

        let bundleURL = Bundle.main.bundleURL
        let bundleCandidates = [
            bundleURL.deletingLastPathComponent().appendingPathComponent("gens", isDirectory: true),
            bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("gens", isDirectory: true)
        ]

        for candidate in bundleCandidates where fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }

        return nil
    }
}
