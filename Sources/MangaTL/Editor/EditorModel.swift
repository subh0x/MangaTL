import AppKit
import MangaTLCore
import Observation

/// Full-page RGBA bitmap for the layer being painted (pixel (x, y) is top-left-origin, row 0 = top).
final class PatchCanvas {
    let width: Int, height: Int
    let context: CGContext
    private let pixels: UnsafeMutablePointer<UInt8>
    let bytesPerRow: Int

    /// Starts transparent and pastes `cropped` at `rect` (a layer's stored pixels).
    init(width: Int, height: Int, cropped: PixelBuffer? = nil, at rect: CGRect = .zero) {
        self.width = width
        self.height = height
        context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        bytesPerRow = context.bytesPerRow
        pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        if let cropped {
            for row in 0..<cropped.height where Int(rect.minY) + row < height {
                cropped.bytes.withUnsafeBufferPointer { src in
                    let count = min(cropped.width, width - Int(rect.minX)) * 4
                    (pixels + offset(Int(rect.minX), Int(rect.minY) + row)).update(from: src.baseAddress! + row * cropped.width * 4, count: count)
                }
            }
        }
    }

    func image() -> CGImage? { context.makeImage() }

    @inline(__always) func offset(_ x: Int, _ y: Int) -> Int { y * bytesPerRow + x * 4 }

    func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let o = offset(x, y)
        return (pixels[o], pixels[o + 1], pixels[o + 2], pixels[o + 3])
    }

    func set(_ x: Int, _ y: Int, _ p: (UInt8, UInt8, UInt8, UInt8)) {
        let o = offset(x, y)
        pixels[o] = p.0; pixels[o + 1] = p.1; pixels[o + 2] = p.2; pixels[o + 3] = p.3
    }

    /// The painted area cropped out (nil if the layer is empty).
    func cropToContent() -> (rect: CGRect, pixels: PixelBuffer)? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[offset(x, y) + 3] != 0 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        let rect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        var out = PixelBuffer(width: Int(rect.width), height: Int(rect.height))
        out.bytes = bytes(in: rect)
        return (rect, out)
    }

    func bytes(in rect: CGRect) -> [UInt8] {
        let r = rect.integral
        var out = [UInt8](); out.reserveCapacity(Int(r.width * r.height) * 4)
        for y in Int(r.minY)..<Int(r.maxY) {
            out.append(contentsOf: UnsafeBufferPointer(start: pixels + offset(Int(r.minX), y), count: Int(r.width) * 4))
        }
        return out
    }

    func setBytes(_ bytes: [UInt8], in rect: CGRect) {
        let r = rect.integral, w = Int(r.width) * 4
        for (row, y) in (Int(r.minY)..<Int(r.maxY)).enumerated() {
            bytes.withUnsafeBufferPointer { src in
                (pixels + offset(Int(r.minX), y)).update(from: src.baseAddress! + row * w, count: w)
            }
        }
    }
}

/// Pixels of one rect of a layer, kept for undo.
struct PixelPatch {
    var rect: CGRect
    var bytes: [UInt8]
}

/// State and operations for editing one page: text boxes, image layers, brushes, undo, save.
///
/// Image layers are kept cropped to their content (`layerPixels`); only the layer being painted is
/// expanded to a full-page `PatchCanvas`, so extra layers cost memory only for the area they cover.
@MainActor @Observable
final class EditorModel {
    enum Tool: String, CaseIterable, Identifiable {
        case select = "Text", lasso = "Lasso", erase = "Erase", heal = "Heal", clone = "Clone", restore = "Unpaint"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .select: "character.cursor.ibeam"
            case .lasso: "lasso"
            case .erase: "paintbrush"
            case .heal: "bandage"
            case .clone: "rectangle.on.rectangle"
            case .restore: "eraser"
            }
        }
        /// Single-key shortcut (handled by the canvas).
        var key: Character {
            switch self {
            case .select: "t"
            case .lasso: "l"
            case .erase: "e"
            case .heal: "h"
            case .clone: "c"
            case .restore: "r"
            }
        }
        var help: String {
            switch self {
            case .select: "Text: select, move and resize text boxes; ⇧-click or drag to select several"
            case .lasso: "Lasso: draw around text the app missed to read, translate and erase it"
            case .erase: "Erase: paint over lettering with a solid colour on the selected layer"
            case .heal: "Heal: paint over lettering on artwork to rebuild what's behind it"
            case .clone: "Clone: copy pixels from elsewhere onto the selected layer; ⌥-click to set the source"
            case .restore: "Unpaint: remove paint from the selected layer, revealing what's below"
            }
        }
        /// Tools that paint with the brush.
        var isBrush: Bool { self != .select && self != .lasso }
    }

    let project: ProjectSession
    let index: Int
    /// Stable id of the page (keys its saved work); the index can change when pages are reordered.
    let pageKey: String
    let page: PixelBuffer
    let pageImage: CGImage
    /// Every editor action is its own undo step (explicit groups, not per-event): the heal brush
    /// finishes asynchronously and would otherwise merge into whatever event happens to be open.
    let undo: UndoManager = {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }()

    var doc: PageDoc
    var selection: Set<TextBlock.ID> = []
    /// Image layer brushes paint into.
    private(set) var activeLayer: ImageLayer.ID?
    var tool: Tool = .select
    var brushSize: Double = 24
    /// nil = pick the colour under the stroke's first point.
    var brushColor: RGBA?
    var cloneSource: CGPoint?
    /// Pending zoom request for the canvas (set by toolbar buttons).
    var zoomCommand: EditorCanvas.ZoomCommand?
    var busy: String?
    var error: String?
    private(set) var dirty = false
    /// Bumped when pixels change so the canvas redraws.
    private(set) var pixelsVersion = 0

    @ObservationIgnored private var canvas: PatchCanvas?
    @ObservationIgnored private var layerPixels: [ImageLayer.ID: PixelBuffer] = [:]
    @ObservationIgnored private var layerImages: [ImageLayer.ID: CGImage] = [:]
    @ObservationIgnored private var changedLayers: Set<ImageLayer.ID> = []

    // Stroke state
    /// Pre-stroke pixels of each 64×64 tile the current stroke touched (keyed by tile index), so
    /// undo costs the stroke's area rather than a full-page copy.
    @ObservationIgnored private var strokeTiles: [Int: PixelPatch] = [:]
    private static let tileSize = 64
    @ObservationIgnored private var strokeDirty: CGRect = .null
    @ObservationIgnored private var strokeColor: (UInt8, UInt8, UInt8, UInt8) = (255, 255, 255, 255)
    @ObservationIgnored private var cloneOffset: CGPoint = .zero
    @ObservationIgnored var healMask: [Bool] = []
    @ObservationIgnored var healPoints: [CGPoint] = []
    @ObservationIgnored private var dragStartDoc: PageDoc?

    init(project: ProjectSession, index: Int) throws {
        self.project = project
        self.index = index
        pageKey = project.pageKey(index)
        let image = try project.source.image(at: index, maxPixelSize: PagePipeline.workingMaxPixels)
        page = PixelBuffer(image)
        pageImage = page.makeImage()
        doc = project.store.loadPage(pageKey) ?? PageDoc(workingSize: page.size)
        for layer in doc.layers {
            guard let stored = project.store.loadLayer(pageKey, layer.id) else { continue }
            layerPixels[layer.id] = PixelBuffer(stored, width: Int(layer.rect.width), height: Int(layer.rect.height))
            layerImages[layer.id] = stored
        }
        activeLayer = doc.layers.last?.id
    }

    var pageSize: CGSize { page.size }

    // MARK: Text boxes

    /// The one selected box, nil when none or several are selected.
    var selectedBlock: TextBlock? { selection.count == 1 ? doc.blocks.first { selection.contains($0.id) } : nil }
    var selectedBlocks: [TextBlock] { doc.blocks.filter { selection.contains($0.id) } }

    func style(of block: TextBlock) -> TextStyle { project.settings.resolvedStyle(for: block) }

    /// Makes `block`'s style its role's preset for the project, and lets every box of that role on
    /// this page follow it.
    func useAsPreset(_ block: TextBlock) {
        let role = block.role ?? .dialogue
        let style = style(of: block)
        if role == .dialogue {
            project.settings.style = style
        } else {
            var presets = project.settings.roleStyles ?? [:]
            presets[role] = style
            project.settings.roleStyles = presets
        }
        change("Use as Preset") { doc in
            for i in doc.blocks.indices where (doc.blocks[i].role ?? .dialogue) == role { doc.blocks[i].style = nil }
        }
    }

    /// The size auto-fit picks for `block` (page pixels), for showing next to the size field.
    func fittedFontSize(of block: TextBlock) -> Double? {
        PageRenderer.fittedFontSize(block, style: style(of: block), pageSize: pageSize, scale: 1).map(Double.init)
    }

    /// Applies an undoable change to the document.
    func change(_ name: String, _ body: (inout PageDoc) -> Void) {
        let before = doc
        body(&doc)
        guard doc != before else { return }
        registerDocUndo(before, name: name)
        dirty = true
    }

    /// Registers one undo step. While undoing/redoing, UndoManager has its own group open.
    private func undoStep(_ name: String, _ register: () -> Void) {
        if undo.isUndoing || undo.isRedoing {
            register()
            undo.setActionName(name)
            return
        }
        undo.beginUndoGrouping()
        register()
        undo.setActionName(name)
        undo.endUndoGrouping()
    }

    private func registerDocUndo(_ before: PageDoc, name: String) {
        undoStep(name) { registerDocUndoAction(before, name: name) }
    }

    private func registerDocUndoAction(_ before: PageDoc, name: String) {
        undo.registerUndo(withTarget: self) { model in
            let current = model.doc
            model.doc = before
            // Layer rects follow their pixels, which this snapshot doesn't own.
            for i in model.doc.layers.indices {
                if let now = current.layers.first(where: { $0.id == model.doc.layers[i].id }) { model.doc.layers[i].rect = now.rect }
            }
            model.selection = model.selection.filter { id in before.blocks.contains { $0.id == id } }
            if let active = model.activeLayer, !before.layers.contains(where: { $0.id == active }) { model.activeLayer = before.layers.last?.id }
            model.registerDocUndo(current, name: name)
            model.pixelsVersion += 1
        }
        undo.setActionName(name)
    }

    /// Applies `body` to every selected box as one undo step.
    func updateSelected(_ name: String, _ body: (inout TextBlock) -> Void) {
        guard !selection.isEmpty else { return }
        change(name) { doc in
            for i in doc.blocks.indices where selection.contains(doc.blocks[i].id) { body(&doc.blocks[i]) }
        }
    }

    func select(_ id: TextBlock.ID, extend: Bool) {
        if extend {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
    }

    /// Selects every box whose frame intersects `rect` (page pixels).
    func select(in rect: CGRect, extend: Bool) {
        let hits = doc.blocks.filter { $0.layoutRect.denormalized(to: pageSize).intersects(rect) }.map(\.id)
        selection = extend ? selection.union(hits) : Set(hits)
    }

    func selectAll() { selection = Set(doc.blocks.map(\.id)) }

    /// Live drag of box frames: one undo step per gesture.
    func beginDrag() { dragStartDoc = doc }

    /// Moves every selected box by (dx, dy) page pixels from where the drag began.
    func dragSelection(by delta: CGPoint) {
        guard let start = dragStartDoc else { return }
        for i in doc.blocks.indices where selection.contains(doc.blocks[i].id) {
            let original = start.blocks[i].layoutRect.denormalized(to: pageSize)
            doc.blocks[i].layoutRect = original.offsetBy(dx: delta.x, dy: delta.y).normalized(in: pageSize)
        }
    }

    /// Resizes the single selected box.
    func drag(to rect: CGRect) {
        guard let id = selection.first, selection.count == 1, let i = doc.blocks.firstIndex(where: { $0.id == id }) else { return }
        doc.blocks[i].layoutRect = rect.normalized(in: pageSize)
    }

    func endDrag() {
        if let before = dragStartDoc, before != doc {
            registerDocUndo(before, name: "Move Text")
            dirty = true
        }
        dragStartDoc = nil
    }

    func addBlock(at point: CGPoint? = nil) {
        let size = CGSize(width: pageSize.width * 0.3, height: pageSize.height * 0.08)
        let center = point ?? CGPoint(x: pageSize.width / 2, y: pageSize.height / 2)
        let rect = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
            .normalized(in: pageSize)
        let block = TextBlock(textRect: rect, layoutRect: rect, shape: .rectangle, sourceText: "", translation: "Text")
        change("Add Text") { $0.blocks.append(block) }
        selection = [block.id]
    }

    func deleteSelected() {
        guard !selection.isEmpty else { return }
        let ids = selection
        change(ids.count > 1 ? "Delete Text Boxes" : "Delete Text") { $0.blocks.removeAll { ids.contains($0.id) } }
        selection = []
    }

    func retranslateSelected() {
        let blocks = selectedBlocks.filter { !$0.sourceText.isEmpty }
        guard !blocks.isEmpty else { return }
        run("Translating…") { [project] in
            let texts = try await Translator.shared.translate(blocks.map(\.sourceText), from: project.settings.language)
            let byID = Dictionary(uniqueKeysWithValues: zip(blocks.map(\.id), texts))
            self.change("Translate") { doc in
                for i in doc.blocks.indices { if let t = byID[doc.blocks[i].id] { doc.blocks[i].translation = t } }
            }
        }
    }

    func rereadSelected() {
        guard let block = selectedBlock else { return }
        let rect = block.textRect.denormalized(to: pageSize)
        run("Reading…") { [project, page] in
            let text = try await PagePipeline.shared.reread(page, rect: rect, language: project.settings.language)
            self.updateSelected("Read Text") { $0.sourceText = text }
            if !text.isEmpty {
                let translated = try await Translator.shared.translate([text], from: project.settings.language).first ?? ""
                self.updateSelected("Translate") { $0.translation = translated }
            }
        }
    }

    /// Runs editor work in the background, one job at a time. A failure goes to the Problems panel
    /// with a Retry; success clears an earlier failure of the same operation.
    private func run(_ label: String, _ work: @escaping @MainActor () async throws -> Void) {
        guard busy == nil else { return }
        busy = label
        let operation = label.replacingOccurrences(of: "…", with: "")
        Task {
            do {
                try await work()
                project.resolve(operation, page: pageKey)
            } catch {
                project.report(operation, page: pageKey, error.localizedDescription) { [weak self] in self?.run(label, work) }
            }
            busy = nil
        }
    }

    // MARK: Lasso

    /// Reads and translates the text inside `outline` (page pixels) into a new box, and erases the
    /// original lettering into the clean-up layer, as one undo step. For text the detector missed.
    func addFromLasso(_ outline: [CGPoint]) {
        let bounds = CGRect(origin: .zero, size: pageSize)
        let rect = outline.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }.integral.intersection(bounds)
        guard outline.count > 2, !rect.isNull, rect.width >= 8, rect.height >= 8 else { return }
        let area = Self.rasterize(outline, in: rect)
        let window = rect.insetBy(dx: -CGFloat(PagePipeline.healContext), dy: -CGFloat(PagePipeline.healContext)).integral
            .intersection(bounds)
        let composite = compositeBuffer(window)
        let local = rect.offsetBy(dx: -window.minX, dy: -window.minY)
        let language = project.settings.language
        run("Reading Selection…") { [page] in
            let source = try await PagePipeline.shared.reread(page, rect: rect, language: language)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let translation = source.isEmpty ? "" : try await Translator.shared.translate([source], from: language).first ?? ""
            let erased = try await PagePipeline.shared.erase(composite, rect: local, area: area)
            self.applyLasso(rect: rect, erased: erased, source: source, translation: translation)
            if source.isEmpty {
                self.project.report("Lasso", page: self.pageKey, "No text was read inside the selection. Type the translation into the new box, or draw around the text more closely.",
                                    severity: .warning)
            }
        }
    }

    private func applyLasso(rect: CGRect, erased: PixelBuffer, source: String, translation: String) {
        let previousLayer = activeLayer
        undo.beginUndoGrouping()
        if !doc.layers.contains(where: { $0.kind == .cleanup }) {
            commitCanvas()
            let layer = ImageLayer(name: "Text Clean-up", rect: .zero, kind: .cleanup)
            change("Add Layer") { $0.layers.insert(layer, at: 0) }
        }
        activate(doc.layers.first { $0.kind == .cleanup }?.id)
        let canvas = activeCanvas()
        if let layer = activeLayer {
            let before = PixelPatch(rect: rect, bytes: canvas.bytes(in: rect))
            for y in 0..<erased.height {
                for x in 0..<erased.width {
                    let i = (y * erased.width + x) * 4
                    guard erased.bytes[i + 3] != 0 else { continue }
                    canvas.set(Int(rect.minX) + x, Int(rect.minY) + y, (erased.bytes[i], erased.bytes[i + 1], erased.bytes[i + 2], 255))
                }
            }
            commitStroke([before], layer: layer, name: "Erase")
        }
        var block = TextBlock(textRect: rect.normalized(in: pageSize), layoutRect: rect.normalized(in: pageSize), shape: .rectangle,
                              sourceText: source, translation: translation)
        let role = PagePipeline.guessRole(source: source, translation: translation, inBubble: true)
        block.role = role == .dialogue ? nil : role
        change("Add Text") { $0.blocks.append(block) }
        undo.setActionName("Lasso Text")
        undo.endUndoGrouping()
        // Brushes keep painting where they did before.
        if let previousLayer, doc.layers.contains(where: { $0.id == previousLayer }) { activate(previousLayer) }
        tool = .select
        selection = [block.id]
        pixelsVersion += 1
    }

    /// Inside-the-outline mask for `rect`, row-major from the top.
    static func rasterize(_ outline: [CGPoint], in rect: CGRect) -> [Bool] {
        let w = Int(rect.width), h = Int(rect.height)
        var bytes = [UInt8](repeating: 0, count: w * h)
        bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            // Memory rows run top-down; flip so page y (down) maps onto them.
            ctx.translateBy(x: -rect.minX, y: CGFloat(h) + rect.minY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.addLines(between: outline)
            ctx.closePath()
            ctx.fillPath()
        }
        return bytes.map { $0 >= 128 }
    }

    // MARK: Image layers

    /// Visible layers bottom to top, as images positioned in page pixels (the active one full-page).
    func visibleLayerImages() -> [PageRenderer.Layer] {
        doc.layers.filter(\.visible).compactMap { layer in
            if layer.id == activeLayer, let canvas, let image = canvas.image() {
                return PageRenderer.Layer(rect: CGRect(origin: .zero, size: pageSize), image: image)
            }
            return layerImages[layer.id].map { PageRenderer.Layer(rect: layer.rect, image: $0) }
        }
    }

    /// Makes `id` the layer brushes paint into.
    func activate(_ id: ImageLayer.ID?) {
        guard id != activeLayer else { return }
        commitCanvas()
        activeLayer = id
    }

    /// Folds the full-page canvas back into the active layer's cropped pixels.
    private func commitCanvas() {
        guard let canvas, let id = activeLayer, let i = doc.layers.firstIndex(where: { $0.id == id }) else {
            canvas = nil
            return
        }
        if let content = canvas.cropToContent() {
            layerPixels[id] = content.pixels
            layerImages[id] = content.pixels.makeImage()
            doc.layers[i].rect = content.rect
        } else {
            layerPixels[id] = nil
            layerImages[id] = nil
            doc.layers[i].rect = .zero
        }
        self.canvas = nil
    }

    /// The active layer's full-page canvas, created on first paint.
    private func activeCanvas() -> PatchCanvas {
        if let canvas { return canvas }
        if activeLayer == nil || !(doc.layers.first { $0.id == activeLayer }?.visible ?? false) {
            addLayer()
        }
        let layer = doc.layers.first { $0.id == activeLayer }!
        let canvas = PatchCanvas(width: page.width, height: page.height, cropped: layerPixels[layer.id], at: layer.rect)
        self.canvas = canvas
        return canvas
    }

    func addLayer() {
        commitCanvas()
        let number = (doc.layers.count) + 1
        let layer = ImageLayer(name: "Retouch \(number)", rect: .zero)
        change("Add Layer") { $0.layers.append(layer) }
        activeLayer = layer.id
    }

    func deleteLayer(_ id: ImageLayer.ID) {
        commitCanvas()
        guard let i = doc.layers.firstIndex(where: { $0.id == id }) else { return }
        let meta = doc.layers[i], pixels = layerPixels[id]
        doc.layers.remove(at: i)
        layerPixels[id] = nil
        layerImages[id] = nil
        if activeLayer == id { activeLayer = doc.layers.last?.id }
        dirty = true
        pixelsVersion += 1
        registerLayerRestore(meta, pixels: pixels, at: i)
    }

    private func registerLayerRestore(_ meta: ImageLayer, pixels: PixelBuffer?, at i: Int) {
        undoStep("Delete Layer") { registerLayerRestoreAction(meta, pixels: pixels, at: i) }
    }

    private func registerLayerRestoreAction(_ meta: ImageLayer, pixels: PixelBuffer?, at i: Int) {
        undo.registerUndo(withTarget: self) { model in
            model.commitCanvas()
            model.doc.layers.insert(meta, at: min(i, model.doc.layers.count))
            model.layerPixels[meta.id] = pixels
            model.layerImages[meta.id] = pixels?.makeImage()
            model.changedLayers.insert(meta.id)
            model.activeLayer = meta.id
            model.pixelsVersion += 1
            model.undo.registerUndo(withTarget: model) { $0.deleteLayer(meta.id) }
        }
        undo.setActionName("Delete Layer")
    }

    func setLayerVisible(_ id: ImageLayer.ID, _ visible: Bool) {
        change(visible ? "Show Layer" : "Hide Layer") { doc in
            if let i = doc.layers.firstIndex(where: { $0.id == id }) { doc.layers[i].visible = visible }
        }
        pixelsVersion += 1
    }

    func renameLayer(_ id: ImageLayer.ID, _ name: String) {
        change("Rename Layer") { doc in
            if let i = doc.layers.firstIndex(where: { $0.id == id }) { doc.layers[i].name = name }
        }
    }

    /// Moves a layer up (+1, towards the front) or down (-1).
    func moveLayer(_ id: ImageLayer.ID, by offset: Int) {
        commitCanvas()
        change("Reorder Layers") { doc in
            guard let i = doc.layers.firstIndex(where: { $0.id == id }) else { return }
            let j = i + offset
            guard doc.layers.indices.contains(j) else { return }
            doc.layers.swapAt(i, j)
        }
        pixelsVersion += 1
    }

    // MARK: Brushes

    /// Colour of the page as currently shown (top visible layer with paint, else the original).
    func compositePixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let x = min(max(0, x), page.width - 1), y = min(max(0, y), page.height - 1)
        for layer in doc.layers.reversed() where layer.visible {
            if layer.id == activeLayer, let canvas {
                let p = canvas.pixel(x, y)
                if p.3 != 0 { return p }
            } else if let pixels = layerPixels[layer.id],
                      CGRect(origin: layer.rect.origin, size: pixels.size).contains(CGPoint(x: x, y: y)) {
                let i = ((y - Int(layer.rect.minY)) * pixels.width + x - Int(layer.rect.minX)) * 4
                if pixels.bytes[i + 3] != 0 { return (pixels.bytes[i], pixels.bytes[i + 1], pixels.bytes[i + 2], 255) }
            }
        }
        let i = (y * page.width + x) * 4
        return (page.bytes[i], page.bytes[i + 1], page.bytes[i + 2], 255)
    }

    func beginStroke(at point: CGPoint) {
        if let c = brushColor {
            strokeColor = (UInt8(c.r * 255), UInt8(c.g * 255), UInt8(c.b * 255), 255)
        } else {
            strokeColor = compositePixel(Int(point.x), Int(point.y))
            strokeColor.3 = 255
        }
        _ = activeCanvas()
        strokeTiles = [:]
        strokeDirty = .null
        if tool == .clone, let source = cloneSource { cloneOffset = CGPoint(x: source.x - point.x, y: source.y - point.y) }
        if tool == .heal {
            healMask = [Bool](repeating: false, count: page.width * page.height)
            healPoints = []
        }
        stroke(to: point, from: nil)
    }

    /// Stamps the brush along the segment; returns the rect that changed (page pixels).
    @discardableResult
    func stroke(to point: CGPoint, from previous: CGPoint?) -> CGRect {
        let canvas = activeCanvas()
        let r = brushSize / 2
        let start = previous ?? point
        let distance = hypot(point.x - start.x, point.y - start.y)
        let steps = max(1, Int(distance / max(1, r / 3)))
        var dirty = CGRect.null
        for s in 0...steps {
            let t = CGFloat(s) / CGFloat(steps)
            let c = CGPoint(x: start.x + (point.x - start.x) * t, y: start.y + (point.y - start.y) * t)
            dirty = dirty.union(stamp(at: c, radius: r, on: canvas))
        }
        if tool == .heal { healPoints.append(point) }
        strokeDirty = strokeDirty.union(dirty)
        pixelsVersion += 1
        return dirty
    }

    private func stamp(at c: CGPoint, radius r: CGFloat, on canvas: PatchCanvas) -> CGRect {
        let x0 = max(0, Int(c.x - r)), x1 = min(page.width - 1, Int(c.x + r))
        let y0 = max(0, Int(c.y - r)), y1 = min(page.height - 1, Int(c.y + r))
        guard x0 <= x1, y0 <= y1 else { return .null }
        if tool != .heal { captureTiles(CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1), from: canvas) }
        let r2 = r * r
        for y in y0...y1 {
            for x in x0...x1 where (CGFloat(x) - c.x) * (CGFloat(x) - c.x) + (CGFloat(y) - c.y) * (CGFloat(y) - c.y) <= r2 {
                switch tool {
                case .erase: canvas.set(x, y, strokeColor)
                case .restore: canvas.set(x, y, (0, 0, 0, 0))
                case .clone:
                    guard cloneSource != nil else { continue }
                    var p = compositePixel(x + Int(cloneOffset.x), y + Int(cloneOffset.y))
                    p.3 = 255
                    canvas.set(x, y, p)
                case .heal: healMask[y * page.width + x] = true
                case .select, .lasso: break
                }
            }
        }
        return CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
    }

    private func captureTiles(_ rect: CGRect, from canvas: PatchCanvas) {
        let t = Self.tileSize, columns = (page.width + t - 1) / t
        for ty in Int(rect.minY) / t...Int(rect.maxY - 1) / t {
            for tx in Int(rect.minX) / t...Int(rect.maxX - 1) / t where strokeTiles[ty * columns + tx] == nil {
                let tile = CGRect(x: tx * t, y: ty * t, width: min(t, page.width - tx * t), height: min(t, page.height - ty * t))
                strokeTiles[ty * columns + tx] = PixelPatch(rect: tile, bytes: canvas.bytes(in: tile))
            }
        }
    }

    func endStroke() {
        defer { strokeTiles = [:] }
        guard !strokeDirty.isNull, let layer = activeLayer else { return }
        if tool == .heal {
            heal(rect: strokeDirty, layer: layer)
            return
        }
        commitStroke(Array(strokeTiles.values), layer: layer, name: tool.rawValue)
    }

    private func commitStroke(_ before: [PixelPatch], layer: ImageLayer.ID, name: String) {
        guard !before.isEmpty else { return }
        changedLayers.insert(layer)
        registerPixelUndo(before, layer: layer, name: name)
        dirty = true
    }

    private func registerPixelUndo(_ patches: [PixelPatch], layer: ImageLayer.ID, name: String) {
        undoStep(name) { registerPixelUndoAction(patches, layer: layer, name: name) }
    }

    private func registerPixelUndoAction(_ patches: [PixelPatch], layer: ImageLayer.ID, name: String) {
        undo.registerUndo(withTarget: self) { model in
            model.activate(layer)
            let canvas = model.activeCanvas()
            let current = patches.map { PixelPatch(rect: $0.rect, bytes: canvas.bytes(in: $0.rect)) }
            for patch in patches { canvas.setBytes(patch.bytes, in: patch.rect) }
            model.changedLayers.insert(layer)
            model.pixelsVersion += 1
            model.registerPixelUndo(current, layer: layer, name: name)
        }
        undo.setActionName(name)
    }

    private func heal(rect: CGRect, layer: ImageLayer.ID) {
        let r = rect.insetBy(dx: -2, dy: -2).integral.intersection(CGRect(origin: .zero, size: pageSize))
        var mask = [Bool](repeating: false, count: Int(r.width * r.height))
        for y in 0..<Int(r.height) {
            for x in 0..<Int(r.width) { mask[y * Int(r.width) + x] = healMask[(Int(r.minY) + y) * page.width + Int(r.minX) + x] }
        }
        healMask = []
        healPoints = []
        // Heal the page as currently shown, in a window around the stroke (AOT tiles need context).
        let window = r.insetBy(dx: -CGFloat(PagePipeline.healContext), dy: -CGFloat(PagePipeline.healContext)).integral
            .intersection(CGRect(origin: .zero, size: pageSize))
        let composite = compositeBuffer(window)
        let local = r.offsetBy(dx: -window.minX, dy: -window.minY)
        run("Healing…") {
            let healed = try await PagePipeline.shared.heal(composite, rect: local, mask: mask)
            self.activate(layer)
            let canvas = self.activeCanvas()
            let before = PixelPatch(rect: r, bytes: canvas.bytes(in: r))
            for y in 0..<healed.height {
                for x in 0..<healed.width {
                    let i = (y * healed.width + x) * 4
                    guard healed.bytes[i + 3] != 0 else { continue }
                    canvas.set(Int(r.minX) + x, Int(r.minY) + y, (healed.bytes[i], healed.bytes[i + 1], healed.bytes[i + 2], 255))
                }
            }
            self.commitStroke([before], layer: layer, name: "Heal")
            self.pixelsVersion += 1
        }
    }

    /// The page as currently shown (original + visible layers) inside `window`.
    private func compositeBuffer(_ window: CGRect) -> PixelBuffer {
        var composite = PixelBuffer(width: Int(window.width), height: Int(window.height))
        for y in 0..<composite.height {
            for x in 0..<composite.width {
                let p = compositePixel(Int(window.minX) + x, Int(window.minY) + y), i = (y * composite.width + x) * 4
                composite.bytes[i] = p.0; composite.bytes[i + 1] = p.1; composite.bytes[i + 2] = p.2; composite.bytes[i + 3] = 255
            }
        }
        return composite
    }

    /// Opacity of the active layer at a pixel (for tests and the smoke run).
    func activeLayerAlpha(_ x: Int, _ y: Int) -> UInt8 {
        if let canvas { return canvas.pixel(x, y).3 }
        guard let id = activeLayer, let layer = doc.layers.first(where: { $0.id == id }), let pixels = layerPixels[id],
              CGRect(origin: layer.rect.origin, size: pixels.size).contains(CGPoint(x: x, y: y)) else { return 0 }
        return pixels.bytes[((y - Int(layer.rect.minY)) * pixels.width + x - Int(layer.rect.minX)) * 4 + 3]
    }

    // MARK: Save

    /// Writes the page doc and every changed layer. Layers stay editable when the page is reopened.
    func save() {
        let active = activeLayer
        commitCanvas()
        activeLayer = active
        do {
            for id in changedLayers {
                guard let layer = doc.layers.first(where: { $0.id == id }), let pixels = layerPixels[id] else { continue }
                try project.store.saveLayer(pixels.makeImage(), page: pageKey, id: layer.id)
            }
            changedLayers = []
            try project.store.save(doc, page: pageKey)
            // Files of deleted (or emptied) layers.
            var referenced = doc
            referenced.layers.removeAll { layerPixels[$0.id] == nil }
            project.store.pruneLayers(page: pageKey, keeping: referenced)
            dirty = false
            project.pageChanged(index)
            project.resolve("Save", page: pageKey)
        } catch {
            project.report("Save", page: pageKey, "Couldn't save this page: \(error.localizedDescription)") { [weak self] in self?.save() }
        }
    }
}
