import CoreGraphics
import Foundation

/// PDF pages rendered straight to the requested size.
public final class PDFSource: PageSource, @unchecked Sendable {
    public let id: String
    public let title: String
    private let document: CGPDFDocument
    /// CGPDFDocument page parsing is not documented as thread-safe.
    private let lock = NSLock()

    public init(_ url: URL) throws {
        guard let document = CGPDFDocument(url as CFURL) else { throw PageSourceError.unsupported(url) }
        guard document.numberOfPages > 0 else { throw PageSourceError.empty(url) }
        self.document = document
        id = PageSources.identity(of: url)
        title = url.deletingPathExtension().lastPathComponent
    }

    public var count: Int { document.numberOfPages }
    public func name(at index: Int) -> String { "Page \(index + 1)" }

    public func image(at index: Int, maxPixelSize: Int) throws -> CGImage {
        try lock.withLock {
            guard let page = document.page(at: index + 1) else { throw PageSourceError.unreadable(name(at: index)) }
            let box = page.getBoxRect(.cropBox)
            let rotated = page.rotationAngle % 180 != 0
            let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
            let scale = CGFloat(maxPixelSize) / max(size.width, size.height)
            let width = max(1, Int(size.width * scale)), height = max(1, Int(size.height * scale))
            guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw PageSourceError.unreadable(name(at: index))
            }
            ctx.setFillColor(.white)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.interpolationQuality = .high
            ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: width, height: height), rotate: 0, preserveAspectRatio: true))
            ctx.drawPDFPage(page)
            guard let image = ctx.makeImage() else { throw PageSourceError.unreadable(name(at: index)) }
            return image
        }
    }
}
