import CoreGraphics
import Foundation
import Vision

/// Apple Vision text recognition for Korean and Latin-script pages (Phase 0: accurate on both,
/// ~90 MB process footprint, no bundled model).
enum SystemOCR {
    static func recognize(_ crops: [PixelBuffer], language: SourceLanguage) async throws -> [String] {
        var results: [String] = []
        for crop in crops {
            var request = RecognizeTextRequest()
            request.recognitionLanguages = [Locale.Language(identifier: language.rawValue)]
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let observations = try await request.perform(on: crop.makeImage())
            // Vision returns lines bottom-to-top in normalised (bottom-left) space; read top-down.
            let lines = observations
                .sorted { $0.boundingBox.origin.y > $1.boundingBox.origin.y }
                .compactMap { $0.topCandidates(1).first?.string }
            results.append(joinLines(lines))
        }
        return results
    }

    /// Joins wrapped lines into one sentence, re-gluing words hyphenated across a line break.
    static func joinLines(_ lines: [String]) -> String {
        var text = ""
        for line in lines.map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
            if text.hasSuffix("-"), let first = line.first, first.isLowercase {
                text.removeLast()
                text += line
            } else {
                text += text.isEmpty ? line : " " + line
            }
        }
        return text
    }
}
