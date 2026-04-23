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

// Parses a query into search terms.
// Quoted substrings ("foo bar") are kept as single exact-phrase terms.
// Unquoted words are individual terms — all must match (implicit AND).
func parseSearchTerms(_ query: String) -> [String] {
    let foldOptions: String.CompareOptions = [.diacriticInsensitive, .caseInsensitive]
    var terms: [String] = []
    var remaining = query[...]
    while !remaining.isEmpty {
        remaining = remaining.drop(while: { $0 == " " })
        guard !remaining.isEmpty else { break }
        if remaining.first == "\"" {
            remaining = remaining.dropFirst()
            let end = remaining.firstIndex(of: "\"") ?? remaining.endIndex
            let phrase = String(remaining[..<end]).trimmingCharacters(in: .whitespaces)
            if !phrase.isEmpty {
                terms.append(phrase.folding(options: foldOptions, locale: .current))
            }
            remaining = end < remaining.endIndex ? remaining[remaining.index(after: end)...] : remaining[remaining.endIndex...]
        } else {
            let end = remaining.firstIndex(of: " ") ?? remaining.endIndex
            let word = String(remaining[..<end])
            if !word.isEmpty {
                terms.append(word.folding(options: foldOptions, locale: .current))
            }
            remaining = remaining[end...]
        }
    }
    return terms
}

private func searchImages(
    matching query: String,
    in images: [ImageItem],
    limit: Int
) -> SearchResult {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else { return .empty }

    let foldOptions: String.CompareOptions = [.diacriticInsensitive, .caseInsensitive]
    let terms = parseSearchTerms(trimmedQuery)
    guard !terms.isEmpty else { return .empty }

    // For ranking, use the full normalised query to detect exact/prefix on single-term searches.
    let normalizedQuery = trimmedQuery.folding(options: foldOptions, locale: .current)
    let safeLimit = max(limit, 1)

    var exactMatches: [ImageItem] = []
    var prefixMatches: [ImageItem] = []
    var containsMatches: [ImageItem] = []

    exactMatches.reserveCapacity(min(safeLimit, 8))
    prefixMatches.reserveCapacity(min(safeLimit, 32))
    containsMatches.reserveCapacity(min(safeLimit, 64))

    var totalMatches = 0

    for image in images {
        let normalizedLabel = image.displayLabel.folding(options: foldOptions, locale: .current)
        guard terms.allSatisfy({ normalizedLabel.contains($0) }) else { continue }

        totalMatches += 1
        let currentVisibleCount = exactMatches.count + prefixMatches.count + containsMatches.count
        guard currentVisibleCount < safeLimit else { continue }

        if normalizedLabel == normalizedQuery {
            exactMatches.append(image)
        } else if terms.count == 1 && normalizedLabel.hasPrefix(normalizedQuery) {
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
