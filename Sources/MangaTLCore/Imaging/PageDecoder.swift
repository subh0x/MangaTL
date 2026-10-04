import CoreGraphics
import Foundation
import ImageIO

/// Downsampled decoding through ImageIO: the full-resolution bitmap is never materialised.
enum PageDecoder {
    static func decode(_ source: CGImageSource, maxPixelSize: Int, name: String) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PageSourceError.unreadable(name)
        }
        return image
    }

    static func decode(url: URL, maxPixelSize: Int) throws -> CGImage {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else {
            throw PageSourceError.unreadable(url.lastPathComponent)
        }
        return try decode(source, maxPixelSize: maxPixelSize, name: url.lastPathComponent)
    }

    static func decode(data: Data, maxPixelSize: Int, name: String) throws -> CGImage {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
            throw PageSourceError.unreadable(name)
        }
        return try decode(source, maxPixelSize: maxPixelSize, name: name)
    }
}
