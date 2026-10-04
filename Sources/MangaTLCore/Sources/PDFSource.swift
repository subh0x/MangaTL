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
            // Render at the requested size, but no sharper than 300 dpi (PDF units are 1/72 in).
            let longest = max(size.width, size.height)
            let scale = min(CGFloat(maxPixelSize), longest * 300 / 72) / longest
            let width = max(1, Int(size.width * scale)), height = max(1, Int(size.height * scale))
            guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw PageSourceError.unreadable(name(at: index))
            }
            ctx.setFillColor(.white)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.interpolationQuality = .high
            // getDrawingTransform never scales up, so build the transform here: scale, then undo the
            // page's rotation and crop-box offset.
            ctx.scaleBy(x: scale, y: scale)
            switch (page.rotationAngle % 360 + 360) % 360 {
            case 90:
                ctx.translateBy(x: 0, y: size.height)
                ctx.rotate(by: -.pi / 2)
            case 180:
                ctx.translateBy(x: size.width, y: size.height)
                ctx.rotate(by: .pi)
            case 270:
                ctx.translateBy(x: size.width, y: 0)
                ctx.rotate(by: .pi / 2)
            default:
                break
            }
            ctx.translateBy(x: -box.minX, y: -box.minY)
            ctx.drawPDFPage(page)
            guard let image = ctx.makeImage() else { throw PageSourceError.unreadable(name(at: index)) }
            return image
        }
    }
}
