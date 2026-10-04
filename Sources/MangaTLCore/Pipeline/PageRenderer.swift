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

    public static func render(page: CGImage, doc: PageDoc, layers: [Layer], style: TextStyle, showText: Bool = true) -> CGImage? {
        let size = CGSize(width: page.width, height: page.height)
        guard let ctx = CGContext(data: nil, width: page.width, height: page.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let bounds = CGRect(origin: .zero, size: size)
        ctx.interpolationQuality = .high
        ctx.draw(page, in: bounds)
        let scale = size.width / max(1, doc.workingSize.width)
        drawLayers(layers, in: ctx, pageHeight: size.height, scale: scale)
        if showText {
            for block in doc.blocks where !block.hidden {
                drawText(block, style: block.style ?? style, in: ctx, pageSize: size, scale: scale)
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
        layout(block, style: style, pageSize: pageSize, scale: scale)?.layout.fontSize
    }

    private static func layout(_ block: TextBlock, style: TextStyle, pageSize: CGSize, scale: CGFloat) -> (layout: Typesetter.Layout, frame: CGRect)? {
        let rect = block.layoutRect.denormalized(to: pageSize)
        // Normalised rects are top-left-origin; Core Text draws bottom-left.
        let flipped = CGRect(x: rect.minX, y: pageSize.height - rect.maxY, width: rect.width, height: rect.height)
        let box = Typesetter.textBox(for: flipped, shape: block.shape)
        return Typesetter.layout(block.translation, in: box, style: style, scale: scale).map { ($0, flipped) }
    }

    /// Draws one block into a bottom-left-origin context the size of the page.
    public static func drawText(_ block: TextBlock, style: TextStyle, in ctx: CGContext, pageSize: CGSize, scale: CGFloat) {
        guard let (layout, flipped) = layout(block, style: style, pageSize: pageSize, scale: scale) else { return }
        ctx.saveGState()
        if block.rotation != 0 {
            ctx.translateBy(x: flipped.midX, y: flipped.midY)
            ctx.rotate(by: -block.rotation * .pi / 180)
            ctx.translateBy(x: -flipped.midX, y: -flipped.midY)
        }
        Typesetter.draw(layout, style: style, in: ctx, scale: scale)
        ctx.restoreGState()
    }
}
