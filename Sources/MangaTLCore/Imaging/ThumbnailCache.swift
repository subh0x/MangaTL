import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Two-tier thumbnail cache for one `PageSource`: a cost-bounded `NSCache` in memory and
/// small HEIC files on disk, so a 2000-page book only decodes each original page once.
/// Entries are keyed by `cacheKey(at:)` (the page's file identity), so reordering or adding
/// pages reuses every existing thumbnail.
///
/// With `setEdits`, pages that have saved work are shown as edited: their text and visible
/// layers are drawn onto the original thumbnail. Those entries are also keyed by when the page
/// was saved and by the lettering styles, so every edit or preset change gets a new thumbnail.
public final class ThumbnailCache: @unchecked Sendable {
    public static let maxPixelSize = 320
    /// Sharper thumbnails for large grid sizes (decoded on demand, cached separately).
    public static let largePixelSize = 640
    public static let memoryLimit = 40 << 20
    public static let diskLimit: Int64 = 1_500 << 20

    public let source: any PageSource
    private let directory: URL
    private let memory = NSCache<NSString, CGImage>()
    private let aspectLock = NSLock()
    private var aspects: [String: CGFloat] = [:]
    private var edits: (store: ProjectStore, settings: ProjectSettings, settingsKey: String)?

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

    /// Shows pages with saved work in `store` as edited, lettered with `settings`.
    public func setEdits(store: ProjectStore, settings: ProjectSettings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let key = Self.hash((try? encoder.encode(settings)).map { String(decoding: $0, as: UTF8.self) } ?? "")
        aspectLock.withLock { edits = (store, settings, key) }
    }

    /// Identifies the edited look of a page: when it was saved, and the styles. Nil = original.
    private func editKey(_ index: Int) -> String? {
        guard let edits = aspectLock.withLock({ edits }),
              let saved = edits.store.pageModified(source.pageKey(at: index)) else { return nil }
        return "\(saved.timeIntervalSince1970)|\(edits.settingsKey)"
    }

    private func memoryKey(_ index: Int, large: Bool, edit: String? = nil) -> NSString {
        let base = large ? "\(source.pageKey(at: index))@2x" : source.pageKey(at: index)
        return (edit.map { "\(base)|\($0)" } ?? base) as NSString
    }

    /// Memory-only lookup; cheap enough for the main thread.
    public func cached(_ index: Int, large: Bool = false) -> CGImage? {
        memory.object(forKey: memoryKey(index, large: large, edit: editKey(index)))
    }

    /// Width / height of the page, known once its thumbnail has been loaded.
    public func aspect(_ index: Int) -> CGFloat? {
        let key = source.pageKey(at: index)
        return aspectLock.withLock { aspects[key] }
    }

    /// Memory → disk → original page, drawn as edited when the page has saved work. Call off the
    /// main thread.
    public func load(_ index: Int, large: Bool = false) throws -> CGImage {
        guard let edit = editKey(index), let edits = aspectLock.withLock({ edits }) else { return try loadOriginal(index, large: large) }
        let key = memoryKey(index, large: large, edit: edit)
        if let image = memory.object(forKey: key) { return image }
        let file = directory.appendingPathComponent("\(Self.hash(source.cacheKey(at: index) + (large ? "@640" : "") + "|" + edit)).heic")
        let image: CGImage
        if let disk = try? PageDecoder.decode(url: file, maxPixelSize: large ? Self.largePixelSize : Self.maxPixelSize) {
            image = disk
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        } else {
            let original = try loadOriginal(index, large: large)
            let page = source.pageKey(at: index)
            guard let doc = edits.store.loadPage(page),
                  let rendered = PageRenderer.render(page: original, doc: doc, layers: edits.store.visibleLayers(of: doc, page: page),
                                                     settings: edits.settings) else { return original }
            image = rendered
            Self.writeHEIC(image, to: file)
        }
        memory.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    private func loadOriginal(_ index: Int, large: Bool) throws -> CGImage {
        if let image = memory.object(forKey: memoryKey(index, large: large)) { return image }
        let pageKey = source.pageKey(at: index)
        let pixels = large ? Self.largePixelSize : Self.maxPixelSize
        let file = directory.appendingPathComponent("\(Self.hash(source.cacheKey(at: index) + (large ? "@640" : ""))).heic")
        let image: CGImage
        if let disk = try? PageDecoder.decode(url: file, maxPixelSize: pixels) {
            image = disk
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        } else {
            image = try source.image(at: index, maxPixelSize: pixels)
            Self.writeHEIC(image, to: file)
        }
        memory.setObject(image, forKey: memoryKey(index, large: large), cost: image.bytesPerRow * image.height)
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
