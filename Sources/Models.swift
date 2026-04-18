import Foundation

struct Category: Identifiable, Hashable {
    let id: String
    let name: String
    let shortName: String
    let rootGroupID: String
    let rootGroupName: String
    let folderURL: URL
    let images: [ImageItem]
}

struct ImageItem: Identifiable, Hashable {
    let id: String
    let fileURL: URL
    let displayName: String
    let inferredTag: String
}

struct CategoryGroup: Identifiable, Hashable {
    let id: String
    let name: String
    let categories: [Category]

    var imageCount: Int {
        categories.reduce(0) { $0 + $1.images.count }
    }
}
