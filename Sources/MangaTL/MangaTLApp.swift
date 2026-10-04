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
    @State private var sheet: ProjectSheet?
    @State private var readerZoom: ReaderZoom = .column(ReaderLayout.defaultColumnWidth)
    @AppStorage("gridThumbnailSize") private var gridSize: Double = Double(ZoomControls.gridDefault)
    @AppStorage("pageSidebarVisible") private var sidebarPreferred = true
    @State private var columns: NavigationSplitViewVisibility = .detailOnly
    @State private var width: CGFloat = 1100
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
            .sheet(item: $sheet) { which in
                if let project {
                    switch which {
                    case .presets: PresetsView(project: project)
                    case .typesetCheck:
                        TypesetCheckView(project: project) { page, block in
                            edit(page)
                            editor?.tool = .select
                            editor?.selection = [block]
                        }
                    }
                }
            }
            .onChange(of: mode) { rememberState() }
            .onChange(of: readerZoom) { rememberState() }
            .onChange(of: editor?.index) { rememberState() }
            #if DEBUG || BENCH
            .task {
                if let path = ScrollBenchmark.bookPath {
                    open(URL(fileURLWithPath: path))
                    // The benchmark starts from the grid regardless of the saved position.
                    editor = nil
                    position.page = 0
                    mode = .grid
                    if project == nil { print("BENCH failed: couldn't open \(path): \(error ?? "unknown")") }
                    readerZoom = .column(ReaderLayout.defaultColumnWidth)
                    if let size = ProcessInfo.processInfo.environment["MANGATL_BENCH_GRID"].flatMap(Double.init) { gridSize = size }
                    await ScrollBenchmark.start {
                        position.page = 0
                        mode = .reader
                    }
                }
                if let path = SmokeRun.bookPath { await SmokeRun.run(in: self, path: path) }
            }
            #endif
    }

    /// Content pinned to the full window, status bar at the bottom, one toolbar.
    /// The page sidebar belongs to the reader and editor; the grid already shows every page.
    private var sidebarAvailable: Bool { project != nil && (editor != nil || mode == .reader) }

    private var framed: some View {
        NavigationSplitView(columnVisibility: $columns) {
            if let project, sidebarAvailable {
                PageSidebar(project: project, position: position, editorPage: editor?.index) { page in
                    if editor != nil {
                        edit(page)
                    } else {
                        position.page = page
                        position.jump = page
                    }
                }
                .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 260)
            } else {
                Color.clear.navigationSplitViewColumnWidth(0)
            }
        } detail: {
            detail
        }
        .onChange(of: columns) { _, new in if sidebarAvailable, width >= Self.sidebarMinWindowWidth { sidebarPreferred = new != .detailOnly } }
        .onChange(of: sidebarAvailable) { syncColumns() }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0; syncColumns() }
        .frame(minWidth: 820, minHeight: 560)
        .navigationTitle(project?.title ?? "MangaTL")
        .toolbar { toolbar }
        // Our own toggle (below) appears only where there is a sidebar; swapping the system one in
        // and out with a conditional modifier would rebuild the whole window's view tree.
        .toolbar(removing: .sidebarToggle)
    }

    static let sidebarMinWindowWidth: CGFloat = 980

    /// Shows the sidebar when it applies and the user wants it, collapsing it in narrow windows.
    private func syncColumns() {
        let show = sidebarAvailable && sidebarPreferred && width >= Self.sidebarMinWindowWidth
        let target: NavigationSplitViewVisibility = show ? .all : .detailOnly
        if columns != target { columns = target }
    }

    private var detail: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                StatusBar(project: project, position: project == nil ? nil : position, activity: editor?.busy ?? busy) {
                    if project != nil, editor == nil {
                        ZoomControls(mode: mode, gridSize: Binding(get: { CGFloat(gridSize) }, set: { gridSize = Double($0) }),
                                     readerZoom: $readerZoom, readerColumn: ReaderLayout.defaultColumnWidth)
                    }
                }
            }
    }

    @ViewBuilder private var content: some View {
        if let editor {
            EditorView(model: editor, inspectorPreferred: inspectorVisible)
                .id(editor.pageKey)
        } else if let project {
            PageCollectionView(project: project, mode: mode, showOriginal: showOriginal, position: position,
                               gridSize: CGFloat(gridSize), readerZoom: readerZoom) { page in
                position.page = page
                if mode == .grid { mode = .reader } else { edit(page) }
            } onEditPage: { page in
                edit(page)
            } onGridSize: { size in
                gridSize = Double(size)
            } onReaderZoom: { zoom in
                readerZoom = zoom
            }
            .id(ObjectIdentifier(project))
        } else {
            WelcomeView(recents: recents, onOpen: { open($0) }, onOpenFolder: { choosingFolder = true }, onImport: { importArchive() })
        }
    }

    private var sidebarToggle: some View {
        Button {
            sidebarPreferred.toggle()
            syncColumns()
        } label: {
            Label("Pages", systemImage: "sidebar.left")
        }
        .keyboardShortcut("s", modifiers: [.command, .control])
        .tip("Show or hide the page list", shortcut: "⌃⌘S")
    }

    private var shownError: String? { error ?? project?.lastError }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if let project, let editor {
            ToolbarItem(placement: .navigation) { sidebarToggle }
            EditorToolbar(model: editor, pageCount: project.count, inspectorVisible: $inspectorVisible,
                          onClose: closeEditor, onOpenPage: edit)
            ToolbarSpacer(.fixed)
            ToolbarItemGroup {
                LanguageMenu(project: project)
                TranslateMenu(project: project, position: position, editor: editor) { sheet = $0 }
            }
        } else if let project {
            ToolbarItem(placement: .navigation) {
                if sidebarAvailable { sidebarToggle }
            }
            ToolbarItem(placement: .navigation) {
                if mode == .reader {
                    Button { mode = .grid } label: { Label("All Pages", systemImage: "square.grid.3x3") }
                        .keyboardShortcut(.escape, modifiers: [])
                        .tip("Back to all pages (Esc)")
                }
            }
            ToolbarItem { LanguageMenu(project: project) }
            ToolbarSpacer(.fixed)
            ToolbarItemGroup {
                TranslateMenu(project: project, position: position) { sheet = $0 }
                Button { edit(position.page) } label: { Label("Edit Page", systemImage: "pencil.and.scribble") }
                    .keyboardShortcut("e")
                    .tip("Edit text, erase and retouch this page (⌘E, or double-click a page in the reader)")
                if mode == .reader {
                    Toggle(isOn: $showOriginal) { Label("Show Original", systemImage: "character.book.closed") }
                        .keyboardShortcut("o", modifiers: [.command, .option])
                        .tip("Show the original pages", shortcut: "⌥⌘O")
                }
            }
            ToolbarSpacer(.fixed)
            ToolbarItemGroup {
                Button { addImages() } label: { Label("Add Images", systemImage: "photo.badge.plus") }
                    .tip("Copy images into this project after the current page")
                Button { closeProject() } label: { Label("Close Project", systemImage: "xmark.circle") }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .tip("Save and go back to recent projects", shortcut: "⇧⌘W")
            }
        } else {
            ToolbarItemGroup {
                Button { choosingFolder = true } label: { Label("Open Folder", systemImage: "folder") }
                    .keyboardShortcut("o")
                    .tip("Open a folder of images as a project", shortcut: "⌘O")
                Button { importArchive() } label: { Label("Import CBZ / PDF", systemImage: "square.and.arrow.down") }
                    .tip("Extract a CBZ/ZIP or PDF into a new project folder")
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
            readerZoom = switch state.fit {
            case "width": .fitWidth
            case "height": .fitHeight
            default: .column(CGFloat(state.zoom ?? Double(ReaderLayout.defaultColumnWidth)))
            }
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
                try await BookExporter.export(source, store: nil, settings: ProjectSettings(), to: folder, format: .folder)
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
        project.close(state: currentState)
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
        project?.rememberState(currentState)
    }

    private var currentState: ProjectFile.State {
        var state = ProjectFile.State()
        state.page = editor?.index ?? position.page
        state.mode = editor != nil ? "editor" : (mode == .reader ? "reader" : "grid")
        switch readerZoom {
        case .column(let width): state.zoom = Double(width)
        case .fitWidth: state.fit = "width"
        case .fitHeight: state.fit = "height"
        }
        return state
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
    func show(_ which: ProjectSheet?) { sheet = which }
    func showGrid() { mode = .grid }
    func setGridSize(_ size: Double) { gridSize = size }
    func setReaderZoom(_ zoom: ReaderZoom) { readerZoom = zoom }
    func setSidebar(_ visible: Bool) { sidebarPreferred = visible; syncColumns() }
    #endif
}
