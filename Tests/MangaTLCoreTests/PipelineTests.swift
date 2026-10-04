import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MangaTLCore

/// End-to-end on real pages. Needs `models/` (tools/export_models.py) and `spike/pages/`
/// (Pepper&Carrot samples); skipped otherwise.
enum PipelineFixtures {
    static let pages = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../spike/pages").standardized
    static let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../spike/out").standardized
    static var available: Bool { ModelStore.root != nil && FileManager.default.fileExists(atPath: pages.path) }
}

@Suite(.serialized, .enabled(if: PipelineFixtures.available))
struct PipelineTests {
    static let pages = PipelineFixtures.pages
    static let out = PipelineFixtures.out

    /// Samples `phys_footprint` every 5 ms while `body` runs.
    static func peakFootprint<T>(_ body: () async throws -> T) async rethrows -> (T, Double) {
        let peak = PeakBox()
        let sampler = Task.detached {
            while !Task.isCancelled {
                peak.update(MemoryFootprint.megabytes())
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        let result = try await body()
        sampler.cancel()
        peak.update(MemoryFootprint.megabytes())
        return (result, peak.value)
    }

    @Test(arguments: [("ja_P01", SourceLanguage.japanese), ("fr_P01", .french), ("kr_P01", .korean), ("cn_P05", .chineseSimplified)])
    func translatesPage(name: String, language: SourceLanguage) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mangatl-pipe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.pages.appendingPathComponent("\(name).jpg"), to: folder.appendingPathComponent("\(name).jpg"))
        let source = try ProjectSource(folder: folder)
        let store = source.store
        let key = source.pageKey(at: 0)
        let settings = ProjectSettings(language: language)

        let baseline = MemoryFootprint.megabytes()
        let start = Date()
        let (doc, peak) = try await Self.peakFootprint {
            try await PagePipeline.shared.process(source, index: 0, settings: settings, store: store)
        }
        print("PIPELINE \(name): \(doc.blocks.count) blocks in \(String(format: "%.1f", Date().timeIntervalSince(start)))s, footprint \(Int(baseline)) → peak \(Int(peak)) MB")
        for block in doc.blocks { print("  [\(block.shape)] \(block.sourceText.replacingOccurrences(of: "\n", with: " ")) → \(block.translation)") }

        #expect(doc.blocks.count >= 3)
        #expect(doc.blocks.filter { !$0.translation.isEmpty }.count >= doc.blocks.count - 1)
        #expect(store.loadPage(key) == doc)
        #expect(doc.layers.allSatisfy { $0.kind == .cleanup })
        #expect(peak - baseline < 250, "pipeline stage exceeded the app memory budget")

        // Render for visual review.
        let page = try source.image(at: 0, maxPixelSize: PagePipeline.workingMaxPixels)
        let rendered = try #require(PageRenderer.render(page: page, doc: doc, layers: store.visibleLayers(of: doc, page: key), style: settings.style))
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(Self.out.appendingPathComponent("\(name).jpg") as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, rendered, nil)
        #expect(CGImageDestinationFinalize(dest))

        // Translating again replaces text + clean-up but keeps the user's own layers.
        var withUser = doc
        let user = ImageLayer(name: "My retouch", rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        try store.saveLayer(PixelBuffer(width: 10, height: 10, fill: 255).makeImage(), page: key, id: user.id)
        withUser.layers.append(user)
        try store.save(withUser, page: key)
        let again = try await PagePipeline.shared.process(source, index: 0, settings: settings, store: store)
        #expect(again.layers.contains { $0.id == user.id })
        #expect(again.layers.filter { $0.kind == .cleanup }.count == 1)
        #expect(store.loadLayer(key, user.id) != nil)
    }
}

final class PeakBox: @unchecked Sendable {
    private let lock = NSLock()
    private var peak = 0.0
    func update(_ v: Double) { lock.withLock { peak = max(peak, v) } }
    var value: Double { lock.withLock { peak } }
}
