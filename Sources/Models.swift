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
    let displayLabel: String
}

struct ImageMetadata: Hashable {
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

struct SearchResult: Hashable {
    let images: [ImageItem]
    let totalMatches: Int

    static let empty = SearchResult(images: [], totalMatches: 0)
}

enum MetadataField: String, CaseIterable {
    case model, sampler, scheduler, vae, upscaler

    var displayName: String {
        switch self {
        case .model:     return "Model"
        case .sampler:   return "Sampler"
        case .scheduler: return "Scheduler"
        case .vae:       return "VAE"
        case .upscaler:  return "Upscaler"
        }
    }

    var columnName: String { rawValue }
}

struct SmartFilter: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var query: String

    init(id: UUID = UUID(), name: String, query: String) {
        self.id = id
        self.name = name
        self.query = query
    }
}

struct MetadataFilter: Identifiable, Hashable {
    let id: UUID
    let field: MetadataField
    let value: String

    init(field: MetadataField, value: String) {
        self.id = UUID()
        self.field = field
        self.value = value
    }
}
