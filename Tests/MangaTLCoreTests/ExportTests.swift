import CoreGraphics
import Foundation
import ImageIO
import Testing
import ZIPFoundation
@testable import MangaTLCore

@Suite struct ExportTests {
    /// A 3-page project where page 2 has a black 100×100 clean-up layer, a hidden layer, and text.
    static func project() throws -> (Fixture, ProjectSource) {
        let fixture = try Fixture()
        let source = try ProjectSource(folder: fixture.folder)
        let key = source.pageKey(at: 1)
        var black = PixelBuffer(width: 100, height: 100)
        for i in 0..<100 * 100 { black.bytes[i * 4 + 3] = 255 }
        let shown = ImageLayer(name: "Clean-up", rect: CGRect(x: 0, y: 0, width: 100, height: 100), kind: .cleanup)
        var hidden = ImageLayer(name: "Hidden", rect: CGRect(x: 400, y: 700, width: 100, height: 100))
        hidden.visible = false
        try source.store.saveLayer(black.makeImage(), page: key, id: shown.id)
        try source.store.saveLayer(black.makeImage(), page: key, id: hidden.id)
        var doc = PageDoc(workingSize: CGSize(width: 1000, height: 1500), layers: [shown, hidden])
        var block = TextBlock(textRect: .zero, layoutRect: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.2), shape: .rectangle,
                              sourceText: "", translation: "HELLO THERE")
        var style = TextStyle()
        style.fontName = "Helvetica-Bold"
        style.color = RGBA(1, 0, 0)
        block.style = style
        doc.blocks = [block]
        try source.store.save(doc, page: key)
        return (fixture, source)
    }

    /// Exported images, in order, decoded from whatever package was written.
    static func images(at url: URL, package: ExportOptions.Package) throws -> [(name: String, image: CGImage)] {
        switch package {
        case .folder:
            return try FileManager.default.contentsOfDirectory(atPath: url.path).sorted().map { name in
                let src = CGImageSourceCreateWithURL(url.appendingPathComponent(name) as CFURL, nil)!
                return (name, CGImageSourceCreateImageAtIndex(src, 0, nil)!)
            }
        case .cbz:
            let archive = try Archive(url: url, accessMode: .read)
            return try archive.sorted { $0.path < $1.path }.map { entry in
                var data = Data()
                _ = try archive.extract(entry) { data.append($0) }
                let src = CGImageSourceCreateWithData(data as CFData, nil)!
                return (entry.path, CGImageSourceCreateImageAtIndex(src, 0, nil)!)
            }
        case .pdf:
            let doc = CGPDFDocument(url as CFURL)!
            return (1...doc.numberOfPages).map { ("page\($0)", try! PDFSource(url).image(at: $0 - 1, maxPixelSize: 1700)) }
        }
    }

    @Test(arguments: ExportOptions.Package.allCases, ExportOptions.Content.allCases)
    func everyPackageAndContent(package: ExportOptions.Package, content: ExportOptions.Content) async throws {
        let (fixture, source) = try Self.project()
        for format in ExportOptions.Format.allCases {
            var options = ExportOptions()
            options.package = package
            options.content = content
            options.format = format
            let out = fixture.root.appendingPathComponent("out-\(package)-\(content)-\(format)" + (package == .folder ? "" : ".\(package.rawValue)"))
            try await BookExporter.export(source, store: source.store, settings: ProjectSettings(), options: options, to: out)
            let images = try Self.images(at: out, package: package)
            #expect(images.count == 3, "\(package) \(content) \(format)")
            if package != .pdf {
                #expect(images.allSatisfy { $0.name.hasSuffix(".\(options.effectiveFormat.fileExtension)") })
            }
            let page2 = PixelBuffer(images[1].image)
            func px(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
                let i = (y * page2.width + x) * 4
                return (page2.bytes[i], page2.bytes[i + 1], page2.bytes[i + 2], page2.bytes[i + 3])
            }
            let corner = px(10, 10), middle = px(500, 1300), hiddenSpot = px(450, 750)
            switch content {
            case .final, .clean:
                #expect(corner.0 < 40, "clean-up layer applied")
                #expect(hiddenSpot.0 > 200, "hidden layer left out")
            case .original:
                #expect(corner.0 > 200, "original has no layers")
            case .textOnly where package != .pdf:
                #expect(corner.3 == 0 && middle.3 == 0, "transparent outside the lettering")
                let anyRed = stride(from: 0, to: page2.bytes.count, by: 4).contains { page2.bytes[$0] > 200 && page2.bytes[$0 + 3] > 200 }
                #expect(anyRed, "the red text is there")
            default: break
            }
        }
    }

    @Test func sizeLimitAndPageSelection() async throws {
        let (fixture, source) = try Self.project()
        var options = ExportOptions()
        options.size = .custom(500)
        let out = fixture.root.appendingPathComponent("small")
        try await BookExporter.export(source, store: source.store, settings: ProjectSettings(), pages: [2, 0], options: options, to: out)
        let images = try Self.images(at: out, package: .folder)
        #expect(images.map(\.name) == ["1.jpg", "3.jpg"])
        #expect(images.allSatisfy { max($0.image.width, $0.image.height) <= 500 })
    }

    @Test func namePatternsAndClashes() {
        var options = ExportOptions()
        #expect(options.fileName(index: 4, count: 120, originalName: "p5.jpg", project: "Vol 1") == "005")
        options.namePattern = "{project} - {name}"
        #expect(options.fileName(index: 4, count: 120, originalName: "p5.jpg", project: "Vol 1") == "Vol 1 - p5")
        options.namePattern = "a/b {n}"
        #expect(options.fileName(index: 0, count: 9, originalName: "x.png", project: "") == "a-b 1")
        options.namePattern = "  "
        #expect(options.fileName(index: 0, count: 9, originalName: "x.png", project: "") == "1")
    }

    @Test func duplicateNamesGetASuffix() async throws {
        let (fixture, source) = try Self.project()
        var options = ExportOptions()
        options.namePattern = "page"
        let out = fixture.root.appendingPathComponent("dupes")
        try await BookExporter.export(source, store: source.store, settings: ProjectSettings(), options: options, to: out)
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).sorted() == ["page 2.jpg", "page 3.jpg", "page.jpg"])
    }

    @Test func pageRanges() throws {
        #expect(try ExportOptions.pages(fromRange: "1-3, 5", count: 10) == [0, 1, 2, 4])
        #expect(try ExportOptions.pages(fromRange: "5, 2–3 ; 5", count: 10) == [1, 2, 4])
        #expect(try ExportOptions.pages(fromRange: "7", count: 7) == [6])
        for bad in ["", "0", "3-1", "11", "2-x", "a"] {
            #expect(throws: ExportOptions.RangeError.self) { try ExportOptions.pages(fromRange: bad, count: 10) }
        }
    }

    @Test func lastOptionsAreSavedWithTheProject() throws {
        let (fixture, source) = try Self.project()
        var options = ExportOptions()
        options.format = .png
        options.package = .pdf
        options.size = .custom(1200)
        source.exportOptions = options
        #expect(try ProjectSource(folder: fixture.folder).exportOptions == options)
    }
}
