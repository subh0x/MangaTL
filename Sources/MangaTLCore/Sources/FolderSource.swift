import CoreGraphics
import Foundation

/// Image files directly inside a folder, in Finder (natural) order.
public final class FolderSource: PageSource {
    public let id: String
    public let title: String
    private let files: [URL]

    public init(_ folder: URL) throws {
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        files = urls
            .filter { PageSources.isImageName($0.lastPathComponent) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !files.isEmpty else { throw PageSourceError.empty(folder) }
        id = PageSources.identity(of: folder)
        title = folder.lastPathComponent
    }

    public var count: Int { files.count }
    public func name(at index: Int) -> String { files[index].lastPathComponent }

    public func image(at index: Int, maxPixelSize: Int) throws -> CGImage {
        try PageDecoder.decode(url: files[index], maxPixelSize: maxPixelSize)
    }
}
