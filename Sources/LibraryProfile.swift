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

struct ParsedSearchQuery {
    let requiredTerms: [String]
    let excludedTerms: [String]

    var isEmpty: Bool {
        requiredTerms.isEmpty && excludedTerms.isEmpty
    }
}

// Parses a query into search terms. Quoted substrings are kept as exact phrases.
// Terms prefixed with "-" are exclusions, e.g. `portrait -kitchen`.
func parseSearchQuery(_ query: String) -> ParsedSearchQuery {
    let foldOptions: String.CompareOptions = [.diacriticInsensitive, .caseInsensitive]
    var requiredTerms: [String] = []
    var excludedTerms: [String] = []
    var remaining = query[...]

    while !remaining.isEmpty {
        remaining = remaining.drop(while: { $0.isWhitespace })
        guard !remaining.isEmpty else { break }

        let isExcluded = remaining.first == "-"
        if isExcluded {
            remaining = remaining.dropFirst()
        }

        guard !remaining.isEmpty else { break }

        let term: String
        if remaining.first == "\"" {
            remaining = remaining.dropFirst()
            let end = remaining.firstIndex(of: "\"") ?? remaining.endIndex
            term = String(remaining[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            remaining = end < remaining.endIndex ? remaining[remaining.index(after: end)...] : remaining[remaining.endIndex...]
        } else {
            let end = remaining.firstIndex(where: { $0.isWhitespace }) ?? remaining.endIndex
            term = String(remaining[..<end])
            remaining = remaining[end...]
        }

        let normalizedTerm = term
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: foldOptions, locale: .current)
        guard !normalizedTerm.isEmpty else { continue }

        if isExcluded {
            excludedTerms.append(normalizedTerm)
        } else {
            requiredTerms.append(normalizedTerm)
        }
    }

    return ParsedSearchQuery(requiredTerms: requiredTerms, excludedTerms: excludedTerms)
}

private func searchImages(
    matching query: String,
    in images: [ImageItem],
    limit: Int
) -> SearchResult {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else { return .empty }

    let foldOptions: String.CompareOptions = [.diacriticInsensitive, .caseInsensitive]
    let parsedQuery = parseSearchQuery(trimmedQuery)
    guard !parsedQuery.isEmpty else { return .empty }

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
        guard parsedQuery.requiredTerms.allSatisfy({ normalizedLabel.contains($0) }) else { continue }
        guard !parsedQuery.excludedTerms.contains(where: { normalizedLabel.contains($0) }) else { continue }

        totalMatches += 1
        let currentVisibleCount = exactMatches.count + prefixMatches.count + containsMatches.count
        guard currentVisibleCount < safeLimit else { continue }

        if normalizedLabel == normalizedQuery {
            exactMatches.append(image)
        } else if parsedQuery.requiredTerms.count == 1 && parsedQuery.excludedTerms.isEmpty && normalizedLabel.hasPrefix(normalizedQuery) {
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
