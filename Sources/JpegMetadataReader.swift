import Foundation
import ImageIO

enum JpegMetadataReader {
    static func read(from fileURL: URL) -> ImageMetadata? {
        let ext = fileURL.pathExtension.lowercased()
        guard ext == "jpg" || ext == "jpeg" else { return nil }

        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard
            let source = CGImageSourceCreateWithURL(fileURL as CFURL, options),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any]
        else { return nil }

        // EXIF UserComment — A1111 stores full infotext here
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let raw = exif[kCGImagePropertyExifUserComment] as? String {
            let text = stripExifCharsetPrefix(raw)
            if let meta = PNGInfoReader.readInfotext(text) { return meta }
        }

        // TIFF ImageDescription — fallback used by some tools
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let desc = tiff[kCGImagePropertyTIFFImageDescription] as? String {
            if let meta = PNGInfoReader.readInfotext(desc) { return meta }
        }

        return nil
    }

    // EXIF UserComment starts with an 8-byte character code identifier
    // ("ASCII\0\0\0", "UNICODE\0", etc.). Strip it if present.
    private static func stripExifCharsetPrefix(_ text: String) -> String {
        let prefixes = ["ASCII\0\0\0", "UNICODE\0", "JIS\0\0\0\0\0"]
        for prefix in prefixes where text.hasPrefix(prefix) {
            return String(text.dropFirst(prefix.count))
        }
        return text
    }
}
