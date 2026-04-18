import AppKit
import Foundation

final class LibraryStore: ObservableObject {
    @Published var rootURL: URL
    @Published var categories: [Category] = []
    @Published var selectedCategoryID: Category.ID?
    @Published var selectedImageID: ImageItem.ID?
    @Published var errorMessage: String?

    private let fileManager = FileManager.default

    init() {
        self.rootURL = Self.defaultRootURL()
        reload()
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
                    categories: sortedCategories
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var selectedImage: ImageItem? {
        guard let category = selectedCategory else { return nil }
        return category.images.first { $0.id == selectedImageID } ?? category.images.first
    }

    func reload() {
        do {
            let categoryFolders = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            .filter(Self.isDirectory)
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }

            let loadedCategories = try categoryFolders.map { folderURL in
                let images = try self.loadImages(in: folderURL)
                let slug = folderURL.lastPathComponent

                return Category(
                    id: slug,
                    name: Self.humanize(slug),
                    shortName: Self.subcategoryName(for: slug),
                    rootGroupID: Self.rootGroupID(for: slug),
                    rootGroupName: Self.rootGroupName(for: slug),
                    folderURL: folderURL,
                    images: images
                )
            }
            .filter { !$0.images.isEmpty }

            categories = loadedCategories
            selectedCategoryID = Self.validCategoryID(current: selectedCategoryID, categories: loadedCategories)
            selectedImageID = Self.validImageID(current: selectedImageID, categories: loadedCategories, selectedCategoryID: selectedCategoryID)
            errorMessage = nil
        } catch {
            categories = []
            selectedCategoryID = nil
            selectedImageID = nil
            errorMessage = error.localizedDescription
        }
    }

    func selectCategory(_ category: Category?) {
        selectedCategoryID = category?.id
        selectedImageID = category?.images.first?.id
    }

    func selectImage(_ image: ImageItem?) {
        selectedImageID = image?.id
    }

    func chooseRootFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose the folder that contains your category folders."

        if panel.runModal() == .OK, let url = panel.url {
            rootURL = url
            reload()
        }
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

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func isSupportedImage(_ url: URL) -> Bool {
        let supportedExtensions = ["png", "jpg", "jpeg", "webp"]
        return supportedExtensions.contains(url.pathExtension.lowercased())
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

    private static func rootGroupID(for slug: String) -> String {
        let parts = folderNameParts(for: slug)
        return parts.first ?? slug
    }

    private static func rootGroupName(for slug: String) -> String {
        return humanize(rootGroupID(for: slug))
    }

    private static func subcategoryName(for slug: String) -> String {
        let parts = folderNameParts(for: slug)
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

    private static func defaultRootURL() -> URL {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let gensURL = repoRoot.appendingPathComponent("gens", isDirectory: true)
        if FileManager.default.fileExists(atPath: gensURL.path) {
            return gensURL
        }
        return repoRoot
    }
}
