import CoreGraphics
import Foundation
import ZIPFoundation

/// Pages inside a CBZ/ZIP, read one entry at a time without unpacking the archive.
public final class ZipSource: PageSource, @unchecked Sendable {
    public let id: String
    public let title: String
    private let archive: Archive
    private let entries: [Entry]
    /// ZIPFoundation's `Archive` shares one file handle, so reads are serialised; decoding is not.
    private let lock = NSLock()

    public init(_ url: URL) throws {
        archive = try Archive(url: url, accessMode: .read)
        entries = archive
            .filter { $0.type == .file && PageSources.isImageName($0.path) && !$0.path.hasPrefix("__MACOSX/") }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        guard !entries.isEmpty else { throw PageSourceError.empty(url) }
        id = PageSources.identity(of: url)
        title = url.deletingPathExtension().lastPathComponent
    }

    public var count: Int { entries.count }
    public func name(at index: Int) -> String { (entries[index].path as NSString).lastPathComponent }

    public func image(at index: Int, maxPixelSize: Int) throws -> CGImage {
        let entry = entries[index]
        var data = Data(capacity: Int(entry.uncompressedSize))
        try lock.withLock {
            _ = try archive.extract(entry, skipCRC32: true) { data.append($0) }
        }
        return try PageDecoder.decode(data: data, maxPixelSize: maxPixelSize, name: entry.path)
    }
}
