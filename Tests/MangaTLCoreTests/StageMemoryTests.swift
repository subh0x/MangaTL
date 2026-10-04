import Foundation
import Testing
@testable import MangaTLCore

/// Per-stage peak footprint, to keep each model inside its budget. Run via tools/test.sh.
@Suite(.serialized, .enabled(if: PipelineFixtures.available))
struct StageMemoryTests {
    @Test func stagePeaks() async throws {
        let source = try PageSources.open(PipelineFixtures.pages.appendingPathComponent("ja_P01.jpg").deletingLastPathComponent())
        let index = (0..<source.count).first { source.name(at: $0) == "ja_P01.jpg" }!
        let page = PixelBuffer(try source.image(at: index, maxPixelSize: PagePipeline.workingMaxPixels))
        var base = MemoryFootprint.megabytes()
        let (detections, detPeak) = try await PipelineTests.peakFootprint { try TextDetector.detect(page) }
        print("STAGE detect: base \(Int(base)) peak \(Int(detPeak)) (+\(Int(detPeak - base)))")
        #expect(detPeak - base < 200)
        let regions = PageLayout.regions(from: detections, rightToLeft: true)
        let crops = regions.map { page.cropped(to: $0.text) }
        base = MemoryFootprint.megabytes()
        let (_, ocrPeak) = try await PipelineTests.peakFootprint { try MangaOCR.recognize(crops) }
        print("STAGE baberu: base \(Int(base)) peak \(Int(ocrPeak)) (+\(Int(ocrPeak - base)))")
        #expect(ocrPeak - base < 200)
        base = MemoryFootprint.megabytes()
        let (_, vPeak) = try await PipelineTests.peakFootprint { try await SystemOCR.recognize(crops, language: .japanese) }
        print("STAGE vision: base \(Int(base)) peak \(Int(vPeak)) (+\(Int(vPeak - base)))")
        base = MemoryFootprint.megabytes()
        let (_, inPeak) = try await PipelineTests.peakFootprint { try Inpainter.patch(for: page, regions: regions.map(\.text)) }
        print("STAGE inpaint: base \(Int(base)) peak \(Int(inPeak)) (+\(Int(inPeak - base))) after \(Int(MemoryFootprint.megabytes()))")
        #expect(inPeak - base < 200)

        // Heal brush: a 150×60 stroke with the editor's 128 px context window.
        let stroke = CGRect(x: 128, y: 128, width: 150, height: 60)
        let window = page.cropped(to: stroke.insetBy(dx: -128, dy: -128))
        let mask = [Bool](repeating: true, count: Int(stroke.width * stroke.height))
        base = MemoryFootprint.megabytes()
        let (_, healPeak) = try await PipelineTests.peakFootprint { try Inpainter.heal(window, rect: stroke, mask: mask) }
        print("STAGE heal: base \(Int(base)) peak \(Int(healPeak)) (+\(Int(healPeak - base)))")
        #expect(healPeak - base < 120)
    }
}
