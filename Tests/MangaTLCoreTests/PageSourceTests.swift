import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import ZIPFoundation
@testable import MangaTLCore

/// Builds a folder of JPEG pages (named so natural order ≠ lexical order), a CBZ of it and a PDF.
struct Fixture {
    let root: URL
    let folder: URL
    let cbz: URL
    let pdf: URL
    static let names = ["p1.jpg", "p2.jpg", "p10.jpg"]
    static let sizes = [CGSize(width: 1200, height: 1700), CGSize(width: 1000, height: 1500), CGSize(width: 2400, height: 1700)]

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mangatl-\(UUID().uuidString)")
        folder = root.appendingPathComponent("book")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, size) in zip(Self.names, Self.sizes) {
            try Self.writeJPEG(size: size, to: folder.appendingPathComponent(name))
        }
        try Data("not an image".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        cbz = root.appendingPathComponent("book.cbz")
        try FileManager.default.zipItem(at: folder, to: cbz)
        pdf = root.appendingPathComponent("book.pdf")
        var box = CGRect(x: 0, y: 0, width: 600, height: 850)
        let ctx = CGContext(pdf as CFURL, mediaBox: &box, nil)!
        for _ in 0..<2 { ctx.beginPDFPage(nil); ctx.setFillColor(.black); ctx.fill(CGRect(x: 50, y: 50, width: 100, height: 100)); ctx.endPDFPage() }
        ctx.closePDF()
    }

    static func writeJPEG(size: CGSize, to url: URL) throws {
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(gray: 0.9, alpha: 1)
        ctx.fill(CGRect(origin: .zero, size: size))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}

@Suite struct PageSourceTests {
    let fixture: Fixture
    init() throws { fixture = try Fixture() }

    @Test(arguments: ["folder", "cbz"])
    func imageSourcesListPagesInNaturalOrder(kind: String) throws {
        let source = try PageSources.open(kind == "folder" ? fixture.folder : fixture.cbz)
        #expect(source.count == 3)
        #expect((0..<3).map(source.name(at:)) == Fixture.names)
    }

    @Test(arguments: ["folder", "cbz", "pdf"])
    func decodeNeverExceedsRequestedSize(kind: String) throws {
        let url = ["folder": fixture.folder, "cbz": fixture.cbz, "pdf": fixture.pdf][kind]!
        let source = try PageSources.open(url)
        for i in 0..<source.count {
            let image = try source.image(at: i, maxPixelSize: 320)
            #expect(max(image.width, image.height) <= 320)
            #expect(max(image.width, image.height) >= 300)
        }
    }

    @Test func wideFolderPageKeepsAspect() throws {
        let image = try PageSources.open(fixture.folder).image(at: 2, maxPixelSize: 480)
        #expect(image.width == 480 && abs(image.height - 340) <= 1)
    }

    @Test func pdfHasOnePagePerPDFPage() throws {
        let source = try PageSources.open(fixture.pdf)
        #expect(source.count == 2)
        let image = try source.image(at: 0, maxPixelSize: 850)
        #expect(image.height == 850 && image.width == 600)
    }

    @Test func pdfPagesScaleUpToTheRequestedSize() throws {
        // 600×850 pt page with a black square at (50,50)-(150,150) from the bottom-left.
        let image = try PageSources.open(fixture.pdf).image(at: 0, maxPixelSize: 1700)
        #expect(image.width == 1200 && image.height == 1700)
        let pixels = PixelBuffer(image)
        func luma(_ x: Int, _ y: Int) -> UInt8 { pixels.bytes[(y * pixels.width + x) * 4] }
        #expect(luma(200, 1700 - 200) < 30, "square drawn at 2× near the bottom-left")
        #expect(luma(200, 200) > 220, "top-left is blank page, not an unscaled corner")
        #expect(luma(1100, 1600) > 220)
    }

    @Test func rejectsUnsupportedFiles() throws {
        #expect(throws: PageSourceError.self) { try PageSources.open(fixture.folder.appendingPathComponent("notes.txt")) }
    }

    @Test func thumbnailCacheRoundTripsThroughDisk() throws {
        let root = fixture.root.appendingPathComponent("cache")
        let source = try PageSources.open(fixture.folder)
        let first = ThumbnailCache(source: source, root: root)
        let thumb = try first.load(0)
        #expect(max(thumb.width, thumb.height) == ThumbnailCache.maxPixelSize)
        #expect(abs((first.aspect(0) ?? 0) - 1200.0 / 1700.0) < 0.01)

        // A fresh cache (new launch) finds the HEIC on disk instead of decoding the original.
        let second = ThumbnailCache(source: source, root: root)
        #expect(second.cached(0) == nil)
        _ = try second.load(0)
        let files = try FileManager.default.subpathsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".heic") }
        #expect(files.count == 1)
    }

    @Test func trimDiskRemovesOldestFirst() throws {
        let root = fixture.root.appendingPathComponent("trim")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for i in 0..<4 {
            let url = root.appendingPathComponent("\(i).heic")
            try Data(count: 64 * 1024).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(i) * 1000)], ofItemAtPath: url.path)
        }
        ThumbnailCache.trimDisk(root: root, limit: 140 * 1024)
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(left == ["2.heic", "3.heic"])
    }
}
