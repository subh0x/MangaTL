import Foundation
import Translation

/// On-device translation through Apple's Translation framework. One session per source
/// language is reused for 60 s and then dropped so `translationd` can exit and free its memory.
public actor Translator {
    public static let shared = Translator()
    private static let english = Locale.Language(identifier: "en")
    private var session: (language: SourceLanguage, session: TranslationSession)?
    private var lastUse = Date.distantPast

    public func translate(_ texts: [String], from language: SourceLanguage) async throws -> [String] {
        let indices = texts.indices.filter { !texts[$0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !indices.isEmpty else { return texts.map { _ in "" } }
        let session = try await session(for: language)
        let requests = indices.map { TranslationSession.Request(sourceText: Self.prepare(texts[$0], language), clientIdentifier: String($0)) }
        // TranslationSession isn't Sendable; this actor is its only user, one call at a time.
        nonisolated(unsafe) let unchecked = session
        let responses = try await unchecked.translations(from: requests)
        var out = texts.map { _ in "" }
        for response in responses {
            if let id = response.clientIdentifier.flatMap(Int.init) { out[id] = response.targetText }
        }
        lastUse = Date()
        scheduleRelease()
        return out
    }

    public static func isInstalled(_ language: SourceLanguage) async -> Bool {
        await LanguageAvailability().status(from: Locale.Language(identifier: language.rawValue), to: english) == .installed
    }

    private func session(for language: SourceLanguage) async throws -> TranslationSession {
        if let session, session.language == language { return session.session }
        guard await Self.isInstalled(language) else { throw PipelineError.translationUnavailable(language.displayName) }
        let new = TranslationSession(installedSource: Locale.Language(identifier: language.rawValue), target: Self.english)
        session = (language, new)
        return new
    }

    private func scheduleRelease() {
        Task {
            try? await Task.sleep(for: .seconds(61))
            if Date().timeIntervalSince(lastUse) >= 60 { session = nil }
        }
    }

    /// OCR keeps manga line breaks; CJK needs them removed, Latin text needs them as spaces.
    static func prepare(_ text: String, _ language: SourceLanguage) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        return language.usesMangaOCR ? lines.joined() : lines.joined(separator: " ")
    }
}
