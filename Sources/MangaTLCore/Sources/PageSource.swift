import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// A read-only, random-access list of manga pages. Implementations must be safe to call from
/// several threads at once and must never decode more pixels than `maxPixelSize` asks for.
public protocol PageSource: AnyObject, Sendable {
    /// Stable identity used as the thumbnail-cache key (path + modification date).
    var id: String { get }
    var title: String { get }
    var count: Int { get }
    func name(at index: Int) -> String
    /// Decodes page `index` so its longer side is at most `maxPixelSize` (never upscaled).
    func image(at index: Int, maxPixelSize: Int) throws -> CGImage
    /// Stable key for the page's saved work (survives reordering).
    func pageKey(at index: Int) -> String
    /// Identity of the page's pixels, for the thumbnail cache.
    func cacheKey(at index: Int) -> String
}

extension PageSource {
    public func pageKey(at index: Int) -> String { String(index) }
    public func cacheKey(at index: Int) -> String { "\(id)#\(index)" }
}

public enum PageSourceError: Error, LocalizedError {
    case unsupported(URL)
    case empty(URL)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let url): "\(url.lastPathComponent) is not a folder, CBZ/ZIP or PDF."
        case .empty(let url): "\(url.lastPathComponent) contains no images."
        case .unreadable(let name): "Could not decode \(name)."
        }
    }
}

public enum PageSources {
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "heic", "avif", "gif", "bmp", "tif", "tiff"]

    /// Opens a folder of images, a CBZ/ZIP archive or a PDF.
    public static func open(_ url: URL) throws -> any PageSource {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return try FolderSource(url)
        }
        switch url.pathExtension.lowercased() {
        case "cbz", "zip": return try ZipSource(url)
        case "pdf": return try PDFSource(url)
        default: throw PageSourceError.unsupported(url)
        }
    }

    static func isImageName(_ name: String) -> Bool {
        let last = (name as NSString).lastPathComponent
        return !last.hasPrefix(".") && imageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    static func identity(of url: URL) -> String {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return "\(url.standardizedFileURL.path)|\(date.timeIntervalSince1970)"
    }
}
