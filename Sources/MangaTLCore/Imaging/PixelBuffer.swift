import CoreGraphics
import Foundation

/// 8-bit RGBA pixels in sRGB, origin top-left. The common currency between decoding, the ML
/// stages and the patch layer; small enough to crop/resize with Core Graphics.
public struct PixelBuffer: Sendable {
    public let width: Int
    public let height: Int
    public var bytes: [UInt8]

    public var size: CGSize { CGSize(width: width, height: height) }
    static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

    public init(width: Int, height: Int, fill: UInt8 = 0) {
        self.width = width
        self.height = height
        bytes = [UInt8](repeating: fill, count: width * height * 4)
    }

    /// Draws `image` scaled to `width × height` (defaults to its own size).
    public init(_ image: CGImage, width: Int? = nil, height: Int? = nil) {
        self.init(width: width ?? image.width, height: height ?? image.height)
        let (w, h) = (self.width, self.height)
        bytes.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: Self.bitmapInfo)!
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    public func makeImage() -> CGImage {
        let data = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: Self.bitmapInfo),
                       provider: data, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }

    /// Crops to `rect` (pixels, clamped to the image) and optionally resizes.
    public func cropped(to rect: CGRect, width outW: Int? = nil, height outH: Int? = nil) -> PixelBuffer {
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !r.isNull, r.width >= 1, r.height >= 1 else { return PixelBuffer(width: outW ?? 1, height: outH ?? 1) }
        var crop = PixelBuffer(width: Int(r.width), height: Int(r.height))
        for y in 0..<crop.height {
            let src = ((Int(r.minY) + y) * width + Int(r.minX)) * 4
            crop.bytes.replaceSubrange(y * crop.width * 4..<(y + 1) * crop.width * 4, with: bytes[src..<src + crop.width * 4])
        }
        guard let outW, let outH, outW != crop.width || outH != crop.height else { return crop }
        return PixelBuffer(crop.makeImage(), width: outW, height: outH)
    }

    /// Writes `other` at (`x`, `y`); with `mask`, only where the mask byte is non-zero.
    public mutating func paste(_ other: PixelBuffer, x: Int, y: Int, mask: [UInt8]? = nil) {
        for row in 0..<other.height where y + row >= 0 && y + row < height {
            for col in 0..<other.width where x + col >= 0 && x + col < width {
                if let mask, mask[row * other.width + col] == 0 { continue }
                let s = (row * other.width + col) * 4, d = ((y + row) * width + x + col) * 4
                bytes[d] = other.bytes[s]; bytes[d + 1] = other.bytes[s + 1]
                bytes[d + 2] = other.bytes[s + 2]; bytes[d + 3] = other.bytes[s + 3]
            }
        }
    }

    /// Planar float tensor [1, 3, H, W]: (v / 255 - mean) / std per channel.
    public func chwFloats(mean: [Float] = [0, 0, 0], std: [Float] = [1, 1, 1]) -> [Float] {
        let plane = width * height
        var out = [Float](repeating: 0, count: plane * 3)
        for i in 0..<plane {
            for c in 0..<3 { out[c * plane + i] = (Float(bytes[i * 4 + c]) / 255 - mean[c]) / std[c] }
        }
        return out
    }

    /// Smallest rect holding every pixel with non-zero alpha, nil if fully transparent.
    public func opaqueBounds() -> CGRect? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where bytes[(y * width + x) * 4 + 3] != 0 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return maxX < 0 ? nil : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Rec. 601 luma per pixel.
    public func luma() -> [UInt8] {
        (0..<width * height).map { i in
            let r = 299 * Int(bytes[i * 4]), g = 587 * Int(bytes[i * 4 + 1]), b = 114 * Int(bytes[i * 4 + 2])
            return UInt8((r + g + b) / 1000)
        }
    }
}
