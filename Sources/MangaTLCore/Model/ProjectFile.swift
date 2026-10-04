import Foundation

/// One page of a project: a stable id (keys its translation and layers) and its image file,
/// relative to the project folder.
public struct PageRef: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var file: String

    public init(id: String = UUID().uuidString, file: String) {
        self.id = id
        self.file = file
    }
}

/// `<folder>/.mangatl/project.json`: everything needed to reopen a project as it was left.
/// Kept small on purpose; per-page work lives in `pages/` and `layers/`.
public struct ProjectFile: Codable, Equatable, Sendable {
    public struct State: Codable, Equatable, Sendable {
        public var page = 0
        /// "grid", "reader" or "editor".
        public var mode = "grid"
        /// Reader page width in points, or nil when fitted.
        public var zoom: Double?
        /// "width" or "height" when the reader is fitted to the window.
        public var fit: String?
        public init() {}
    }

    public var version = 1
    public var settings: ProjectSettings
    /// Reading order.
    public var pages: [PageRef]
    public var state = State()
    /// Last export settings, offered again next time.
    public var export: ExportOptions?
    public var updated = Date()

    public init(settings: ProjectSettings = ProjectSettings(), pages: [PageRef] = []) {
        self.settings = settings
        self.pages = pages
    }

    public static func load(from url: URL) -> ProjectFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ProjectFile.self, from: data)
    }

    public func save(to url: URL) throws {
        var copy = self
        copy.updated = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(copy).write(to: url, options: .atomic)
    }

    /// Matches `pages` to the image files actually in the folder: files that disappeared are
    /// dropped, new files are inserted after their predecessor in Finder order. Returns whether
    /// anything changed.
    @discardableResult
    public mutating func reconcile(with files: [String]) -> Bool {
        let present = Set(files)
        let before = pages
        pages.removeAll { !present.contains($0.file) }
        let known = Set(pages.map(\.file))
        // `files` is in natural order: put each new file right after the page that precedes it
        // there, so "page 12a.jpg" lands next to page 12 rather than at the end.
        var previous: String?
        for name in files {
            if !known.contains(name) {
                let at = previous.flatMap { p in pages.firstIndex { $0.file == p } }.map { $0 + 1 } ?? 0
                pages.insert(PageRef(file: name), at: at)
            }
            previous = name
        }
        return pages != before
    }
}
