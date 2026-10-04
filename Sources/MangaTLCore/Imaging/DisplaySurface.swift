import CoreGraphics
import CoreVideo
import IOSurface

/// Copies a decoded page into an IOSurface (BGRA, sRGB). Core Animation displays IOSurface layer
/// contents without making its own copy, and the memory is returned as soon as the surface is
/// released — unlike CGImage contents, which CA re-renders and caches per image on the main thread.
public enum DisplaySurface {
    public static func make(from image: CGImage) -> IOSurface? {
        let width = image.width, height = image.height
        let properties: [IOSurfacePropertyKey: Any] = [
            .width: width,
            .height: height,
            .bytesPerElement: 4,
            .pixelFormat: kCVPixelFormatType_32BGRA,
        ]
        guard let surface = IOSurface(properties: properties) else { return nil }
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        guard let ctx = CGContext(data: surface.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: surface.bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return surface
    }
}
