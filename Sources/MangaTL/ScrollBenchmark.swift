#if DEBUG || BENCH
import AppKit
import MangaTLCore
import QuartzCore
import SwiftUI

/// Debug-only scroll benchmark, enabled with `MANGATL_BENCH=<project path>`.
/// Drives the scroll view once per display frame (grid to the bottom, then 300 reader pages),
/// prints hitch time per second and the peak memory footprint, then quits.
@MainActor
final class ScrollBenchmark: NSObject {
    static var bookPath: String? { ProcessInfo.processInfo.environment["MANGATL_BENCH"] }
    nonisolated(unsafe) static var running: ScrollBenchmark?

    /// Starts on the page grid that is actually in the window (SwiftUI may create and discard
    /// collection views while building the split view).
    static func start(openReader: @escaping () -> Void) async {
        for _ in 0..<50 {
            if let grid = NSApp.windows.lazy.compactMap({ $0.contentView?.firstDescendant(of: PageGridView.self) }).first,
               let scroll = grid.enclosingScrollView, grid.window != nil {
                running = ScrollBenchmark(scroll: scroll, openReader: openReader)
                running?.start()
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        print("BENCH failed: no page grid")
        NSApp.terminate(nil)
    }

    private weak var scroll: NSScrollView?
    private let openReader: () -> Void
    private var link: CADisplayLink?
    private var phase = "grid"
    private var last: CFTimeInterval = 0
    private var started: CFTimeInterval = 0
    private var hitch: CFTimeInterval = 0
    private var frames = 0
    private var peak = 0.0
    private let gridSpeed: CGFloat = 8000
    private let readerSpeed: CGFloat = 6000

    init(scroll: NSScrollView, openReader: @escaping () -> Void) {
        self.scroll = scroll
        self.openReader = openReader
    }

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            link = scroll?.displayLink(target: self, selector: #selector(tick(_:)))
            link?.add(to: .main, forMode: .common)
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let scroll, let document = scroll.documentView else { return }
        peak = max(peak, MemoryFootprint.megabytes())
        if last == 0 { last = link.timestamp; started = link.timestamp; return }
        let dt = link.timestamp - last
        let budget = link.duration
        last = link.timestamp
        frames += 1
        if dt > budget * 1.5 { hitch += dt - budget }

        let maxY = document.frame.height - scroll.contentSize.height
        var origin = scroll.contentView.bounds.origin
        origin.y = min(maxY, origin.y + (phase == "grid" ? gridSpeed : readerSpeed) * dt)
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)

        let elapsed = link.timestamp - started
        let readerDone = phase == "reader" && (origin.y >= maxY || elapsed > 60)
        if (phase == "grid" && origin.y >= maxY) || readerDone {
            report(elapsed: elapsed)
            if phase == "grid" {
                phase = "reader"
                (last, started, hitch, frames) = (0, 0, 0, 0)
                openReader()
            } else {
                link.invalidate()
                NSApp.terminate(nil)
            }
        }
    }

    private func report(elapsed: CFTimeInterval) {
        let line = String(format: "BENCH %@: %.1fs, %d frames (%.0f fps), hitch %.1f ms/s, peak footprint %.0f MB",
                          phase, elapsed, frames, Double(frames) / elapsed, hitch * 1000 / elapsed, peak)
        if let collection = scroll?.documentView as? NSCollectionView {
            let items = collection.visibleItems().compactMap { $0 as? PageItem }
            print("  visibleItems \(items.count), with image \(items.filter(\.hasImage).count), visible paths \(collection.indexPathsForVisibleItems().count)")
        }
        print(line)
        fflush(stdout)
    }
}
#endif

#if DEBUG || BENCH
/// Debug-only UI smoke run, enabled with `MANGATL_SMOKE=<project path>`: opens the project in the reader,
/// translates the first pages through the same `ProjectSession` the menus use, logs progress and the
/// app's peak footprint, then quits.
enum PageSourcesHelper {
    static func isImage(_ name: String) -> Bool {
        ["jpg", "jpeg", "png", "webp"].contains((name as NSString).pathExtension.lowercased())
    }
}

@MainActor
enum SmokeRun {
    static var bookPath: String? { ProcessInfo.processInfo.environment["MANGATL_SMOKE"] }

    /// Renders the whole window (title bar + toolbar included) into a PNG.
    static func snapshotWindow(to url: URL, sheet: Bool = false) {
        let main = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil })
        guard let window = sheet ? main?.attachedSheet : main, let frameView = window.contentView?.superview else { return }
        let rect = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: rect) else { return }
        frameView.cacheDisplay(in: rect, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("SMOKE window snapshot \(rep.pixelsWide)x\(rep.pixelsHigh) → \(url.lastPathComponent)")
    }

    /// US-layout virtual key codes for the keys the smoke run presses.
    static let keyCodes: [String: UInt16] = ["e": 14, "t": 17, "0": 29, ".": 47, "z": 6, "left": 123, "right": 124, "down": 125, "up": 126]

    /// Makes the app active with its window key (the smoke run is launched from a terminal, which
    /// can keep focus), then presses the key.
    static func pressSettled(_ key: String, _ modifiers: NSEvent.ModifierFlags = .command) async {
        NSApp.activate()
        NSApp.windows.first(where: { $0.isVisible })?.makeKeyAndOrderFront(nil)
        for _ in 0..<20 where NSApp.keyWindow == nil { try? await Task.sleep(for: .milliseconds(50)) }
        press(key, modifiers)
    }

    /// Queues a key press as the keyboard would deliver it (Shift gives the capital letter), so it
    /// goes through event monitors, the window and the menu bar like a real one.
    static func press(_ key: String, _ modifiers: NSEvent.ModifierFlags = .command) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else { return }
        let arrows: [String: NSEvent.SpecialKey] = ["left": .leftArrow, "right": .rightArrow, "up": .upArrow, "down": .downArrow]
        let chars = arrows[key].map { String(Character(UnicodeScalar($0.rawValue)!)) } ?? (modifiers.contains(.shift) ? key.uppercased() : key)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                            isARepeat: false, keyCode: keyCodes[key.lowercased()] ?? 0) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    /// The page actually at the top of the reader's scroll view (not the published position).
    static func readerShownPage() -> Int? {
        guard let collection = NSApp.windows.lazy.compactMap({ $0.contentView?.firstDescendant(of: NSCollectionView.self) }).first,
              let layout = collection.collectionViewLayout as? ReaderLayout,
              let top = collection.enclosingScrollView?.contentView.bounds.minY else { return nil }
        return layout.index(atY: top + ReaderLayout.spacing + 1)
    }

    /// Height of each toolbar item as laid out in the real window.
    static func logToolbar(_ name: String) {
        guard let toolbar = NSApp.windows.first(where: { $0.isVisible })?.toolbar else { return }
        let items = toolbar.items.compactMap { item -> String? in
            guard let view = item.view else { return item.itemIdentifier.rawValue.contains("idebar") ? "[system sidebar toggle]" : nil }
            return "\(item.label.isEmpty ? item.itemIdentifier.rawValue.suffix(12).description : item.label)=\(Int(view.frame.height))"
        }
        log("toolbar \(name): \(items.joined(separator: ", "))")
    }

    static func log(_ s: String) {
        print("SMOKE \(s) (\(Int(MemoryFootprint.megabytes())) MB)")
        fflush(stdout)
    }

    static func waitForTranslation(_ project: ProjectSession, peak: inout Double) async {
        try? await Task.sleep(for: .milliseconds(100))
        while project.isTranslating {
            peak = max(peak, MemoryFootprint.megabytes())
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Sets the window width (content size) and snapshots it.
    static func snapshot(width: CGFloat, name: String) async {
        guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return }
        window.setContentSize(NSSize(width: width, height: 760))
        try? await Task.sleep(for: .milliseconds(600))
        snapshotWindow(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mangatl_\(name)_\(Int(width)).png"))
    }

    /// The whole flow on a throwaway copy of `path`: welcome → project ops → translate →
    /// editor → translate in editor → narrow/wide snapshots → close → reopen.
    static func run(in view: ContentView, path: String) async {
        let fm = FileManager.default
        let copy = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mangatl-smoke-\(UUID().uuidString.prefix(6))")
        try? fm.createDirectory(at: copy, withIntermediateDirectories: true)
        for file in (try? fm.contentsOfDirectory(atPath: path)) ?? [] where PageSourcesHelper.isImage(file) {
            try? fm.copyItem(at: URL(fileURLWithPath: path).appendingPathComponent(file), to: copy.appendingPathComponent(file))
        }
        try? await Task.sleep(for: .seconds(1))
        await snapshot(width: 1000, name: "welcome")

        view.open(copy)
        guard let project = view.currentProject else { log("open failed"); NSApp.terminate(nil); return }
        log("project open: \(project.count) pages, .mangatl \(fm.fileExists(atPath: copy.appendingPathComponent(".mangatl/project.json").path))")

        // Add an image, move it to the end, check order persisted.
        let extra = URL(fileURLWithPath: path).appendingPathComponent("../pages/fr_P01.jpg").standardized
        project.addImages([extra], at: 0)
        let added = project.pages.first?.file ?? "?"
        project.move(fromOffsets: [0], toOffset: project.count)
        log("added \(added) at 1, moved to end → order \(project.pages.map(\.file))")
        await snapshot(width: 1000, name: "grid")

        var peak = 0.0
        view.showReader()
        project.translate(pages: [0, 1], redo: true)
        await waitForTranslation(project, peak: &peak)
        log("translated \(project.translatedCount) pages, peak \(Int(peak)) MB, problems \(project.problems.isEmpty ? "none" : project.problems.map(\.message).joined(separator: "; "))")
        logToolbar("reader")
        // Jumping to a page (as the sidebar does) must leave that page current.
        var landed: [Int] = []
        for page in 0..<project.count {
            view.jump(to: page)
            try? await Task.sleep(for: .milliseconds(500))
            landed.append(view.currentPage)
        }
        // Shortcuts work without ever opening the toolbar's Translate menu.
        NSApp.activate()
        NSApp.windows.first(where: { $0.isVisible })?.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(500))
        let translateMenu = NSApp.mainMenu?.items.first { $0.title == "Translate" }?.submenu
        translateMenu?.update()
        NSApp.activate()
        NSApp.windows.first(where: { $0.isVisible })?.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(500))
        log("menu bar Translate: \(translateMenu?.items.map { "\($0.title)[\($0.keyEquivalent)]\($0.isEnabled ? "" : " disabled")" } ?? ["missing"]), active \(NSApp.isActive), key window \(NSApp.keyWindow != nil)")
        await pressSettled("e")
        try? await Task.sleep(for: .milliseconds(600))
        log("shortcuts: ⌘E opened the editor \(view.currentEditor != nil)")
        if view.currentEditor != nil { view.closeEditor(); try? await Task.sleep(for: .milliseconds(800)) }
        await pressSettled("e", [.command, .shift])
        var opened = false
        for _ in 0..<30 where !opened { try? await Task.sleep(for: .milliseconds(50)); opened = view.sheetShown }
        log("shortcuts: ⇧⌘E opened export sheet \(opened), opened the editor instead \(view.currentEditor != nil)")
        if view.currentEditor != nil { view.closeEditor(); try? await Task.sleep(for: .milliseconds(800)) }
        view.show(nil)
        try? await Task.sleep(for: .milliseconds(800))
        await pressSettled("t")
        try? await Task.sleep(for: .milliseconds(300))
        let started = project.isTranslating
        await pressSettled(".")
        try? await Task.sleep(for: .milliseconds(300))
        log("shortcuts: ⌘T started translation \(started), ⌘. stopped it \(!project.isTranslating)")
        await pressSettled("t", [.command, .shift])
        var startedAll = false
        for _ in 0..<30 where !startedAll { try? await Task.sleep(for: .milliseconds(50)); startedAll = project.isTranslating }
        let queued = project.progress?.total ?? 0
        project.cancel()
        while project.isTranslating { try? await Task.sleep(for: .milliseconds(50)) }
        log("shortcuts: ⇧⌘T started translating all \(startedAll), queued \(queued) pages (untranslated: \(project.count - project.translatedCount))")

        // Auto names a language only for pages it has identified.
        project.settings.autoLanguage = true
        let languageBefore = project.detectedLanguage(ofPage: 1)
        project.translate(pages: [1], redo: true)
        await waitForTranslation(project, peak: &peak)
        log("auto: page 2 language before \(languageBefore?.rawValue ?? "none"), after \(project.detectedLanguage(ofPage: 1)?.rawValue ?? "none"), page 3 \(project.detectedLanguage(ofPage: 2)?.rawValue ?? "none")")
        project.settings.autoLanguage = nil

        // Closing the editor returns to the page that was edited, not page 1.
        view.edit(2)
        try? await Task.sleep(for: .milliseconds(500))
        view.closeEditor()
        try? await Task.sleep(for: .milliseconds(1200))
        log("close editor on page 3 → current page \(view.currentPage + 1), showing page \(readerShownPage().map { "\($0 + 1)" } ?? "?")")
        await pressSettled("right", [])
        try? await Task.sleep(for: .milliseconds(800))
        let afterRight = view.currentPage
        await pressSettled("down", [])
        try? await Task.sleep(for: .milliseconds(800))
        log("shortcuts: reader → from page 3 to \(afterRight + 1); ↓ scrolls (page \(view.currentPage + 1), not a jump)")
        log("sidebar jumps to pages \(Array(0..<project.count)) → current \(landed)")
        log("translated marks: \(project.pages.prefix(2).map { project.translatedIDs.contains($0.id) })")
        await snapshot(width: 1000, name: "reader")

        // The page sidebar on its own (window snapshots don't capture it).
        let sidebarHost = NSHostingView(rootView: PageSidebar(project: project, position: ReadingPosition(), editorPage: nil, onSelect: { _ in }, onRemove: { _ in })
            .frame(width: 200, height: 640).background(Color(white: 0.16)).environment(\.colorScheme, .dark))
        let offscreen = NSWindow(contentRect: CGRect(x: -4000, y: 0, width: 200, height: 640), styleMask: .borderless, backing: .buffered, defer: false)
        offscreen.contentView = sidebarHost
        offscreen.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(1.5))
        if let rep = sidebarHost.bitmapImageRepForCachingDisplay(in: sidebarHost.bounds) {
            sidebarHost.cacheDisplay(in: sidebarHost.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mangatl_sidebar.png"))
        }
        offscreen.orderOut(nil)

        // An image dropped into the folder from outside joins the project in name order.
        let first = project.pages[0].file
        let outside = copy.appendingPathComponent((first as NSString).deletingPathExtension + "a." + (first as NSString).pathExtension)
        let before = project.count
        try? fm.copyItem(at: copy.appendingPathComponent(first), to: outside)
        let watchStart = Date()
        while project.count == before, Date().timeIntervalSince(watchStart) < 3 { try? await Task.sleep(for: .milliseconds(20)) }
        log(String(format: "folder watch: %d → %d pages after %.2f s, new page at %d", before, project.count, Date().timeIntervalSince(watchStart),
                   (project.pages.firstIndex { $0.file == outside.lastPathComponent } ?? -1) + 1))
        try? fm.removeItem(at: outside)
        try? await Task.sleep(for: .seconds(1))
        log("folder watch: removed → \(project.count) pages")
        // A page removed from the project stays out although its file is still in the folder.
        let removedFile = project.pages[1].file
        project.remove(atOffsets: [1])
        project.rescanFolder()
        log("remove page \(removedFile): \(project.count) pages after rescan, back in project \(project.pages.contains { $0.file == removedFile })")
        project.addImages([copy.appendingPathComponent(removedFile)], at: 1)
        log("add it back: \(project.pages.map(\.file)), at \((project.pages.firstIndex { $0.file == removedFile } ?? -1) + 1)")

        // A failing export lands in the Problems panel (which opens itself); Retry fails again.
        project.export(pages: [0], options: ExportOptions(), to: URL(fileURLWithPath: "/System/mangatl-smoke/out.cbz"))
        while project.isTranslating { try? await Task.sleep(for: .milliseconds(20)) }
        try? await Task.sleep(for: .milliseconds(400))
        log("problems after failed export: \(project.problems.map { "\($0.operation): \($0.message)" }), panel \(view.problemsShown)")
        await snapshot(width: 1200, name: "problems")
        if let problem = project.problems.first { project.retry(problem) }
        while project.isTranslating { try? await Task.sleep(for: .milliseconds(20)) }
        log("after retry: \(project.problems.count) problem(s)")
        project.clearProblems()
        view.showProblems(false)

        // Sidebar open / collapsed / narrow window, reader fit modes.
        view.setSidebar(true)
        try? await Task.sleep(for: .milliseconds(600))
        await snapshot(width: 1200, name: "reader_sidebar")
        view.setReaderZoom(.fitHeight)
        await snapshot(width: 1200, name: "reader_fitheight")
        view.setReaderZoom(.fitWidth)
        await snapshot(width: 1200, name: "reader_fitwidth")
        view.setReaderZoom(.column(ReaderLayout.defaultColumnWidth))
        await snapshot(width: 820, name: "reader_narrow")
        view.setSidebar(false)
        await snapshot(width: 1200, name: "reader_nosidebar")
        view.setSidebar(true)

        // Grid sizes.
        view.showGrid()
        for size in [90.0, 160, 360] {
            view.setGridSize(size)
            await snapshot(width: 1200, name: "grid_\(Int(size))")
        }
        view.setGridSize(150)
        view.showReader()

        // Tooltip: appears after ~300 ms (measured once the window is idle).
        try? await Task.sleep(for: .seconds(1.5))
        let start = Date()
        TooltipPresenter.shared.schedule("Lasso: draw around text the app missed to read, translate and erase it", shortcut: "L")
        while !TooltipPresenter.shared.isVisible, Date().timeIntervalSince(start) < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        log(String(format: "tooltip visible after %.0f ms", Date().timeIntervalSince(start) * 1000))
        try? await Task.sleep(for: .milliseconds(200))
        let tipView = TooltipPresenter.shared.contentView
        if let rep = tipView.bitmapImageRepForCachingDisplay(in: tipView.bounds) {
            tipView.cacheDisplay(in: tipView.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mangatl_tooltip.png"))
        }
        TooltipPresenter.shared.hide()

        for which in [ProjectSheet.presets, .export(.all)] {
            view.show(which)
            try? await Task.sleep(for: .seconds(1.5))
            snapshotWindow(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mangatl_sheet_\(which.id).png"), sheet: true)
            view.show(nil)
            try? await Task.sleep(for: .milliseconds(500))
        }

        view.edit(0)
        try? await Task.sleep(for: .milliseconds(500))
        guard let editor = view.currentEditor else { log("no editor"); NSApp.terminate(nil); return }
        for width in [1100.0, 1400] {
            NSApp.windows.first(where: { $0.isVisible })?.setContentSize(NSSize(width: width, height: 760))
            try? await Task.sleep(for: .milliseconds(500))
            logToolbar("editor \(Int(width))")
        }
        await edit(editor, canvasSnapshot: copy.appendingPathComponent("../mangatl_editor_canvas.jpg").standardized)
        await lasso(editor)
        if let canvas = NSApp.windows.lazy.compactMap({ $0.contentView?.firstDescendant(of: CanvasDocumentView.self) }).first,
           let scroll = canvas.enclosingScrollView {
            scroll.magnification = 2
            await pressSettled("0")
            let blocks = editor.doc.blocks.count
            editor.addBlock()
            await pressSettled("z")
            try? await Task.sleep(for: .milliseconds(400))
            let afterUndo = editor.doc.blocks.count
            await pressSettled("z", [.command, .shift])
            try? await Task.sleep(for: .milliseconds(400))
            log("shortcuts: add box \(blocks) → \(blocks + 1), ⌘Z → \(afterUndo), ⇧⌘Z → \(editor.doc.blocks.count)")
            editor.undo.undo()
            // Arrow keys move between pages in the editor.
            var visited = [view.currentEditor?.index ?? -1]
            for key in ["right", "right", "left", "down"] {
                await pressSettled(key, [])
                try? await Task.sleep(for: .milliseconds(700))
                visited.append(view.currentEditor?.index ?? -1)
            }
            log("shortcuts: editor arrows → → ← ↓ visit pages \(visited.map { $0 + 1 })")
            view.edit(visited[0])
            try? await Task.sleep(for: .milliseconds(500))
            try? await Task.sleep(for: .milliseconds(400))
            let target = min(scroll.contentSize.width / canvas.frame.width, scroll.contentSize.height / canvas.frame.height) * 0.98
            log(String(format: "shortcuts: ⌘0 in editor → magnification %.3f (fit %.3f)", scroll.magnification, target))
        }
        for fit in [EditorCanvas.ZoomCommand.fitWidth, .fitHeight] {
            editor.zoomCommand = fit
            try? await Task.sleep(for: .milliseconds(500))
            if let canvas = NSApp.windows.lazy.compactMap({ $0.contentView?.firstDescendant(of: CanvasDocumentView.self) }).first,
               let scroll = canvas.enclosingScrollView {
                let target = fit == .fitWidth ? scroll.contentSize.width / canvas.frame.width : scroll.contentSize.height / canvas.frame.height
                log(String(format: "editor %@: magnification %.3f vs %.3f (%.1f%% off)", "\(fit)", scroll.magnification, target * 0.98,
                           abs(scroll.magnification / (target * 0.98) - 1) * 100))
            }
        }
        editor.zoomCommand = .fit

        // Translate again from inside the editor: user layers must survive, editor reloads.
        if editor.dirty { editor.save() }
        let userLayers = editor.doc.layers.filter { $0.kind == nil }.map(\.id)
        project.translate(pages: [editor.index], redo: true)
        await waitForTranslation(project, peak: &peak)
        try? await Task.sleep(for: .milliseconds(500))
        if let reloaded = view.currentEditor {
            let kept = userLayers.allSatisfy { id in reloaded.doc.layers.contains { $0.id == id } }
            try? await Task.sleep(for: .milliseconds(300))
            let canvasModel = NSApp.windows.lazy.compactMap { $0.contentView?.firstDescendant(of: CanvasDocumentView.self) }.first?.model
            log("translate in editor: canvas shows reloaded model \(canvasModel === reloaded),")
            log("translate in editor: reloaded \(reloaded !== editor), \(reloaded.doc.blocks.count) blocks, user layers kept \(kept), cleanup layers \(reloaded.doc.layers.filter { $0.kind == .cleanup }.count)")
            reloaded.selection = Set(reloaded.doc.blocks.prefix(1).map(\.id))
        }
        for width in [820.0, 1000, 1400] { await snapshot(width: width, name: "editor") }

        // The colour control in a form, and its popover, rendered on their own.
        RecentColors.shared.use(RGBA(hex: "#1E90FF")!)
        let samples: [(String, AnyView)] = [
            ("colour_form", AnyView(Form {
                Section("Colour") {
                    LabeledContent("Text") { ColorField(color: .constant(.black)) }
                    LabeledContent("Outline") { ColorField(color: .constant(.white)) }
                }
            }.formStyle(.grouped).frame(width: 320, height: 150))),
            ("colour_popover", AnyView(ColorPopover(color: .constant(RGBA(hex: "#1E90FF")!)).background(.background))),
        ]
        for (name, view) in samples {
            let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mangatl_\(name).png"))
            }
        }

        // Deleting pages from the sidebar while editing: the editor stays on its page.
        if let editing = view.currentEditor {
            let key = editing.pageKey, pagesBefore = project.count
            view.edit(1)
            try? await Task.sleep(for: .milliseconds(300))
            let onSecond = view.currentEditor?.pageKey
            view.removeFromSidebar([0, 2])
            try? await Task.sleep(for: .milliseconds(300))
            log("sidebar delete pages 1 and 3 while editing page 2: \(pagesBefore) → \(project.count) pages, editor still on its page \(view.currentEditor?.pageKey == onSecond) at \((view.currentEditor?.index ?? -1) + 1)")
            view.removeFromSidebar([0])
            try? await Task.sleep(for: .milliseconds(300))
            log("delete the edited page: \(project.count) pages, editor on page \((view.currentEditor?.index ?? -1) + 1), key changed \(view.currentEditor?.pageKey != onSecond)")
            _ = key
        }

        view.closeProject()
        try? await Task.sleep(for: .milliseconds(300))
        let recent = RecentProjects.shared.entries.first
        log("closed; recents[0] = \(recent?.title ?? "none") (\(recent?.translated ?? 0)/\(recent?.pages ?? 0)), saved state \(ProjectFile.load(from: copy.appendingPathComponent(".mangatl/project.json")).map { "\($0.state.mode) p\($0.state.page + 1)" } ?? "none")")

        view.open(copy)
        try? await Task.sleep(for: .milliseconds(500))
        if let reopened = view.currentProject {
            log("reopened: \(reopened.count) pages, last page \(reopened.pages.last?.file ?? ""), editor open \(view.currentEditor != nil) on page \((view.currentEditor?.index ?? -1) + 1), translated \(reopened.translatedCount)")
        }
        RecentProjects.shared.entries.filter { $0.path.contains("mangatl-smoke-") }.forEach { RecentProjects.shared.remove($0) }
        NSApp.terminate(nil)
    }

    /// Deletes a detected box, then lassos its lettering: the box comes back (read + translated) with
    /// the lettering erased, and one undo removes both.
    static func lasso(_ model: EditorModel) async {
        func log(_ s: String) { SmokeRun.log("lasso: \(s)") }
        guard let target = model.doc.blocks.first(where: { !$0.sourceText.isEmpty }) else { log("no text block"); return }
        let rect = target.textRect.denormalized(to: model.pageSize).insetBy(dx: -6, dy: -6)
        model.selection = [target.id]
        model.deleteSelected()
        let blocks = model.doc.blocks.count
        let outline = (0..<24).map { i -> CGPoint in
            let a = Double(i) / 24 * 2 * .pi
            return CGPoint(x: rect.midX + cos(a) * rect.width * 0.62, y: rect.midY + sin(a) * rect.height * 0.62)
        }
        let probe = (Int(rect.midX), Int(rect.midY))
        model.addFromLasso(outline)
        let start = Date()
        while model.busy != nil, Date().timeIntervalSince(start) < 30 { try? await Task.sleep(for: .milliseconds(50)) }
        let added = model.doc.blocks.last
        let cleanup = model.doc.layers.first { $0.kind == .cleanup }
        log(String(format: "%.1f s; blocks %d → %d, read \"%@\" → \"%@\", cleanup layer %@, centre alpha %d",
                   Date().timeIntervalSince(start), blocks, model.doc.blocks.count, String((added?.sourceText ?? "").prefix(20)),
                   String((added?.translation ?? "").prefix(30)), cleanup == nil ? "missing" : "present", model.activeLayerAlpha(probe.0, probe.1)))
        model.undo.undo()
        log("undo → blocks \(model.doc.blocks.count), undo name was \"\(model.undo.redoActionName)\"")
        model.undo.redo()
        log("redo → blocks \(model.doc.blocks.count)")
    }

    /// Drives the editor model the way the canvas does and snapshots the canvas to `out`.
    static func edit(_ model: EditorModel, canvasSnapshot out: URL) async {
        func log(_ s: String) { SmokeRun.log("edit: \(s)") }
        var peak = MemoryFootprint.megabytes()
        log("opened page \(model.index + 1), \(model.doc.blocks.count) blocks, \(model.doc.layers.count) layers, font \(model.project.settings.style.fontName)")
        guard model.doc.blocks.count >= 2 else { log("need 2 blocks"); return }
        let first = model.doc.blocks[0], second = model.doc.blocks[1]

        // Single box: text + fixed font size.
        model.select(first.id, extend: false)
        model.updateSelected("Edit Translation") { $0.translation = "EDITED BY SMOKE TEST" }
        model.updateSelected("Size") { var s = model.style(of: $0); s.fontSize = 30; $0.style = s }
        let rect = first.layoutRect.denormalized(to: model.pageSize)
        model.beginDrag(); model.dragSelection(by: CGPoint(x: 20, y: 10)); model.endDrag()

        // Multi-select (rubber band over both boxes) and restyle both at once.
        let r1 = first.layoutRect.denormalized(to: model.pageSize), r2 = second.layoutRect.denormalized(to: model.pageSize)
        model.select(in: r1.union(r2).insetBy(dx: -30, dy: -30), extend: false)
        let picked = model.selection.count
        model.updateSelected("Colour") { var s = model.style(of: $0); s.color = RGBA(0.8, 0, 0); $0.style = s }
        let red = model.doc.blocks.filter { $0.style?.color == RGBA(0.8, 0, 0) }.count
        model.updateSelected("Outline") { var s = model.style(of: $0); s.strokeColor = RGBA(hex: "#1e90ff")!; $0.style = s }
        log("hex outline → \(model.style(of: model.doc.blocks[0]).strokeColor.hex)")
        log("text: size 30 on box 1, rubber band picked \(picked) boxes, \(red) recoloured, box 1 moved from \(Int(rect.minX)) to \(Int(model.doc.blocks[0].layoutRect.denormalized(to: model.pageSize).minX))")

        // Inspector must survive its boxes disappearing.
        model.tool = .select
        try? await Task.sleep(for: .milliseconds(400))
        model.deleteSelected()
        try? await Task.sleep(for: .milliseconds(400))
        model.undo.undo()
        model.selection = [first.id]
        try? await Task.sleep(for: .milliseconds(400))
        model.selection = []
        try? await Task.sleep(for: .milliseconds(400))
        log("inspector survived delete / undo / deselect, \(model.doc.blocks.count) blocks")
        if ProcessInfo.processInfo.environment["MANGATL_SMOKE_HOLD"] != nil {
            model.selection = [first.id]
            log("holding 10 s with inspector visible, moving the mouse over the window")
            // Mouse-moved events through the normal routing (tracking areas, hit testing).
            if let window = NSApp.windows.first(where: { $0.isVisible }) {
                for i in 0..<500 {
                    let p = NSPoint(x: 100 + Double(i * 7 % 1100), y: 100 + Double(i * 13 % 600))
                    if let event = NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                        NSApp.sendEvent(event)
                    }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                log("mouse moves done")
            }
            model.selection = []
        }

        // Layers: erase on a new layer, heal on another, hide the first.
        let layersBefore = model.doc.layers.count
        model.addLayer()
        model.tool = .erase
        model.brushColor = RGBA(0, 0.6, 1)
        model.beginStroke(at: CGPoint(x: 200, y: 150)); model.stroke(to: CGPoint(x: 600, y: 150), from: CGPoint(x: 200, y: 150)); model.endStroke()
        model.tool = .restore
        model.beginStroke(at: CGPoint(x: 400, y: 150)); model.stroke(to: CGPoint(x: 600, y: 150), from: CGPoint(x: 400, y: 150)); model.endStroke()
        let eraseLayer = model.activeLayer!
        model.addLayer()
        model.tool = .heal
        model.brushSize = 30
        model.beginStroke(at: CGPoint(x: 900, y: 700)); model.stroke(to: CGPoint(x: 1050, y: 760), from: CGPoint(x: 900, y: 700)); model.endStroke()
        while model.busy != nil {
            peak = max(peak, MemoryFootprint.megabytes())
            try? await Task.sleep(for: .milliseconds(10))
        }
        let healLayer = model.activeLayer!
        let healed = model.activeLayerAlpha(975, 730)
        model.undo.undo()
        let undone = model.activeLayerAlpha(975, 730)
        model.undo.redo()
        log("layers \(layersBefore) → \(model.doc.layers.count); heal alpha \(healed) → undo \(undone) → redo \(model.activeLayerAlpha(975, 730)); peak \(Int(peak)) MB")
        model.activate(eraseLayer)
        log("erase layer: painted px alpha \(model.activeLayerAlpha(300, 150)), unpainted px alpha \(model.activeLayerAlpha(500, 150))")
        model.deleteLayer(healLayer)
        let afterDelete = model.doc.layers.count
        model.undo.undo()
        log("delete heal layer → \(afterDelete) layers, undo → \(model.doc.layers.count)")
        model.setLayerVisible(eraseLayer, false)
        model.renameLayer(eraseLayer, "Sky fix")

        model.save()
        // Reopen the page from disk: everything must come back editable.
        if let reopened = try? EditorModel(project: model.project, index: model.index) {
            let names = reopened.doc.layers.map { "\($0.name)\($0.visible ? "" : " (hidden)")" }.joined(separator: ", ")
            reopened.activate(healLayer)
            let size = reopened.doc.blocks.first { $0.id == first.id }?.style?.fontSize
            log("reopened: layers [\(names)], heal px alpha \(reopened.activeLayerAlpha(975, 730)), box 1 size \(size.map { "\(Int($0))" } ?? "auto"), text \"\(reopened.doc.blocks.first { $0.id == first.id }?.translation ?? "")\"")
            // Deleting a layer must stick: gone from the page and its file pruned after saving.
            let store = model.project.store, key = model.pageKey
            reopened.deleteLayer(healLayer)
            reopened.save()
            let again = try? EditorModel(project: model.project, index: model.index)
            log("deleted heal layer and saved → reopened layers [\((again?.doc.layers ?? []).map(\.name).joined(separator: ", "))], file left \(store.loadLayer(key, healLayer) != nil)")
        }
        model.setLayerVisible(eraseLayer, true)

        // Snapshot the canvas view (it draws in draw(_:), so cacheDisplay captures it).
        try? await Task.sleep(for: .milliseconds(300))
        if let canvas = NSApp.windows.lazy.compactMap({ $0.contentView?.firstDescendant(of: CanvasDocumentView.self) }).first,
           let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.bounds.width), pixelsHigh: Int(canvas.bounds.height),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            rep.size = canvas.bounds.size
            canvas.cacheDisplay(in: canvas.bounds, to: rep)
            try? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])?.write(to: out)
            log("canvas snapshot \(rep.pixelsWide)x\(rep.pixelsHigh) → \(out.lastPathComponent)")
        } else {
            log("canvas not found")
        }
    }
}
#endif

#if DEBUG || BENCH
extension NSView {
    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        for sub in subviews {
            if let match = sub as? T ?? sub.firstDescendant(of: type) { return match }
        }
        return nil
    }
}
#endif
