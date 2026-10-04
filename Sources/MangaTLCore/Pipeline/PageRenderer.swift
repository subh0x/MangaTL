import CoreGraphics
import CoreText
import Foundation

/// Composites original page + patch layer + typeset translations. Used for on-screen display
/// (at screen size) and export (at full size), so what you see is what you export.
public enum PageRenderer {
    /// One image layer's pixels and where they go (working-size pixels, top-left origin).
    public struct Layer {
        public var rect: CGRect
        public var image: CGImage
        public init(rect: CGRect, image: CGImage) {
            self.rect = rect
            self.image = image
        }
    }

    /// `showPage: false` leaves the page and layers out: just the lettering on transparency.
    public static func render(page: CGImage, doc: PageDoc, layers: [Layer], settings: ProjectSettings, showText: Bool = true,
                              showPage: Bool = true) -> CGImage? {
        let size = CGSize(width: page.width, height: page.height)
        guard let ctx = CGContext(data: nil, width: page.width, height: page.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let bounds = CGRect(origin: .zero, size: size)
        ctx.interpolationQuality = .high
        let scale = size.width / max(1, doc.workingSize.width)
        if showPage {
            ctx.draw(page, in: bounds)
            drawLayers(layers, in: ctx, pageHeight: size.height, scale: scale)
        } else {
            ctx.clear(bounds)
        }
        if showText {
            for block in doc.blocks where !block.hidden {
                drawText(block, style: settings.resolvedStyle(for: block), in: ctx, pageSize: size, scale: scale)
            }
        }
        return ctx.makeImage()
    }

    /// Draws layers into a bottom-left-origin context; `scale` maps working pixels to the context.
    public static func drawLayers(_ layers: [Layer], in ctx: CGContext, pageHeight: CGFloat, scale: CGFloat) {
        for layer in layers {
            let r = layer.rect
            ctx.draw(layer.image, in: CGRect(x: r.minX * scale, y: pageHeight - r.maxY * scale, width: r.width * scale, height: r.height * scale))
        }
    }

    /// The font size `drawText` uses for `block` (auto-fitted unless the style fixes it).
    public static func fittedFontSize(_ block: TextBlock, style: TextStyle, pageSize: CGSize, scale: CGFloat) -> CGFloat? {
        textLayout(block, style: style, pageSize: pageSize, scale: scale)?.fontSize
    }

    /// The block's frame in a bottom-left-origin page space (normalised rects are top-left).
    static func flippedFrame(_ block: TextBlock, pageSize: CGSize) -> CGRect {
        let rect = block.layoutRect.denormalized(to: pageSize)
        return CGRect(x: rect.minX, y: pageSize.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// How `drawText` lays the block out (also used by the typeset check).
    public static func textLayout(_ block: TextBlock, style: TextStyle, pageSize: CGSize, scale: CGFloat) -> Typesetter.Layout? {
        Typesetter.layout(block.translation, in: flippedFrame(block, pageSize: pageSize), shape: block.shape, style: style, scale: scale)
    }

    /// Draws one block into a bottom-left-origin context the size of the page.
    public static func drawText(_ block: TextBlock, style: TextStyle, in ctx: CGContext, pageSize: CGSize, scale: CGFloat) {
        guard let layout = textLayout(block, style: style, pageSize: pageSize, scale: scale) else { return }
        let frame = flippedFrame(block, pageSize: pageSize)
        ctx.saveGState()
        if block.rotation != 0 {
            ctx.translateBy(x: frame.midX, y: frame.midY)
            ctx.rotate(by: -block.rotation * .pi / 180)
            ctx.translateBy(x: -frame.midX, y: -frame.midY)
        }
        Typesetter.draw(layout, style: style, in: ctx, scale: scale)
        ctx.restoreGState()
    }
}
