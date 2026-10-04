import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ZIPFoundation

/// Writes the book with translations applied — untranslated pages are copied as-is (re-encoded).
/// One page is decoded, rendered and written at a time.
public enum BookExporter {
    public enum Format: Sendable { case cbz, folder }
    /// Longest side of exported pages; originals larger than this are scaled down.
    public static let maxPixels = 4096

    /// With `store` nil the pages are written as they are (used to import a CBZ/PDF into a folder).
    public static func export(_ source: any PageSource, store: ProjectStore?, settings: ProjectSettings, to url: URL, format: Format,
                              progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws {
        let digits = String(source.count).count
        var archive: Archive?
        switch format {
        case .cbz:
            try? FileManager.default.removeItem(at: url)
            archive = try Archive(url: url, accessMode: .create)
        case .folder:
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        for index in 0..<source.count {
            try Task.checkCancellation()
            progress(index, source.count)
            let data: Data = try autoreleasepool {
                var image = try source.image(at: index, maxPixelSize: maxPixels)
                let page = source.pageKey(at: index)
                if let store, let doc = store.loadPage(page),
                   let rendered = PageRenderer.render(page: image, doc: doc, layers: store.visibleLayers(of: doc, page: page), settings: settings) {
                    image = rendered
                }
                return try jpeg(image)
            }
            let name = String(repeating: "0", count: max(0, digits - String(index + 1).count)) + "\(index + 1).jpg"
            if let archive {
                // JPEGs don't compress further; store them.
                try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .none) { position, size in
                    data.subdata(in: Int(position)..<Int(position) + size)
                }
            } else {
                try data.write(to: url.appendingPathComponent(name), options: .atomic)
            }
        }
        progress(source.count, source.count)
    }

    static func jpeg(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }
}
