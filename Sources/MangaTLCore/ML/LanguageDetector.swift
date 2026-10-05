import Foundation
import NaturalLanguage
import Vision

/// Works out which supported language most of a page's lettering is in ("Auto" source language).
///
/// The script decides most of it: kana means Japanese, Hangul Korean, Latin letters one of the
/// European languages. Vision with automatic language detection reads the text first; because it
/// often misreads vertical Japanese as kana-less Chinese characters, CJK pages are confirmed with
/// the manga OCR model, which reads kana reliably.
enum LanguageDetector {
    /// Text regions read for the guess; enough for a clear majority at bounded cost.
    static let sampleCount = 10

    static func detect(_ crops: [PixelBuffer]) async throws -> SourceLanguage? {
        let sample = Array(crops.prefix(sampleCount))
        guard !sample.isEmpty else { return nil }
        var text = ""
        for crop in sample {
            var request = RecognizeTextRequest()
            request.automaticallyDetectsLanguage = true
            request.recognitionLevel = .accurate
            let observations = try await request.perform(on: crop.makeImage())
            text += observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") + "\n"
        }
        let guess = language(of: text)
        guard guess == nil || guess!.usesMangaOCR else { return guess }
        // Japanese or Chinese (or nothing legible): read again with the manga model.
        let manga = try MangaOCR.recognize(sample).joined(separator: "\n")
        return language(of: manga) ?? guess
    }

    /// The supported language most of `text` is written in, nil when there is too little to tell.
    static func language(of text: String) -> SourceLanguage? {
        var kana = 0, hangul = 0, han = 0, latin = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D: kana += 1
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: hangul += 1
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: han += 1
            default: if scalar.properties.isAlphabetic, scalar.value < 0x250 { latin += 1 }
            }
        }
        let cjk = kana + han
        guard max(cjk, hangul, latin) >= 4 else { return nil }
        if hangul >= max(cjk, latin) { return .korean }
        if cjk >= latin {
            // Japanese always mixes in kana; Chinese has none.
            if kana >= 2 && Double(kana) >= 0.1 * Double(cjk) { return .japanese }
            return dominant(text, among: [.traditionalChinese: .chineseTraditional, .simplifiedChinese: .chineseSimplified]) ?? .chineseSimplified
        }
        return dominant(text, among: [.spanish: .spanish, .french: .french, .portuguese: .portuguese])
    }

    private static func dominant(_ text: String, among map: [NLLanguage: SourceLanguage]) -> SourceLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = Array(map.keys)
        recognizer.processString(text)
        return recognizer.dominantLanguage.flatMap { map[$0] }
    }
}
