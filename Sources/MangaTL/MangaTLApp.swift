import AppKit
import MangaTLCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct MangaTLApp: App {
    init() {
        Self.ensureSpaceEfficientMalloc()
        Task.detached(priority: .background) { ThumbnailCache.trimDisk() }
    }

    /// macOS malloc keeps freed model buffers resident (and counted) unless this is set at launch;
    /// with it, each pipeline stage returns to ~15 MB after its session closes (Phase 0 follow-up).
    /// `LSEnvironment` covers Finder launches; this covers running the binary directly.
    private static func ensureSpaceEfficientMalloc() {
        guard getenv("MallocSpaceEfficient") == nil else { return }
        setenv("MallocSpaceEfficient", "1", 1)
        let args = CommandLine.unsafeArgv
        execv(args[0]!, args)
        // execv only returns on failure; carry on with the default allocator.
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1100, height: 800)
    }
}


/// The window: Welcome (recent projects) until a project is open, then its pages in grid,
/// reader or editor mode. One window toolbar and one status bar serve every mode.
struct ContentView: View {
    @State private var project: ProjectSession?
    @State private var mode: PageLayoutMode = .grid
    @State private var editor: EditorModel?
    @State private var position = ReadingPosition()
    @State private var showOriginal = false
    @State private var choosingFolder = false
    @State private var error: String?
    @State private var busy: String?
    @AppStorage("editorInspectorVisible") private var inspectorVisible = true
    private let recents = RecentProjects.shared

    var body: some View {
        framed
            .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { open(url) }
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                // Folders or archives open/import; image files dropped on the grid are handled there.
                guard project == nil else { return false }
                _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in openOrImport(url) } }
                }
                return true
            }
            .alert("MangaTL", isPresented: .constant(shownError != nil), presenting: shownError) { _ in
                Button("OK") { error = nil; project?.dismissError() }
            } message: { Text($0) }
            .onChange(of: project?.lastTranslated?.token) { reloadEditorIfTranslated() }
            .onChange(of: mode) { rememberState() }
            .onChange(of: editor?.index) { rememberState() }
            #if DEBUG || BENCH
            .task {
                if let path = ScrollBenchmark.bookPath {
                    open(URL(fileURLWithPath: path))
                    // The benchmark starts from the grid regardless of the saved position.
                    position.page = 0
                    mode = .grid
                }
                if let path = SmokeRun.bookPath { await SmokeRun.run(in: self, path: path) }
            }
            #endif
    }

    /// Content pinned to the full window, status bar at the bottom, one toolbar.
    private var framed: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                StatusBar(project: project, position: project == nil ? nil : position, activity: editor?.busy ?? busy)
            }
            .frame(minWidth: 820, minHeight: 560)
            .navigationTitle(project?.title ?? "MangaTL")
            .toolbar { toolbar }
    }

    @ViewBuilder private var content: some View {
        if let editor {
            EditorView(model: editor, inspectorPreferred: inspectorVisible)
                .id(editor.pageKey)
        } else if let project {
            PageCollectionView(project: project, mode: mode, showOriginal: showOriginal, position: position) { page in
                position.page = page
                if mode == .grid { mode = .reader } else { edit(page) }
            } onEditPage: { page in
                edit(page)
            }
            .id(ObjectIdentifier(project))
        } else {
            WelcomeView(recents: recents, onOpen: { open($0) }, onOpenFolder: { choosingFolder = true }, onImport: { importArchive() })
        }
    }

    private var shownError: String? { error ?? project?.lastError }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if let project, let editor {
            EditorToolbar(model: editor, pageCount: project.count, inspectorVisible: $inspectorVisible,
                          onClose: closeEditor, onOpenPage: edit)
            ToolbarSpacer(.fixed)
            ToolbarItemGroup {
                LanguageMenu(project: project)
                TranslateMenu(project: project, position: position, editor: editor)
            }
        } else if let project {
            ToolbarItem(placement: .navigation) {
                if mode == .reader {
                    Button { mode = .grid } label: { Label("All Pages", systemImage: "square.grid.3x3") }
                        .keyboardShortcut(.escape, modifiers: [])
                        .help("Back to all pages (Esc)")
                }
            }
            ToolbarItem { LanguageMenu(project: project) }
            ToolbarSpacer(.fixed)
            ToolbarItemGroup {
                TranslateMenu(project: project, position: position)
                Button { edit(position.page) } label: { Label("Edit Page", systemImage: "pencil.and.scribble") }
                    .keyboardShortcut("e")
                    .help("Edit text, erase and retouch this page (⌘E, or double-click a page in the reader)")
                if mode == .reader {
                    Toggle(isOn: $showOriginal) { Label("Show Original", systemImage: "character.book.closed") }
                        .keyboardShortcut("o", modifiers: [.command, .option])
                        .help("Show the original pages (⌥⌘O)")
                }
            }
            ToolbarSpacer(.fixed)
            ToolbarItemGroup {
                Button { addImages() } label: { Label("Add Images", systemImage: "photo.badge.plus") }
                    .help("Copy images into this project after the current page")
                Button { closeProject() } label: { Label("Close Project", systemImage: "xmark.circle") }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .help("Save and go back to recent projects (⇧⌘W)")
            }
        } else {
            ToolbarItemGroup {
                Button { choosingFolder = true } label: { Label("Open Folder", systemImage: "folder") }
                    .keyboardShortcut("o")
                    .help("Open a folder of images as a project (⌘O)")
                Button { importArchive() } label: { Label("Import CBZ / PDF", systemImage: "square.and.arrow.down") }
                    .help("Extract a CBZ/ZIP or PDF into a new project folder")
            }
        }
    }

    // MARK: Projects

    func open(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            closeProject()
            let session = try ProjectSession(folder: url)
            let state = session.source.state
            position.page = min(state.page, session.count - 1)
            mode = state.mode == "reader" ? .reader : .grid
            project = session
            recents.note(session)
            if state.mode == "editor" { edit(position.page) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func openOrImport(_ url: URL) {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            open(url)
        } else {
            importArchive(url)
        }
    }

    /// Extracts a CBZ/ZIP/PDF into a new folder next to it (or wherever the user picks) and opens it.
    private func importArchive(_ chosen: URL? = nil) {
        var archive = chosen
        if archive == nil {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.zip, .pdf] + [UTType(filenameExtension: "cbz")].compactMap { $0 }
            panel.message = "Choose a CBZ/ZIP or PDF to turn into a project folder."
            guard panel.runModal() == .OK else { return }
            archive = panel.url
        }
        guard let archive else { return }
        let save = NSSavePanel()
        save.directoryURL = archive.deletingLastPathComponent()
        save.nameFieldStringValue = archive.deletingPathExtension().lastPathComponent
        save.prompt = "Create Project"
        save.message = "The pages are extracted into this new folder, which becomes the project."
        guard save.runModal() == .OK, let folder = save.url else { return }
        busy = "Importing \(archive.lastPathComponent)…"
        Task {
            do {
                let source = try PageSources.open(archive)
                try await BookExporter.export(source, store: nil, style: TextStyle(), to: folder, format: .folder)
                busy = nil
                open(folder)
            } catch {
                busy = nil
                self.error = "Couldn't import \(archive.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    func closeProject() {
        guard let project else { return }
        if let editor, editor.dirty { editor.save() }
        project.close(page: editor?.index ?? position.page, mode: editor != nil ? "editor" : (mode == .reader ? "reader" : "grid"))
        recents.note(project)
        editor = nil
        self.project = nil
    }

    private func addImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.prompt = "Add"
        panel.message = "The images are copied into the project folder after the current page."
        if panel.runModal() == .OK { project?.addImages(panel.urls, at: position.page + 1) }
    }

    private func rememberState() {
        guard let project else { return }
        project.rememberState(page: editor?.index ?? position.page, mode: editor != nil ? "editor" : (mode == .reader ? "reader" : "grid"))
    }

    // MARK: Editor

    /// Opens (or switches the editor to) `page`, saving the page being edited first.
    func edit(_ page: Int) {
        guard let project, page >= 0, page < project.count else { return }
        project.cancel()
        if let editor, editor.dirty { editor.save() }
        do {
            editor = try EditorModel(project: project, index: page)
            position.page = page
        } catch {
            self.error = error.localizedDescription
        }
    }

    func closeEditor() {
        if let editor, editor.dirty { editor.save() }
        editor = nil
    }

    /// Translation finished for the page being edited: show the new text and clean-up layer.
    private func reloadEditorIfTranslated() {
        guard let project, let editor, let done = project.lastTranslated, done.page == editor.pageKey else { return }
        self.editor = try? EditorModel(project: project, index: editor.index)
    }

    #if DEBUG || BENCH
    /// Hooks for the debug smoke run.
    var currentEditor: EditorModel? { editor }
    var currentProject: ProjectSession? { project }
    func showReader() { mode = .reader }
    #endif
}
