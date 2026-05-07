import CoreGraphics
import Foundation
import ImageIO

struct CullGroup {
    let keeper: ImageItem
    let duplicates: [ImageItem]
}

struct CullResult {
    let groups: [CullGroup]
    let singletonCount: Int

    var toTrashCount: Int { groups.reduce(0) { $0 + $1.duplicates.count } }
    var groupCount: Int { groups.count }
}

enum ImageCuller {
    // dHash: resize to 9x8 grayscale, compare each pixel to its right neighbor → 64 bits.
    static func computeHash(url: URL) -> UInt64? {
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOptions as CFDictionary)
        else { return nil }

        let w = 9, h = 8
        var pixels = [UInt8](repeating: 0, count: w * h)
        let space = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w,
            space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: w, height: h))

        var hash: UInt64 = 0
        for row in 0..<h {
            for col in 0..<(w - 1) {
                let i = row * w + col
                if pixels[i] > pixels[i + 1] {
                    hash |= 1 << (row * 8 + col)
                }
            }
        }
        return hash
    }

    static func findGroups(images: [ImageItem], threshold: Int) async -> CullResult {
        var entries: [(image: ImageItem, hash: UInt64, fileSize: Int)] = []
        for image in images {
            guard let hash = computeHash(url: image.fileURL) else { continue }
            let size = (try? FileManager.default.attributesOfItem(
                atPath: image.fileURL.path
            )[.size] as? Int) ?? 0
            entries.append((image, hash, size))
        }

        let n = entries.count
        var adj = [[Int]](repeating: [], count: n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                if (entries[i].hash ^ entries[j].hash).nonzeroBitCount <= threshold {
                    adj[i].append(j)
                    adj[j].append(i)
                }
            }
        }

        var visited = [Bool](repeating: false, count: n)
        var groups: [CullGroup] = []
        var singletons = 0

        for start in 0..<n {
            guard !visited[start] else { continue }
            var component: [Int] = []
            var queue = [start]
            visited[start] = true
            while !queue.isEmpty {
                let node = queue.removeFirst()
                component.append(node)
                for neighbor in adj[node] where !visited[neighbor] {
                    visited[neighbor] = true
                    queue.append(neighbor)
                }
            }
            if component.count == 1 {
                singletons += 1
            } else {
                let members = component.map { entries[$0] }.sorted { $0.fileSize > $1.fileSize }
                groups.append(CullGroup(
                    keeper: members[0].image,
                    duplicates: members.dropFirst().map(\.image)
                ))
            }
        }

        return CullResult(groups: groups, singletonCount: singletons)
    }
}
