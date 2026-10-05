import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import MangaTLCore

@Suite struct LanguageDetectorTests {
    @Test(arguments: [
        ("あれ、しまった。また窓を開けたまま寝ちゃったみたい", SourceLanguage.japanese),
        ("等一下，科魔那的市民们，请保留你们的掌声", .chineseSimplified),
        ("等一下，科魔那的市民們，請保留你們的掌聲，這是真的", .chineseTraditional),
        ("잠깐만요, 여러분 박수는 아껴두세요", .korean),
        ("Espera, ¿por qué puedes ver la ciudad desde aquí?", .spanish),
        ("Attends, pourquoi est-ce qu'on voit la ville d'ici ?", .french),
        ("Espera, por que você consegue ver a cidade daqui?", .portuguese),
    ])
    func identifiesTheScriptAndLanguage(text: String, expected: SourceLanguage) {
        #expect(LanguageDetector.language(of: text) == expected)
    }

    @Test func mostlyKoreanWithLatinSoundEffects() {
        #expect(LanguageDetector.language(of: "BANG! 잠깐만요 여러분 이것 좀 보세요 WOW") == .korean)
    }

    @Test func tooLittleTextIsUnknown() {
        #expect(LanguageDetector.language(of: "!? …") == nil)
    }
}

/// Real pages: detection runs on the detector's text regions, as in the pipeline.
@Suite(.serialized, .enabled(if: PipelineFixtures.available))
struct LanguageDetectorPageTests {
    @Test(arguments: [("ja_P01", SourceLanguage.japanese), ("fr_P01", .french), ("kr_P01", .korean), ("cn_P05", .chineseSimplified)])
    func identifiesSamplePage(name: String, expected: SourceLanguage) async throws {
        let url = PipelineFixtures.pages.appendingPathComponent("\(name).jpg")
        let image = try PageDecoder.decode(url: url, maxPixelSize: PagePipeline.workingMaxPixels)
        let page = PixelBuffer(image)
        let crops = PageLayout.regions(from: try TextDetector.detect(page), rightToLeft: false)
            .map { page.cropped(to: $0.text.insetBy(dx: -4, dy: -4)) }
        let found = try await LanguageDetector.detect(crops)
        print("LANGUAGE \(name): \(found?.rawValue ?? "none")")
        #expect(found == expected)
    }

    @Test func autoTranslatesAPageInItsOwnLanguage() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mangatl-auto-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: PipelineFixtures.pages.appendingPathComponent("ja_P01.jpg"), to: folder.appendingPathComponent("ja_P01.jpg"))
        let source = try ProjectSource(folder: folder)
        var settings = ProjectSettings(language: .korean)
        settings.autoLanguage = true
        let found = LockedBox<SourceLanguage?>(nil)
        let baseline = MemoryFootprint.megabytes()
        let (doc, peak) = try await PipelineTests.peakFootprint {
            try await PagePipeline.shared.process(source, index: 0, settings: settings, store: source.store) { _ in } detected: { found.set($0) }
        }
        print("AUTO ja_P01: \(found.value?.rawValue ?? "none"), footprint \(Int(baseline)) → peak \(Int(peak)) MB")
        // A Korean project setting must not stop a Japanese page being read as Japanese.
        #expect(found.value == .japanese)
        #expect(peak - baseline < 250, "auto language stage exceeded the app memory budget")
        #expect(doc.blocks.filter { !$0.translation.isEmpty }.count >= 3)
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func set(_ value: T) { lock.withLock { stored = value } }
}
