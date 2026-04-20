import AppKit
import ImageIO

enum SafeImageLoader {
    enum LoadResult {
        case success(NSImage)
        case blocked(BlockReason)
        case failed
    }

    enum BlockReason: String {
        case fileTooLarge
        case imageTooLarge

        var title: String {
            switch self {
            case .fileTooLarge:
                return "Preview Blocked"
            case .imageTooLarge:
                return "Preview Blocked"
            }
        }

        var message: String {
            switch self {
            case .fileTooLarge:
                return "File exceeds safe preview size."
            case .imageTooLarge:
                return "Image exceeds safe preview dimensions."
            }
        }

        var compactTitle: String {
            switch self {
            case .fileTooLarge:
                return "File Too Large"
            case .imageTooLarge:
                return "Too Large"
            }
        }
    }

    static let maximumFileSize = 256 * 1_024 * 1_024
    static let maximumPixelCount = 70_000_000
    private static let metadataDimensionSanityLimit = 1_000_000

    private static let cache = NSCache<NSString, NSImage>()

    static func loadImage(for fileURL: URL, maximumThumbnailDimension: Int) -> LoadResult {
        let clampedDimension = max(1, maximumThumbnailDimension)
        let cacheKey = "\(fileURL.path)#\(clampedDimension)" as NSString

        if let cachedImage = cache.object(forKey: cacheKey) {
            return .success(cachedImage)
        }

        guard
            let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
            fileSize > 0
        else {
            return .failed
        }

        guard fileSize <= maximumFileSize else {
            return .blocked(.fileTooLarge)
        }

        guard
            let source = CGImageSourceCreateWithURL(fileURL as CFURL, [
                kCGImageSourceShouldCache: false
            ] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [
                kCGImageSourceShouldCache: false
            ] as CFDictionary) as? [CFString: Any],
            let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
            let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int,
            pixelWidth > 0,
            pixelHeight > 0,
            pixelWidth <= metadataDimensionSanityLimit,
            pixelHeight <= metadataDimensionSanityLimit,
            pixelWidth <= maximumPixelCount / pixelHeight
        else {
            if let source = CGImageSourceCreateWithURL(fileURL as CFURL, [
                kCGImageSourceShouldCache: false
            ] as CFDictionary),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [
                kCGImageSourceShouldCache: false
               ] as CFDictionary) as? [CFString: Any],
               let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
               let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int,
               pixelWidth > 0,
               pixelHeight > 0
            {
                return .blocked(.imageTooLarge)
            }

            return .failed
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: clampedDimension
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return .failed
        }

        let image = NSImage(cgImage: thumbnail, size: .zero)
        cache.setObject(image, forKey: cacheKey)
        return .success(image)
    }
}
