import Foundation

struct Category: Identifiable, Hashable {
    let id: String
    let name: String
    let shortName: String
    let pathParts: [String]
    let rootGroupID: String
    let rootGroupName: String
    let folderURL: URL
    let images: [ImageItem]
    let isSynthetic: Bool
}

struct ImageItem: Identifiable, Hashable {
    let id: String
    let fileURL: URL
    let displayName: String
    let inferredTag: String
}

struct PNGInfo: Hashable {
    let prompt: String?
    let negativePrompt: String?
    let generationParameters: [PNGTextEntry]
    let textEntries: [PNGTextEntry]

    var hasVisibleContent: Bool {
        prompt?.isEmpty == false
            || negativePrompt?.isEmpty == false
            || !generationParameters.isEmpty
            || !textEntries.isEmpty
    }
}

struct FolderMetadata: Hashable {
    let prompt: String?
    let negativePrompt: String?
    let generationParameters: [PNGTextEntry]
    let textEntries: [PNGTextEntry]

    var hasVisibleContent: Bool {
        prompt?.isEmpty == false
            || negativePrompt?.isEmpty == false
            || !generationParameters.isEmpty
            || !textEntries.isEmpty
    }
}

struct InspectorMetadata: Hashable {
    let prompt: String?
    let negativePrompt: String?
    let generationParameters: [PNGTextEntry]
    let textEntries: [PNGTextEntry]

    var hasVisibleContent: Bool {
        prompt?.isEmpty == false
            || negativePrompt?.isEmpty == false
            || !generationParameters.isEmpty
            || !textEntries.isEmpty
    }
}

struct PNGTextEntry: Hashable, Identifiable {
    let keyword: String
    let value: String

    var id: String {
        "\(keyword)\u{1F} \(value)"
    }
}

struct CategoryGroup: Identifiable, Hashable {
    let id: String
    let name: String
    let categories: [Category]
    let isSynthetic: Bool

    var imageCount: Int {
        categories.reduce(0) { $0 + $1.images.count }
    }
}

struct TagSearchResult: Hashable {
    let images: [ImageItem]
    let totalMatches: Int

    static let empty = TagSearchResult(images: [], totalMatches: 0)
}
