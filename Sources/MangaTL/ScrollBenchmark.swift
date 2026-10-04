#if DEBUG || BENCH
import AppKit
import MangaTLCore
import QuartzCore

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
        log("translated \(project.translatedCount) pages, peak \(Int(peak)) MB, error \(project.lastError ?? "none")")
        await snapshot(width: 1000, name: "reader")

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
        TooltipPresenter.shared.schedule("Translate this page", shortcut: "⌘T")
        while !TooltipPresenter.shared.isVisible, Date().timeIntervalSince(start) < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        log(String(format: "tooltip visible after %.0f ms", Date().timeIntervalSince(start) * 1000))
        try? await Task.sleep(for: .milliseconds(200))
        let tipView = TooltipPresenter.shared.contentView
        if let rep = tipView.bitmapImageRepForCachingDisplay(in: tipView.bounds) {
            tipView.cacheDisplay(in: tipView.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mangatl_tooltip.png"))
        }
        TooltipPresenter.shared.hide()

        for which in [ProjectSheet.presets, .typesetCheck, .export(.all)] {
            view.show(which)
            try? await Task.sleep(for: .seconds(1.5))
            snapshotWindow(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mangatl_sheet_\(which.id).png"), sheet: true)
            view.show(nil)
            try? await Task.sleep(for: .milliseconds(500))
        }

        view.edit(0)
        try? await Task.sleep(for: .milliseconds(500))
        guard let editor = view.currentEditor else { log("no editor"); NSApp.terminate(nil); return }
        await edit(editor, canvasSnapshot: copy.appendingPathComponent("../mangatl_editor_canvas.jpg").standardized)
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
            log("translate in editor: reloaded \(reloaded !== editor), \(reloaded.doc.blocks.count) blocks, user layers kept \(kept), cleanup layers \(reloaded.doc.layers.filter { $0.kind == .cleanup }.count)")
            reloaded.selection = Set(reloaded.doc.blocks.prefix(1).map(\.id))
        }
        for width in [820.0, 1000, 1400] { await snapshot(width: width, name: "editor") }

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
            log("holding 10 s with inspector visible")
            try? await Task.sleep(for: .seconds(10))
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
