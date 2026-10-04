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
    private(set) var lastError: String?
    /// Set when translation finishes a page, so an open editor can reload it.
    private(set) var lastTranslated: (page: String, token: Int)?
    @ObservationIgnored var onPageChanged: (Int) -> Void = { _ in }
    @ObservationIgnored var onPagesReordered: () -> Void = {}
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var stateWrite: Task<Void, Never>?

    init(folder: URL) throws {
        source = try ProjectSource(folder: folder)
        cache = ThumbnailCache(source: source)
        pages = source.pages
        settings = source.settings
        if settings.style.fontName == TextStyle.previousDefaultFontName { settings.style.fontName = TextStyle.defaultFontName }
        source.store.registerFonts()
    }

    var title: String { source.title }
    var count: Int { pages.count }
    var isTranslating: Bool { worker != nil }
    func pageKey(_ index: Int) -> String { pages[index].id }
    func isTranslated(_ index: Int) -> Bool { index < pages.count && store.hasPage(pages[index].id) }
    var translatedCount: Int { pages.filter { store.hasPage($0.id) }.count }

    // MARK: Translation

    func translate(pages indices: [Int], redo: Bool = false) {
        cancel()
        // Work by page id: the order may change while the queue runs.
        let todo = indices.filter { $0 < pages.count && (redo || !isTranslated($0)) }.map { pages[$0].id }
        guard !todo.isEmpty else { return }
        lastError = nil
        let (source, store, settings) = (source, store, settings)
        worker = Task {
            for (n, key) in todo.enumerated() {
                guard let index = pages.firstIndex(where: { $0.id == key }) else { continue }
                progress = (n, todo.count, index, PagePipeline.Stage.detecting.rawValue)
                do {
                    _ = try await PagePipeline.shared.process(source, index: index, settings: settings, store: store) { stage in
                        Task { @MainActor in
                            if let p = self.progress, p.page == index { self.progress = (p.done, p.total, index, stage.rawValue) }
                        }
                    }
                    lastTranslated = (key, (lastTranslated?.token ?? 0) + 1)
                    pageChanged(index)
                } catch is CancellationError {
                    break
                } catch {
                    lastError = error.localizedDescription
                    // Missing models / language packs fail every page alike: stop instead of repeating it.
                    if error is PipelineError { break }
                }
                if Task.isCancelled { break }
            }
            progress = nil
            worker = nil
        }
    }

    func export(to url: URL, format: BookExporter.Format) {
        cancel()
        lastError = nil
        let (source, store, style) = (source, store, settings.style)
        worker = Task {
            do {
                try await BookExporter.export(source, store: store, style: style, to: url, format: format) { done, total in
                    Task { @MainActor in if self.worker != nil { self.progress = (done, total, min(done, total - 1), "Exporting") } }
                }
            } catch is CancellationError {
            } catch {
                lastError = "Export failed: \(error.localizedDescription)"
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

    func pageChanged(_ index: Int) { onPageChanged(index) }

    func dismissError() { lastError = nil }

    // MARK: Pages

    /// Copies images into the project folder and inserts them at `index`.
    func addImages(_ urls: [URL], at index: Int) {
        do {
            try source.insert(files: urls, at: index)
            pagesChanged()
        } catch {
            lastError = "Couldn't add images: \(error.localizedDescription)"
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
        onPagesReordered()
    }

    // MARK: State

    /// Remembers where the user is; written at most once a second.
    func rememberState(page: Int, mode: String) {
        stateWrite?.cancel()
        stateWrite = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            var state = ProjectFile.State()
            state.page = page
            state.mode = mode
            source.state = state
        }
    }

    func close(page: Int, mode: String) {
        cancel()
        stateWrite?.cancel()
        var state = ProjectFile.State()
        state.page = page
        state.mode = mode
        source.state = state
    }
}
