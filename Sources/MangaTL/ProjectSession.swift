import AppKit
import Foundation
import MangaTLCore
import Observation

/// One open project: its pages (in project order), thumbnails, saved work and the translation queue.
@MainActor @Observable
final class ProjectSession {
    let source: ProjectSource
    let cache: ThumbnailCache
    var store: ProjectStore { source.store }

    var settings: ProjectSettings {
        didSet { source.settings = settings }
    }
    /// Mirrors the project's page order so views update when pages are added or moved.
    private(set) var pages: [PageRef]

    /// Queue progress, nil when idle.
    private(set) var progress: (done: Int, total: Int, page: Int, stage: String)?
    /// Failures and warnings shown in the Problems panel, oldest first.
    private(set) var problems: [Problem] = []
    /// Ids of pages with saved work (translated or edited); observed by the sidebar and grid.
    private(set) var translatedIDs: Set<String> = []
    /// Set when translation finishes a page, so an open editor can reload it.
    private(set) var lastTranslated: (page: String, token: Int)?
    /// Views that re-render pages; held weakly (SwiftUI may create and discard several).
    @ObservationIgnored private var observers: [PageObserver] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var stateWrite: Task<Void, Never>?
    /// Detected language per page id, read from the page docs on demand (nil = none detected).
    @ObservationIgnored private var detectedLanguages: [String: SourceLanguage?] = [:]
    /// Bumped when a page's detected language may have changed, so the language menu updates.
    private(set) var detectedLanguagesVersion = 0
    @ObservationIgnored private var folderWatch: DispatchSourceFileSystemObject?
    @ObservationIgnored private var rescan: Task<Void, Never>?

    init(folder: URL) throws {
        source = try ProjectSource(folder: folder)
        cache = ThumbnailCache(source: source)
        pages = source.pages
        settings = source.settings
        if settings.style.fontName == TextStyle.previousDefaultFontName { settings.style.fontName = TextStyle.defaultFontName }
        source.store.registerFonts()
        translatedIDs = Set(pages.lazy.map(\.id).filter(source.store.hasPage))
        watchFolder()
    }

    var title: String { source.title }
    var count: Int { pages.count }
    var isTranslating: Bool { worker != nil }
    func pageKey(_ index: Int) -> String { pages[index].id }
    func isTranslated(_ index: Int) -> Bool { index < pages.count && translatedIDs.contains(pages[index].id) }
    var translatedCount: Int { translatedIDs.count }

    // MARK: Translation

    func translate(pages indices: [Int], redo: Bool = false) {
        // Work by page id: the order may change while the queue runs.
        translate(keys: indices.filter { $0 < pages.count && (redo || !isTranslated($0)) }.map { pages[$0].id })
    }

    /// Translates one page again; an open editor saves its edits first (its own layers are kept).
    func translatePage(_ index: Int, saving editor: EditorModel?) {
        if let editor, editor.dirty { editor.save() }
        translate(pages: [index], redo: true)
    }

    private func translate(keys todo: [String]) {
        cancel()
        guard !todo.isEmpty else { return }
        resolve(Self.translateStopped)
        let (source, store, settings) = (source, store, settings)
        worker = Task {
            for (n, key) in todo.enumerated() {
                guard let index = pages.firstIndex(where: { $0.id == key }) else { continue }
                progress = (n, todo.count, index, PagePipeline.Stage.detecting.rawValue)
                do {
                    let doc = try await PagePipeline.shared.process(source, index: index, settings: settings, store: store) { stage in
                        Task { @MainActor in
                            if let p = self.progress, p.page == index { self.progress = (p.done, p.total, index, stage.rawValue) }
                        }
                    } detected: { language in
                        Task { @MainActor in self.adoptDetectedLanguage(language) }
                    }
                    lastTranslated = (key, (lastTranslated?.token ?? 0) + 1)
                    pageChanged(index)
                    resolve("Translate", page: key)
                    if doc.blocks.isEmpty {
                        report("Translate", page: key, "No text was found on this page. Use the Lasso tool in the editor to mark text the app missed.",
                               severity: .warning) { [weak self] in self?.translate(keys: [key]) }
                    }
                } catch is CancellationError {
                    break
                } catch let error as PipelineError {
                    // Missing models / language packs fail every page alike: stop instead of repeating it.
                    let remaining = Array(todo[n...])
                    report(Self.translateStopped, "Translation stopped: \(error.localizedDescription)") { [weak self] in
                        self?.translate(keys: remaining)
                    }
                    break
                } catch {
                    report("Translate", page: key, error.localizedDescription) { [weak self] in self?.translate(keys: [key]) }
                }
                if Task.isCancelled { break }
            }
            progress = nil
            worker = nil
        }
    }

    private static let translateStopped = "Translate Pages"

    /// The language Auto identified for a page when it was translated, if any.
    func detectedLanguage(ofPage index: Int) -> SourceLanguage? {
        _ = detectedLanguagesVersion
        guard index >= 0, index < pages.count else { return nil }
        let id = pages[index].id
        if let known = detectedLanguages[id] { return known }
        let found = translatedIDs.contains(id) ? store.loadPage(id)?.detectedLanguage : nil
        detectedLanguages[id] = .some(found)
        return found
    }

    /// Auto language: follow what the last translated page was written in.
    private func adoptDetectedLanguage(_ language: SourceLanguage) {
        guard settings.autoLanguage == true, settings.language != language else { return }
        settings.language = language
        settings.rightToLeft = language.defaultRightToLeft
    }

    /// Pages selected in the grid (for "Export Selected").
    var gridSelection: [Int] = []

    /// Exports `pages` (nil = all) and remembers `options` for next time.
    func export(pages: [Int]?, options: ExportOptions, to url: URL) {
        cancel()
        resolve("Export")
        source.exportOptions = options
        let (source, store, settings, title) = (source, store, settings, title)
        worker = Task {
            do {
                try await BookExporter.export(source, store: store, settings: settings, pages: pages, options: options, title: title,
                                              to: url) { done, total in
                    Task { @MainActor in if self.worker != nil { self.progress = (done, total, min(done, total - 1), "Exporting") } }
                }
                if options.revealInFinder { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } catch is CancellationError {
            } catch {
                report("Export", "Export to \(url.lastPathComponent) failed: \(error.localizedDescription)") { [weak self] in
                    self?.export(pages: pages, options: options, to: url)
                }
            }
            progress = nil
            worker = nil
        }
    }

    func cancel() {
        worker?.cancel()
        worker = nil
        progress = nil
    }

    func revert(page index: Int) {
        guard index < pages.count else { return }
        store.deletePage(pages[index].id)
        pageChanged(index)
    }

    func pageChanged(_ index: Int) {
        if index < pages.count {
            let id = pages[index].id
            if store.hasPage(id) { translatedIDs.insert(id) } else { translatedIDs.remove(id) }
            detectedLanguages[id] = nil
            detectedLanguagesVersion += 1
        }
        liveObservers.forEach { $0.pageChanged(index) }
    }

    /// Presets changed: every page's lettering may look different.
    func stylesChanged() { liveObservers.forEach { $0.pagesChanged() } }

    func addObserver(_ owner: AnyObject, pageChanged: @escaping (Int) -> Void, pagesChanged: @escaping () -> Void) {
        observers.removeAll { $0.owner == nil || $0.owner === owner }
        observers.append(PageObserver(owner: owner, pageChanged: pageChanged, pagesChanged: pagesChanged))
    }

    private var liveObservers: [PageObserver] {
        observers.removeAll { $0.owner == nil }
        return observers
    }

    // MARK: Problems

    /// Records a failure (or warning) for the Problems panel. A newer problem for the same operation
    /// and page replaces the older one; `retry` repeats the operation.
    func report(_ operation: String, page: String? = nil, _ message: String, severity: Problem.Severity = .error,
                retry: (@MainActor () -> Void)? = nil) {
        problems.removeAll { $0.operation == operation && $0.pageID == page }
        problems.append(Problem(severity: severity, operation: operation, pageID: page, message: message, retry: retry))
    }

    /// The operation succeeded: drops its problem.
    func resolve(_ operation: String, page: String? = nil) {
        problems.removeAll { $0.operation == operation && $0.pageID == page }
    }

    func retry(_ problem: Problem) {
        dismiss(problem)
        problem.retry?()
    }

    func dismiss(_ problem: Problem) { problems.removeAll { $0.id == problem.id } }

    func clearProblems() { problems = [] }

    /// Page number (0-based) of a problem's page, if it is still in the project.
    func index(of pageID: String) -> Int? { pages.firstIndex { $0.id == pageID } }

    // MARK: Pages

    /// Copies images into the project folder and inserts them at `index`.
    func addImages(_ urls: [URL], at index: Int) {
        do {
            try source.insert(files: urls, at: index)
            pagesChanged()
            resolve("Add Images")
        } catch {
            report("Add Images", "Couldn't add images: \(error.localizedDescription)") { [weak self] in self?.addImages(urls, at: index) }
        }
    }

    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        source.move(fromOffsets: offsets, toOffset: destination)
        pagesChanged()
    }

    /// Takes pages out of the project (files stay in the folder). The last page can't be removed.
    func remove(atOffsets offsets: IndexSet) {
        guard offsets.count < pages.count else { return }
        source.remove(atOffsets: offsets)
        pagesChanged()
    }

    private func pagesChanged() {
        pages = source.pages
        translatedIDs = Set(pages.lazy.map(\.id).filter(store.hasPage))
        liveObservers.forEach { $0.pagesChanged() }
    }

    /// Picks up images added to (or removed from) the folder outside the app. A directory's own
    /// write events fire when entries are added, removed or renamed; saves inside `.mangatl` and
    /// in-place edits of an image don't, so our own writes don't trigger a rescan.
    private func watchFolder() {
        let fd = open(source.folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        watch.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRescan() }
        }
        watch.setCancelHandler { Darwin.close(fd) }
        watch.resume()
        folderWatch = watch
    }

    /// Batches bursts of events (a Finder copy of many files) into one rescan.
    private func scheduleRescan() {
        rescan?.cancel()
        rescan = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            rescanFolder()
        }
    }

    func rescanFolder() {
        do {
            if try source.rescan() { pagesChanged() }
            resolve("Folder")
        } catch {
            report("Folder", "Couldn't read the project folder: \(error.localizedDescription)") { [weak self] in self?.rescanFolder() }
        }
    }

    // MARK: State

    /// Remembers where the user is (page, mode, zoom); written at most once a second.
    func rememberState(_ state: ProjectFile.State) {
        stateWrite?.cancel()
        stateWrite = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            source.state = state
        }
    }

    func close(state: ProjectFile.State) {
        cancel()
        folderWatch?.cancel()
        folderWatch = nil
        rescan?.cancel()
        stateWrite?.cancel()
        source.state = state
    }
}

/// Something that failed or needs attention, shown in the Problems panel.
struct Problem: Identifiable {
    enum Severity { case error, warning }
    let id = UUID()
    let date = Date()
    var severity: Severity
    /// What was being done ("Translate", "Export", "Heal"…); with `pageID`, identifies the problem.
    var operation: String
    var pageID: String?
    var message: String
    var retry: (@MainActor () -> Void)?
}

/// A weakly held view that re-renders when pages change.
struct PageObserver {
    weak var owner: AnyObject?
    let pageChanged: (Int) -> Void
    let pagesChanged: () -> Void
}
