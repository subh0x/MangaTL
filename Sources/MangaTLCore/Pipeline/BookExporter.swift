import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ZIPFoundation

/// Writes pages (final, clean, text-only or original) as a folder of images, a CBZ or a PDF.
/// One page is decoded, rendered, encoded and written at a time.
public enum BookExporter {
    /// - Parameters:
    ///   - pages: 0-based page indices to export, in order (nil = all).
    ///   - store: with nil, pages are written as they are (used to import a CBZ/PDF into a folder).
    public static func export(_ source: any PageSource, store: ProjectStore?, settings: ProjectSettings, pages: [Int]? = nil,
                              options: ExportOptions, title: String = "", to url: URL,
                              progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws {
        let indices = pages ?? Array(0..<source.count)
        let format = options.effectiveFormat
        let writer = try Writer(package: options.package, url: url)
        var used = Set<String>()
        for (n, index) in indices.enumerated() {
            try Task.checkCancellation()
            progress(n, indices.count)
            try autoreleasepool {
                let image = try render(source, index: index, store: store, settings: settings, options: options)
                if options.package == .pdf {
                    try writer.addPDFPage(image, format: format, quality: options.quality)
                } else {
                    let base = options.fileName(index: index, count: source.count, originalName: source.name(at: index), project: title)
                    var name = "\(base).\(format.fileExtension)", copy = 2
                    while used.contains(name.lowercased()) {
                        name = "\(base) \(copy).\(format.fileExtension)"
                        copy += 1
                    }
                    used.insert(name.lowercased())
                    try writer.add(encode(image, format: format, quality: options.quality), name: name)
                }
            }
        }
        try writer.finish()
        progress(indices.count, indices.count)
    }

    static func render(_ source: any PageSource, index: Int, store: ProjectStore?, settings: ProjectSettings,
                       options: ExportOptions) throws -> CGImage {
        let page = try source.image(at: index, maxPixelSize: options.size.maxPixels)
        guard options.content != .original, let store else { return page }
        let key = source.pageKey(at: index)
        guard let doc = store.loadPage(key) else {
            // Untranslated: the original, or nothing for a text-only export.
            return options.content == .textOnly ? blank(like: page) : page
        }
        let rendered = PageRenderer.render(page: page, doc: doc, layers: store.visibleLayers(of: doc, page: key), settings: settings,
                                           showText: options.content != .clean, showPage: options.content != .textOnly)
        return rendered ?? page
    }

    private static func blank(like page: CGImage) -> CGImage {
        let ctx = CGContext(data: nil, width: page.width, height: page.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        return ctx.makeImage()!
    }

    static func encode(_ image: CGImage, format: ExportOptions.Format, quality: Double) throws -> Data {
        let type: UTType = switch format {
        case .jpeg: .jpeg
        case .png: .png
        case .heic: .heic
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let properties: [CFString: Any] = format.hasQuality ? [kCGImageDestinationLossyCompressionQuality: quality] : [:]
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    /// The output container: a folder, a CBZ (ZIP, stored), or a PDF with one page per image.
    final class Writer {
        let package: ExportOptions.Package
        let url: URL
        private var archive: Archive?
        private var pdf: CGContext?

        init(package: ExportOptions.Package, url: URL) throws {
            self.package = package
            self.url = url
            switch package {
            case .folder:
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            case .cbz:
                try? FileManager.default.removeItem(at: url)
                archive = try Archive(url: url, accessMode: .create)
            case .pdf:
                try? FileManager.default.removeItem(at: url)
                guard let context = CGContext(url as CFURL, mediaBox: nil, [kCGPDFContextCreator: "MangaTL"] as CFDictionary) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                pdf = context
            }
        }

        func add(_ data: Data, name: String) throws {
            if let archive {
                // Images don't compress further; store them.
                try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .none) { position, size in
                    data.subdata(in: Int(position)..<Int(position) + size)
                }
            } else {
                try data.write(to: url.appendingPathComponent(name), options: .atomic)
            }
        }

        /// A PDF page the size of the image (1 px = 1 pt). JPEG data is embedded as-is (DCT), which
        /// keeps PDFs close to the size of the images.
        func addPDFPage(_ image: CGImage, format: ExportOptions.Format, quality: Double) throws {
            guard let pdf else { return }
            var drawn = image
            if format == .jpeg, let provider = CGDataProvider(data: try encode(image, format: .jpeg, quality: quality) as CFData),
               let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
                drawn = jpeg
            }
            var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            pdf.beginPage(mediaBox: &box)
            pdf.draw(drawn, in: box)
            pdf.endPage()
        }

        func finish() throws {
            pdf?.closePDF()
        }
    }
}
