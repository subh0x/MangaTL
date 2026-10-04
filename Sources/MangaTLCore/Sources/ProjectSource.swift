import CoreGraphics
import Foundation

/// A folder of images opened as a project. Reading order, settings and the last position live in
/// `<folder>/.mangatl/project.json`; image files are never renamed or deleted.
public final class ProjectSource: PageSource, @unchecked Sendable {
    public static let metadataFolder = ".mangatl"

    public let folder: URL
    public let id: String
    public let title: String
    public let store: ProjectStore
    private let lock = NSLock()
    private var file: ProjectFile

    public var projectFileURL: URL { folder.appendingPathComponent("\(Self.metadataFolder)/project.json") }

    /// Opens (or creates) the project in `folder`. A folder used before projects existed gets its
    /// old work copied in from Application Support.
    public init(folder: URL) throws {
        self.folder = folder.standardizedFileURL
        id = self.folder.path
        title = folder.lastPathComponent
        // List first: this throws for a missing folder instead of creating it below.
        let images = try Self.imageFiles(in: self.folder)
        // Pre-project builds keyed work by folder path + modification date; read it before
        // creating .mangatl changes that date.
        let legacy = ProjectStore.legacyDirectory(forSourceID: PageSources.identity(of: self.folder))
        let meta = self.folder.appendingPathComponent(Self.metadataFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        store = ProjectStore(directory: meta)

        let url = meta.appendingPathComponent("project.json")
        if var existing = ProjectFile.load(from: url) {
            if existing.reconcile(with: images) { try? existing.save(to: url) }
            file = existing
        } else {
            file = ProjectFile(pages: images.map { PageRef(file: $0) })
            if FileManager.default.fileExists(atPath: legacy.path),
               let settings = store.importLegacy(from: legacy, pageIDs: file.pages.map(\.id)) {
                file.settings = settings
            }
            try file.save(to: url)
        }
        guard !file.pages.isEmpty else { throw PageSourceError.empty(folder) }
    }

    static func imageFiles(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .map(\.lastPathComponent)
            .filter(PageSources.isImageName)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: PageSource

    public var count: Int { lock.withLock { file.pages.count } }
    public var pages: [PageRef] { lock.withLock { file.pages } }
    public func name(at index: Int) -> String { lock.withLock { file.pages[index].file } }
    public func pageKey(at index: Int) -> String { lock.withLock { file.pages[index].id } }

    public func cacheKey(at index: Int) -> String {
        let url = folder.appendingPathComponent(name(at: index))
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return "\(url.path)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? 0)"
    }

    public func image(at index: Int, maxPixelSize: Int) throws -> CGImage {
        try PageDecoder.decode(url: folder.appendingPathComponent(name(at: index)), maxPixelSize: maxPixelSize)
    }

    // MARK: Project file

    public var settings: ProjectSettings {
        get { lock.withLock { file.settings } }
        set { update { $0.settings = newValue } }
    }

    public var exportOptions: ExportOptions? {
        get { lock.withLock { file.export } }
        set { update { $0.export = newValue } }
    }

    public var state: ProjectFile.State {
        get { lock.withLock { file.state } }
        set { update { $0.state = newValue } }
    }

    private func update(_ body: (inout ProjectFile) -> Void) {
        let snapshot: ProjectFile = lock.withLock {
            body(&file)
            return file
        }
        try? snapshot.save(to: projectFileURL)
    }

    // MARK: Page management

    /// Copies images into the folder (renaming on clashes) and inserts them at `index`.
    @discardableResult
    public func insert(files urls: [URL], at index: Int) throws -> [PageRef] {
        var added: [PageRef] = []
        for url in urls where PageSources.isImageName(url.lastPathComponent) {
            var name = url.lastPathComponent
            if url.deletingLastPathComponent().standardizedFileURL != folder {
                name = Self.freeName(for: name, in: folder)
                try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(name))
            }
            if pages.contains(where: { $0.file == name }) { continue }
            added.append(PageRef(file: name))
        }
        update { file in file.pages.insert(contentsOf: added, at: min(max(0, index), file.pages.count)) }
        return added
    }

    /// Moves the pages at `offsets` so they start at `destination` (indices before the move).
    public func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        update { file in
            let moving = offsets.map { file.pages[$0] }
            let before = offsets.filter { $0 < destination }.count
            file.pages = file.pages.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
            file.pages.insert(contentsOf: moving, at: min(file.pages.count, destination - before))
        }
    }

    /// Takes pages out of the project. Their image files and translations stay on disk.
    public func remove(atOffsets offsets: IndexSet) {
        update { file in
            file.pages = file.pages.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        }
    }

    static func freeName(for name: String, in folder: URL) -> String {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = name, n = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
            candidate = "\(base) \(n).\(ext)"
            n += 1
        }
        return candidate
    }
}
