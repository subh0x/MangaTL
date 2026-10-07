import AppKit
import MangaTLCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct MangaTLApp: App {
    init() {
        Self.ensureSpaceEfficientMalloc()
        Task.detached(priority: .background) { ThumbnailCache.trimDisk() }
        WindowCommandCenter.shared.installShortcuts()
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
        .commands {
            // View › Show/Hide Sidebar (⌃⌘S) for the page sidebar.
            SidebarCommands()
            CommandGroup(after: .saveItem) { ExportMenuItem() }
            TranslateCommands()
            CommandGroup(after: .sidebar) {
                Button("Zoom to Fit") { WindowCommandCenter.shared.actions?.zoomToFit() }
                    .keyboardShortcut("0")
            }
            CommandMenu("Page") {
                Button("Edit Page") { WindowCommandCenter.shared.actions?.editPage() }
                    .keyboardShortcut("e")
            }
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
    @AppStorage("problemsPanelVisible") private var problemsVisible = false
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
            .alert("MangaTL", isPresented: .constant(error != nil), presenting: error) { _ in
                Button("OK") { error = nil }
            } message: { Text($0) }
            .onChange(of: project?.lastTranslated?.token) { reloadEditorIfTranslated() }
            // Commands for the menu bar while a project is open (they read state when run).
            .onChange(of: project.map(ObjectIdentifier.init), initial: true) {
                WindowCommandCenter.shared.actions = project == nil ? nil : WindowActions(
                    export: { openExport() },
                    translatePage: { project?.translatePage(editor?.index ?? position.page, saving: editor) },
                    translateAll: { if let project { project.translate(pages: Array(0..<project.count)) } },
                    stop: {
                        project?.cancel()
                        editor?.cancelWork()
                    },
                    editPage: { if project != nil, editor == nil { edit(position.page) } },
                    // As the status-bar ⌘0: a whole page in the reader, default thumbnails in the grid.
                    zoomToFit: {
                        if let editor { editor.zoomCommand = .fit }
                        else if mode == .reader { readerZoom = .fitHeight }
                        else { gridSize = Double(ZoomControls.gridDefault) }
                    },
                    undoManager: { editor?.undo },
                    stepPage: { delta, vertical in
                        guard let project else { return false }
                        if let editor {
                            let target = editor.index + delta
                            if target >= 0, target < project.count { edit(target) }
                            return true
                        }
                        guard mode == .reader, !vertical else { return false }
                        let target = min(max(position.page + delta, 0), project.count - 1)
                        position.page = target
                        position.jump = target
                        return true
                    })
            }
            .sheet(item: $sheet) { which in
                if let project {
                    switch which {
                    case .presets: PresetsView(project: project)
                    case .export(let scope):
                        ExportView(project: project, scope: scope)
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

    /// The page sidebar is a system split-view column, as in Finder: the traffic lights sit in it,
    /// the title and toolbar sit to its right, and the system provides its one toggle (and ⌃⌘S).
    private var framed: some View {
        NavigationSplitView(columnVisibility: $columns) {
            if let project {
                PageSidebar(project: project, position: position, editorPage: editor?.index) { page in
                    if editor != nil {
                        edit(page)
                    } else {
                        if mode == .grid { mode = .reader }
                        position.page = page
                        position.jump = page
                    }
                } onRemove: { pages in
                    removePages(pages, from: project)
                }
                .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 320)
            }
        } detail: {
            detail
        }
        // Remember whether the user wants the sidebar; without a project there is nothing to list.
        .onChange(of: columns) { _, new in if project != nil { sidebarPreferred = new != .detailOnly } }
        .onChange(of: project == nil, initial: true) { _, closed in
            columns = closed || !sidebarPreferred ? .detailOnly : .all
        }
        .toolbar(removing: project == nil ? .sidebarToggle : nil)
        .frame(minWidth: 820, minHeight: 560)
        .navigationTitle(project?.title ?? "MangaTL")
        .toolbar { toolbar }
    }

    private var detail: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if let project, problemsVisible {
                        ProblemsPanel(project: project, onGoToPage: { page in
                            if editor != nil {
                                edit(page)
                            } else {
                                if mode == .grid { mode = .reader }
                                position.page = page
                                position.jump = page
                            }
                        }, onClose: { problemsVisible = false })
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    StatusBar(project: project, position: project == nil ? nil : position, activity: editor?.busy ?? busy,
                              cancelActivity: editor?.busy == nil ? nil : { editor?.cancelWork() }) {
                        if project != nil, editor == nil {
                            ZoomControls(mode: mode, gridSize: Binding(get: { CGFloat(gridSize) }, set: { gridSize = Double($0) }),
                                         readerZoom: $readerZoom, readerColumn: ReaderLayout.defaultColumnWidth)
                        }
                    } leading: {
                        if let project { ProblemsButton(project: project, visible: $problemsVisible) }
                    }
                }
                .animation(.snappy(duration: 0.2), value: problemsVisible)
            }
            // A new failure opens the panel; warnings only update the count.
            .onChange(of: project?.problems.last?.id) {
                if project?.problems.last?.severity == .error { problemsVisible = true }
            }
    }

    @ViewBuilder private var content: some View {
        if let editor {
            EditorView(model: editor, inspectorPreferred: inspectorVisible)
                // A new model (e.g. reloaded after translating) needs a new canvas: it holds its model.
                .id(ObjectIdentifier(editor))
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
            } onExport: { pages in
                sheet = .export(.pages(pages))
            }
            .id(ObjectIdentifier(project))
        } else {
            WelcomeView(recents: recents, onOpen: { open($0) }, onOpenFolder: { choosingFolder = true }, onImport: { importArchive() })
        }
    }

    /// File › Export…: the grid selection if there is one, else the whole project.
    private func openExport() {
        if let editor, editor.dirty { editor.save() }
        let selected = project?.gridSelection ?? []
        sheet = .export(editor == nil && mode == .grid && !selected.isEmpty ? .pages(selected) : .all)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if let project, let editor {
            EditorToolbar(model: editor, pageCount: project.count, inspectorVisible: $inspectorVisible,
                          onClose: closeEditor, onOpenPage: edit) {
                if editor.dirty { editor.save() }
                sheet = .export(.pages([editor.index]))
            }
            ToolbarSpacer(.fixed)
            ToolbarItemGroup {
                LanguageMenu(project: project, position: position, editorPage: editor.index)
                TranslateMenu(project: project, position: position, editor: editor) { sheet = $0 }
            }
        } else if let project {
            ToolbarItem(placement: .navigation) {
                if mode == .reader {
                    Button { mode = .grid } label: { Label("All Pages", systemImage: "square.grid.3x3") }
                        .keyboardShortcut(.escape, modifiers: [])
                        .tip("Back to all pages (Esc)")
                }
            }
            ToolbarItem { LanguageMenu(project: project, position: position) }
            ToolbarSpacer(.fixed)
            ToolbarItemGroup {
                TranslateMenu(project: project, position: position) { sheet = $0 }
                // ⌘E lives in View › Edit Page: on this button it also caught ⇧⌘E (Export).
                Button { edit(position.page) } label: { Label("Edit Page", systemImage: "pencil.and.scribble") }
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
                try await BookExporter.export(source, store: nil, settings: ProjectSettings(), options: .importArchive, to: folder)
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

    /// Takes pages out of the project (the files stay in the folder). The editor, which knows its
    /// page by index, is reopened on the same page, or on the nearest one left if it was removed.
    private func removePages(_ pages: IndexSet, from project: ProjectSession) {
        guard pages.count < project.count else { return }
        let edited = editor.map { ($0.pageKey, $0.index) }
        if edited != nil { closeEditor() }
        project.remove(atOffsets: pages)
        position.page = min(position.page, project.count - 1)
        if let (key, index) = edited {
            edit(project.index(of: key) ?? min(index - pages.filter { $0 < index }.count, project.count - 1))
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
    func setSidebar(_ visible: Bool) {
        sidebarPreferred = visible
        columns = visible ? .all : .detailOnly
    }
    var problemsShown: Bool { problemsVisible }
    var currentPage: Int { position.page }
    var sheetShown: Bool { sheet != nil }
    func jump(to page: Int) { position.page = page; position.jump = page }
    func removeFromSidebar(_ pages: IndexSet) { if let project { removePages(pages, from: project) } }
    func showProblems(_ visible: Bool) { problemsVisible = visible }
    #endif
}

/// The open project's commands, for the menu bar. Shortcuts on items inside toolbar menus only
/// register once that menu has been opened, so the menu bar carries them (always active).
struct WindowActions {
    let export: () -> Void
    let translatePage: () -> Void
    let translateAll: () -> Void
    let stop: () -> Void
    let editPage: () -> Void
    let zoomToFit: () -> Void
    /// The editor's undo stack (nil outside the editor: the standard Edit menu handles it).
    let undoManager: () -> UndoManager?
    /// Arrow keys: moves `delta` pages; returns false to leave the key to the view (e.g. ↑/↓
    /// scrolling the reader, arrows in the grid).
    let stepPage: (_ delta: Int, _ vertical: Bool) -> Bool
}

/// Where the open window registers its commands for the menu bar. The menu items look them up
/// when chosen rather than observing them: SwiftUI evaluated the items' enabled state once, at
/// launch (no project yet), and only refreshed it when the menu was opened, so until then their
/// shortcuts didn't fire. With no project open they do nothing.
@MainActor final class WindowCommandCenter {
    static let shared = WindowCommandCenter()
    var actions: WindowActions?
    private var monitor: Any?

    /// The app's own shortcuts, matched exactly (key and modifiers). SwiftUI's menu matching ignored
    /// Shift — plain ⌘E ran Export (⇧⌘E), and a ⌘E button caught ⇧⌘E — so these are handled here
    /// first; the menu items only show them.
    private static let shortcuts: [(key: String, modifiers: NSEvent.ModifierFlags, run: (WindowActions) -> Void)] = [
        ("e", [.command], { $0.editPage() }),
        ("e", [.command, .shift], { $0.export() }),
        ("t", [.command], { $0.translatePage() }),
        ("t", [.command, .shift], { $0.translateAll() }),
        (".", [.command], { $0.stop() }),
        ("0", [.command], { $0.zoomToFit() }),
    ]

    func installShortcuts() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated { WindowCommandCenter.shared.handle(event) }
            return handled ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        // Only for the project window itself: not in sheets, panels or popovers.
        guard let actions, let window = event.window ?? NSApp.keyWindow, window.attachedSheet == nil, window.sheetParent == nil,
              !(window is NSPanel), window.contentView != nil else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        // Undo/redo go to the editor's own stack (Edit › Undo targets the window's, which is empty),
        // except while typing in a text field, which undoes its own typing.
        if event.charactersIgnoringModifiers?.lowercased() == "z", modifiers == [.command] || modifiers == [.command, .shift],
           let undo = actions.undoManager(), !(window.firstResponder is NSTextView) {
            if modifiers == [.command] { if undo.canUndo { undo.undo() } } else if undo.canRedo { undo.redo() }
            return true
        }
        // Arrows: previous/next page (editor: all four; reader: ← →). Not while typing.
        if modifiers.isEmpty, !(window.firstResponder is NSTextView),
           let step: (Int, Bool) = switch event.specialKey {
               case .leftArrow?: (-1, false)
               case .rightArrow?: (1, false)
               case .upArrow?: (-1, true)
               case .downArrow?: (1, true)
               default: nil
           } {
            return actions.stepPage(step.0, step.1)
        }
        guard let key = event.charactersIgnoringModifiers?.lowercased(),
              let match = Self.shortcuts.first(where: { $0.key == key && $0.modifiers == modifiers }) else { return false }
        match.run(actions)
        return true
    }
}

struct ExportMenuItem: View {
    var body: some View {
        Button("Export…") { WindowCommandCenter.shared.actions?.export() }
            .keyboardShortcut("e", modifiers: [.command, .shift])
    }
}

/// Translate in the menu bar (also offered from the toolbar's Translate menu).
struct TranslateCommands: Commands {
    var body: some Commands {
        CommandMenu("Translate") {
            Button("Translate This Page") { WindowCommandCenter.shared.actions?.translatePage() }
                .keyboardShortcut("t")
            Button("Translate All Untranslated Pages") { WindowCommandCenter.shared.actions?.translateAll() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            Button("Stop Translating") { WindowCommandCenter.shared.actions?.stop() }
                .keyboardShortcut(".")
        }
    }
}
