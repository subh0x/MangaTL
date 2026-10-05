import CoreGraphics
import Foundation

/// Detect → OCR → translate → erase for one page at a time. Being an actor serialises pages, and
/// every model stage opens and closes its own ONNX session, so at most one model is resident.
public actor PagePipeline {
    public static let shared = PagePipeline()
    /// Longest side the pipeline works at; also the patch layer's resolution.
    public static let workingMaxPixels = 2400

    public enum Stage: String, Sendable {
        case detecting = "Finding text", identifying = "Identifying language", reading = "Reading", translating = "Translating", erasing = "Erasing"
    }

    /// With `settings.autoLanguage`, the page's language is identified from its text first and used
    /// for reading, reading order and translation; `detected` receives it.
    public func process(_ source: any PageSource, index: Int, settings: ProjectSettings, store: ProjectStore,
                        progress: @Sendable (Stage) -> Void = { _ in },
                        detected: @Sendable (SourceLanguage) -> Void = { _ in }) async throws -> PageDoc {
        var settings = settings
        let page = PixelBuffer(try source.image(at: index, maxPixelSize: Self.workingMaxPixels))
        let size = page.size

        progress(.detecting)
        let detections = try TextDetector.detect(page)
        try Task.checkCancellation()
        if settings.autoLanguage == true {
            progress(.identifying)
            let sample = PageLayout.regions(from: detections, rightToLeft: settings.rightToLeft)
                .map { page.cropped(to: $0.text.insetBy(dx: -4, dy: -4)) }
            if let language = try await LanguageDetector.detect(sample) {
                settings.language = language
                settings.rightToLeft = language.defaultRightToLeft
                detected(language)
            }
            try Task.checkCancellation()
        }
        let regions = PageLayout.regions(from: detections, rightToLeft: settings.rightToLeft)

        progress(.reading)
        let crops = regions.map { page.cropped(to: $0.text.insetBy(dx: -4, dy: -4)) }
        let texts = settings.language.usesMangaOCR
            ? try MangaOCR.recognize(crops)
            : try await SystemOCR.recognize(crops, language: settings.language)
        try Task.checkCancellation()

        // Drop regions where nothing legible was read: they are not erased either.
        let kept = zip(regions, texts).filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).isEmpty }

        progress(.translating)
        let translations = try await Translator.shared.translate(kept.map(\.1), from: settings.language)
        try Task.checkCancellation()

        progress(.erasing)
        let patch = try Inpainter.patch(for: page, regions: kept.map(\.0.text))

        let blocks = zip(kept, translations).map { pair, translation in
            let (region, text) = pair
            let layout = region.bubble ?? region.text
            var block = TextBlock(textRect: region.text.normalized(in: size), layoutRect: layout.normalized(in: size),
                                  shape: region.bubble.map { Self.shape(of: $0, in: page) } ?? .rectangle,
                                  sourceText: text, translation: translation)
            let role = Self.guessRole(source: text, translation: translation, inBubble: region.bubble != nil)
            block.role = role == .dialogue ? nil : role
            return block
        }
        // Translating again replaces the text and the clean-up layer; the user's own layers stay.
        let key = source.pageKey(at: index)
        var doc = PageDoc(blocks: blocks, workingSize: size)
        if let bounds = patch.opaqueBounds() {
            let layer = ImageLayer(name: "Text Clean-up", rect: bounds, kind: .cleanup)
            try store.saveLayer(patch.cropped(to: bounds).makeImage(), page: key, id: layer.id)
            doc.layers = [layer]
        }
        if let previous = store.loadPage(key), previous.workingSize == size {
            doc.layers += previous.layers.filter { $0.kind != ImageLayer.Kind.cleanup }
        }
        store.pruneLayers(page: key, keeping: doc)
        try store.save(doc, page: key)
        return doc
    }

    /// Reads the text inside `rect` (page pixels) again, e.g. after the user resized a box.
    public func reread(_ page: PixelBuffer, rect: CGRect, language: SourceLanguage) async throws -> String {
        let crop = page.cropped(to: rect.insetBy(dx: -4, dy: -4))
        return language.usesMangaOCR
            ? try MangaOCR.recognize([crop]).first ?? ""
            : try await SystemOCR.recognize([crop], language: language).first ?? ""
    }

    /// Pixels of surrounding context to pass to `heal` around a stroke.
    public static let healContext = 128

    /// Inpaints the masked pixels of `rect` with AOT ("heal" brush). `mask` is rect-sized, row-major.
    /// Returns a rect-sized buffer: healed pixels opaque, everything else transparent.
    public func heal(_ page: PixelBuffer, rect: CGRect, mask: [Bool]) throws -> PixelBuffer {
        try Inpainter.heal(page, rect: rect, mask: mask)
    }

    /// Erases the lettering inside a lasso outline (`area` is rect-sized, row-major, true = inside).
    /// Returns a rect-sized buffer: erased pixels opaque, everything else transparent.
    public func erase(_ page: PixelBuffer, rect: CGRect, area: [Bool]) throws -> PixelBuffer {
        try Inpainter.erase(page, rect: rect, area: area)
    }

    /// A first guess at what kind of lettering a block is; the user can change it in the editor.
    public static func guessRole(source: String, translation: String, inBubble: Bool) -> TextRole {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let exclamations = trimmed.filter { $0 == "!" || $0 == "！" }.count
        if !inBubble {
            // Short text loose on the art is a sound effect; longer text is narration/captions.
            let letters = trimmed.filter { $0.isLetter }.count
            return letters <= 4 && translation.split(whereSeparator: \.isWhitespace).count <= 2 ? .sfx : .narration
        }
        if let first = trimmed.first, "(（".contains(first) { return .thought }
        let latin = translation.filter { $0.isLetter }
        if exclamations >= 2 || (latin.count >= 4 && latin == latin.uppercased() && exclamations >= 1) { return .shout }
        return .dialogue
    }

    /// A balloon whose box corners are the same colour as its centre is rectangular (captions);
    /// otherwise the corners are outside the balloon and it is treated as an ellipse.
    static func shape(of bubble: CGRect, in page: PixelBuffer) -> BlockShape {
        let luma = { (p: CGPoint) -> Int in
            let x = min(page.width - 1, max(0, Int(p.x))), y = min(page.height - 1, max(0, Int(p.y)))
            let i = (y * page.width + x) * 4
            return (299 * Int(page.bytes[i]) + 587 * Int(page.bytes[i + 1]) + 114 * Int(page.bytes[i + 2])) / 1000
        }
        let inset = bubble.insetBy(dx: bubble.width * 0.04, dy: bubble.height * 0.04)
        let corners = [CGPoint(x: inset.minX, y: inset.minY), CGPoint(x: inset.maxX, y: inset.minY),
                       CGPoint(x: inset.minX, y: inset.maxY), CGPoint(x: inset.maxX, y: inset.maxY)]
        // Sample just inside the top edge as the balloon's paper colour (centre has text).
        let paper = luma(CGPoint(x: bubble.midX, y: bubble.minY + bubble.height * 0.08))
        let matching = corners.filter { abs(luma($0) - paper) < 24 }.count
        return matching >= 3 ? .rectangle : .ellipse
    }
}
