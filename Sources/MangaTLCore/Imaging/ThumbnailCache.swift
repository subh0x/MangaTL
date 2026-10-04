import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Two-tier thumbnail cache for one `PageSource`: a cost-bounded `NSCache` in memory and
/// small HEIC files on disk, so a 2000-page book only decodes each original page once.
/// Entries are keyed by `cacheKey(at:)` (the page's file identity), so reordering or adding
/// pages reuses every existing thumbnail.
public final class ThumbnailCache: @unchecked Sendable {
    public static let maxPixelSize = 320
    public static let memoryLimit = 40 << 20
    public static let diskLimit: Int64 = 1_500 << 20

    public let source: any PageSource
    private let directory: URL
    private let memory = NSCache<NSString, CGImage>()
    private let aspectLock = NSLock()
    private var aspects: [String: CGFloat] = [:]

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MangaTL/thumbnails")
    }

    public init(source: any PageSource, root: URL = ThumbnailCache.defaultRoot) {
        self.source = source
        directory = root
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.totalCostLimit = Self.memoryLimit
    }

    private static func hash(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Memory-only lookup; cheap enough for the main thread.
    public func cached(_ index: Int) -> CGImage? { memory.object(forKey: source.pageKey(at: index) as NSString) }

    /// Width / height of the page, known once its thumbnail has been loaded.
    public func aspect(_ index: Int) -> CGFloat? {
        let key = source.pageKey(at: index)
        return aspectLock.withLock { aspects[key] }
    }

    /// Memory → disk → original page. Call off the main thread.
    public func load(_ index: Int) throws -> CGImage {
        if let image = cached(index) { return image }
        let pageKey = source.pageKey(at: index)
        let file = directory.appendingPathComponent("\(Self.hash(source.cacheKey(at: index))).heic")
        let image: CGImage
        if let disk = try? PageDecoder.decode(url: file, maxPixelSize: Self.maxPixelSize) {
            image = disk
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        } else {
            image = try source.image(at: index, maxPixelSize: Self.maxPixelSize)
            Self.writeHEIC(image, to: file)
        }
        memory.setObject(image, forKey: pageKey as NSString, cost: image.bytesPerRow * image.height)
        aspectLock.withLock { aspects[pageKey] = CGFloat(image.width) / CGFloat(max(1, image.height)) }
        return image
    }

    private static func writeHEIC(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    /// Deletes least-recently-used thumbnail files until the cache is under `limit` bytes.
    public static func trimDisk(root: URL = defaultRoot, limit: Int64 = diskLimit) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return }
        var files: [(url: URL, date: Date, size: Int64)] = []
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let size = Int64(v.totalFileAllocatedSize ?? 0)
            files.append((url, v.contentModificationDate ?? .distantPast, size))
            total += size
        }
        guard total > limit else { return }
        for file in files.sorted(by: { $0.date < $1.date }) {
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
            if total <= limit { break }
        }
    }
}
