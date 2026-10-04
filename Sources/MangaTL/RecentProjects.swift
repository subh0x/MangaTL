import Foundation
import Observation

/// Recently opened project folders, newest first (like an editor's "Open Recent").
/// Stored in UserDefaults; each project's own state lives in its `.mangatl` folder.
@MainActor @Observable
final class RecentProjects {
    struct Entry: Codable, Identifiable, Equatable {
        var path: String
        var title: String
        var pages: Int
        var translated: Int
        var cover: String?
        var opened: Date
        var id: String { path }
        var url: URL { URL(fileURLWithPath: path) }
        var exists: Bool { FileManager.default.fileExists(atPath: path) }
    }

    static let shared = RecentProjects()
    private static let key = "recentProjects"
    private static let limit = 20

    private(set) var entries: [Entry]

    private init() {
        let data = UserDefaults.standard.data(forKey: Self.key)
        entries = data.flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    func note(_ project: ProjectSession) {
        let entry = Entry(path: project.source.folder.path, title: project.title, pages: project.count,
                          translated: project.translatedCount, cover: project.pages.first?.file, opened: Date())
        entries.removeAll { $0.path == entry.path }
        entries.insert(entry, at: 0)
        entries = Array(entries.prefix(Self.limit))
        persist()
    }

    func remove(_ entry: Entry) {
        entries.removeAll { $0.path == entry.path }
        persist()
    }

    func clear() {
        entries = []
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(entries), forKey: Self.key)
    }
}
