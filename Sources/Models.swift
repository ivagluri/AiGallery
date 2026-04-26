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
    let sourceRootURL: URL?
}

struct ImageItem: Identifiable, Hashable {
    let id: String
    let fileURL: URL
    let displayName: String
    let displayLabel: String
    let createdAt: Date?
}

struct ImageMetadata: Hashable {
    let prompt: String?
    let negativePrompt: String?
    let promptStatusMessage: String?
    let generationParameters: [PNGTextEntry]
    let textEntries: [PNGTextEntry]

    var hasVisibleContent: Bool {
        prompt?.isEmpty == false
            || negativePrompt?.isEmpty == false
            || promptStatusMessage?.isEmpty == false
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
    let sourceRootURL: URL?

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
    var scopeFolderPath: String?  // nil = global; stored as path string for Codable

    var scopeFolderURL: URL? {
        get { scopeFolderPath.map { URL(fileURLWithPath: $0) } }
        set { scopeFolderPath = newValue?.path }
    }

    init(id: UUID = UUID(), name: String, query: String, scopeFolderURL: URL? = nil) {
        self.id = id
        self.name = name
        self.query = query
        self.scopeFolderPath = scopeFolderURL?.path
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

// MARK: - Kin

struct KinMatch: Identifiable {
    var id: String { image.id }
    let image: ImageItem
    let relationship: KinRelationship
    let score: Int
    let reasons: [KinReason]
}

enum KinRelationship {
    case sibling
    case variant
    case upscale
    case related

    var displayName: String {
        switch self {
        case .sibling: return "Same Batch"
        case .variant: return "Variants"
        case .upscale: return "Possible Upscales"
        case .related: return "Related"
        }
    }
}

enum KinReason: String {
    case samePrompt        = "same prompt"
    case similarPrompt     = "similar prompt"
    case sameSeed          = "same seed"
    case sameModel         = "same model"
    case sameFolder        = "same folder"
    case filenamePattern   = "nearby filename"
    case closeTimestamp    = "close timestamp"
    case upscaleDimensions = "larger dimensions"
}

// MARK: - Prompt Diff

enum DiffToken {
    case unchanged(String)
    case added(String)
    case removed(String)
}

struct MetadataDiff {
    let promptTokens: [DiffToken]
    let negativeTokens: [DiffToken]
    let parameterDiffs: [(key: String, aValue: String?, bValue: String?)]

    var hasAnyContent: Bool {
        !promptTokens.isEmpty || !negativeTokens.isEmpty || !parameterDiffs.isEmpty
    }
}
