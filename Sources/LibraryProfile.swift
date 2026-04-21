import Foundation

protocol LibraryProfile {
    func suggestedInitialRootURL(
        fileManager: FileManager,
        bundleURL: URL,
        sourceFilePath: String
    ) -> URL?
    func categoryPathParts(for folderURL: URL, relativeTo rootURL: URL) -> [String]
    func displayLabel(for displayName: String) -> String
    func search(matching query: String, in images: [ImageItem], limit: Int) -> SearchResult
}

struct GeneralLibraryProfile: LibraryProfile {
    func suggestedInitialRootURL(
        fileManager: FileManager,
        bundleURL: URL,
        sourceFilePath: String
    ) -> URL? {
        nil
    }

    func categoryPathParts(for folderURL: URL, relativeTo rootURL: URL) -> [String] {
        if folderURL.standardizedFileURL == rootURL.standardizedFileURL {
            let rootName = rootURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            return [rootName.isEmpty ? "Library" : rootName]
        }

        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let folderComponents = folderURL.standardizedFileURL.pathComponents
        let relativeComponents = folderComponents.dropFirst(rootComponents.count)
        return relativeComponents.map { String($0) }.filter { !$0.isEmpty }
    }

    func displayLabel(for displayName: String) -> String {
        displayName.replacingOccurrences(of: "_", with: " ")
    }

    func search(matching query: String, in images: [ImageItem], limit: Int) -> SearchResult {
        searchImages(matching: query, in: images, limit: limit)
    }
}

struct TagExplorerLegacyProfile: LibraryProfile {
    func suggestedInitialRootURL(
        fileManager: FileManager,
        bundleURL: URL,
        sourceFilePath: String
    ) -> URL? {
        let repoRoot = URL(fileURLWithPath: sourceFilePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let gensURL = repoRoot.appendingPathComponent("gens", isDirectory: true)

        if fileManager.fileExists(atPath: gensURL.path) {
            return gensURL
        }

        let bundleCandidates = [
            bundleURL.deletingLastPathComponent().appendingPathComponent("gens", isDirectory: true),
            bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("gens", isDirectory: true)
        ]

        for candidate in bundleCandidates where fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }

        return nil
    }

    func categoryPathParts(for folderURL: URL, relativeTo rootURL: URL) -> [String] {
        if folderURL.standardizedFileURL == rootURL.standardizedFileURL {
            let rootName = rootURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            return [rootName.isEmpty ? "Library" : rootName]
        }

        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let folderComponents = folderURL.standardizedFileURL.pathComponents
        let relativeComponents = folderComponents.dropFirst(rootComponents.count)
        let components = relativeComponents.map { String($0) }.filter { !$0.isEmpty }

        if components.count <= 1, let first = components.first {
            return folderNameParts(for: first)
        }

        return components
    }

    func displayLabel(for displayName: String) -> String {
        let cleaned = displayName.replacingOccurrences(of: "_00001_", with: "")
        return cleaned.replacingOccurrences(of: "_", with: " ")
    }

    func search(matching query: String, in images: [ImageItem], limit: Int) -> SearchResult {
        searchImages(matching: query, in: images, limit: limit)
    }

    private func folderNameParts(for slug: String) -> [String] {
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
}

private func searchImages(
    matching query: String,
    in images: [ImageItem],
    limit: Int
) -> SearchResult {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else {
        return .empty
    }

    let normalizedQuery = trimmedQuery.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    let safeLimit = max(limit, 1)

    var exactMatches: [ImageItem] = []
    var prefixMatches: [ImageItem] = []
    var containsMatches: [ImageItem] = []

    exactMatches.reserveCapacity(min(safeLimit, 8))
    prefixMatches.reserveCapacity(min(safeLimit, 32))
    containsMatches.reserveCapacity(min(safeLimit, 64))

    var totalMatches = 0

    for image in images {
        let normalizedLabel = image.displayLabel.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        guard normalizedLabel.contains(normalizedQuery) else {
            continue
        }

        totalMatches += 1
        let currentVisibleCount = exactMatches.count + prefixMatches.count + containsMatches.count
        guard currentVisibleCount < safeLimit else {
            continue
        }

        if normalizedLabel == normalizedQuery {
            exactMatches.append(image)
        } else if normalizedLabel.hasPrefix(normalizedQuery) {
            prefixMatches.append(image)
        } else {
            containsMatches.append(image)
        }
    }

    return SearchResult(
        images: exactMatches + prefixMatches + containsMatches,
        totalMatches: totalMatches
    )
}
