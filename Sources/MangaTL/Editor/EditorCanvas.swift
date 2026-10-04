import AppKit
import MangaTLCore
import SwiftUI

/// Zoomable page canvas (pinch / ⌘± to zoom). The document view is in page pixels, top-left origin.
struct EditorCanvas: NSViewRepresentable {
    let model: EditorModel

    enum ZoomCommand { case fit, fitWidth, fitHeight, zoomIn, zoomOut, actual }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Keeps the page fitted to the canvas while the window resizes, until the user zooms.
    final class Coordinator: NSObject {
        /// The fit the page follows while the window resizes (nil once the user zooms by hand).
        var fit: ZoomCommand? = .fit
        weak var scroll: NSScrollView?

        @objc func resized(_ note: Notification) {
            if let fit, let scroll { EditorCanvas.apply(fit, to: scroll) }
        }

        @objc func userZoomed(_ note: Notification) { fit = nil }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.contentView = CenteringClipView()
        context.coordinator.scroll = scroll
        scroll.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.resized(_:)),
                                               name: NSView.frameDidChangeNotification, object: scroll)
        // Pinch / trackpad zoom.
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.userZoomed(_:)),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: scroll)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 8
        scroll.backgroundColor = .underPageBackgroundColor
        let canvas = CanvasDocumentView(model: model)
        scroll.documentView = canvas
        DispatchQueue.main.async { Self.fit(scroll) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // Reading these registers observation, so any change redraws the canvas.
        _ = (model.doc, model.selection, model.tool, model.pixelsVersion, model.brushSize, model.cloneSource, model.activeLayer, model.project.settings)
        scroll.documentView?.needsDisplay = true
        if let command = model.zoomCommand {
            context.coordinator.fit = [.fit, .fitWidth, .fitHeight].contains(command) ? command : nil
            Self.apply(command, to: scroll)
            DispatchQueue.main.async { model.zoomCommand = nil }
        }
    }

    static func fit(_ scroll: NSScrollView) { apply(.fit, to: scroll) }

    static func apply(_ command: ZoomCommand, to scroll: NSScrollView) {
        guard let doc = scroll.documentView, doc.frame.width > 0 else { return }
        let visible = scroll.contentSize
        let width = visible.width / doc.frame.width, height = visible.height / doc.frame.height
        switch command {
        case .fit: scroll.magnification = min(width, height) * 0.98
        case .fitWidth: scroll.magnification = width * 0.98
        case .fitHeight: scroll.magnification = height * 0.98
        case .zoomIn: scroll.animator().magnification = min(scroll.maxMagnification, scroll.magnification * 1.25)
        case .zoomOut: scroll.animator().magnification = max(scroll.minMagnification, scroll.magnification / 1.25)
        case .actual: scroll.animator().magnification = 1
        }
    }
}

/// Keeps the page centred when it is smaller than the visible area (NSClipView pins it top-left).
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}

final class CanvasDocumentView: NSView {
    let model: EditorModel
    private enum DragMode {
        case none, move(start: CGPoint), resize(corner: Int, original: CGRect), brush(last: CGPoint), lasso
        /// Rubber-band selection; `base` is the selection to extend (⇧/⌘ held).
        case marquee(start: CGPoint, base: Set<TextBlock.ID>)
    }
    private var dragMode = DragMode.none
    private var mouse: CGPoint?
    private var marquee: CGRect?
    /// Freehand outline being drawn with the lasso (page pixels).
    private var lasso: [CGPoint] = []

    init(model: EditorModel) {
        self.model = model
        super.init(frame: CGRect(origin: .zero, size: model.pageSize))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var magnification: CGFloat { enclosingScrollView?.magnification ?? 1 }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let size = model.pageSize
        let full = CGRect(origin: .zero, size: size)
        ctx.saveGState()
        // Page and text are composed bottom-left like PageRenderer, so the editor matches export.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = magnification < 1 ? .medium : .none
        ctx.draw(model.pageImage, in: full)
        PageRenderer.drawLayers(model.visibleLayerImages(), in: ctx, pageHeight: size.height, scale: 1)
        for block in model.doc.blocks where !block.hidden {
            PageRenderer.drawText(block, style: model.style(of: block), in: ctx, pageSize: size, scale: 1)
        }
        ctx.restoreGState()
        drawOverlays(ctx)
    }

    private func drawOverlays(_ ctx: CGContext) {
        let line = 1.5 / magnification
        if model.tool == .select {
            for block in model.doc.blocks {
                let rect = block.layoutRect.denormalized(to: model.pageSize)
                let selected = model.selection.contains(block.id)
                ctx.setStrokeColor(selected ? NSColor.controlAccentColor.cgColor : NSColor.systemTeal.withAlphaComponent(0.6).cgColor)
                ctx.setLineWidth(line * (selected ? 1.5 : 1))
                ctx.setLineDash(phase: 0, lengths: selected ? [] : [6 / magnification, 4 / magnification])
                ctx.stroke(rect)
                if selected && model.selection.count == 1 {
                    ctx.setLineDash(phase: 0, lengths: [])
                    ctx.setFillColor(NSColor.controlAccentColor.cgColor)
                    for corner in corners(of: rect) { ctx.fill(handleRect(corner)) }
                }
            }
            ctx.setLineDash(phase: 0, lengths: [])
            if let marquee {
                ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor)
                ctx.fill(marquee)
                ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
                ctx.setLineWidth(line)
                ctx.stroke(marquee)
            }
        }
        if lasso.count > 1 {
            ctx.addLines(between: lasso)
            ctx.closePath()
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor)
            ctx.fillPath()
            ctx.addLines(between: lasso)
            ctx.closePath()
            ctx.setLineWidth(line)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.strokePath()
            ctx.addLines(between: lasso)
            ctx.closePath()
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineDash(phase: 0, lengths: [5 / magnification, 4 / magnification])
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }
        if model.tool == .heal, model.healPoints.count > 0 {
            ctx.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.35).cgColor)
            ctx.setLineWidth(model.brushSize)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addLines(between: model.healPoints.count == 1 ? [model.healPoints[0], model.healPoints[0]] : model.healPoints)
            ctx.strokePath()
        }
        if model.tool == .clone, let source = model.cloneSource {
            ctx.setStrokeColor(NSColor.systemOrange.cgColor)
            ctx.setLineWidth(line)
            let s = 8 / magnification
            ctx.strokeLineSegments(between: [CGPoint(x: source.x - s, y: source.y), CGPoint(x: source.x + s, y: source.y),
                                             CGPoint(x: source.x, y: source.y - s), CGPoint(x: source.x, y: source.y + s)])
        }
        if model.tool.isBrush, let mouse {
            let r = model.brushSize / 2
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.7).cgColor)
            ctx.setLineWidth(line)
            ctx.strokeEllipse(in: CGRect(x: mouse.x - r, y: mouse.y - r, width: r * 2, height: r * 2))
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.7).cgColor)
            ctx.strokeEllipse(in: CGRect(x: mouse.x - r - line, y: mouse.y - r - line, width: (r + line) * 2, height: (r + line) * 2))
        }
    }

    private func corners(of rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
    }

    private func handleRect(_ p: CGPoint) -> CGRect {
        let s = 9 / magnification
        return CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
    }

    // MARK: Mouse

    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = point(event)
        if model.tool == .select {
            selectDown(at: p, clicks: event.clickCount, extend: !event.modifierFlags.intersection([.shift, .command]).isEmpty)
            return
        }
        if model.tool == .lasso {
            lasso = [p]
            dragMode = .lasso
            return
        }
        if model.tool == .clone, event.modifierFlags.contains(.option) {
            model.cloneSource = p
            return
        }
        if model.tool == .clone, model.cloneSource == nil {
            model.error = "⌥-click where to copy from first."
            return
        }
        model.beginStroke(at: p)
        dragMode = .brush(last: p)
        needsDisplay = true
    }

    private func selectDown(at p: CGPoint, clicks: Int, extend: Bool) {
        if !extend, let selected = model.selectedBlock {
            let rect = selected.layoutRect.denormalized(to: model.pageSize)
            if let corner = corners(of: rect).firstIndex(where: { handleRect($0).insetBy(dx: -4 / magnification, dy: -4 / magnification).contains(p) }) {
                model.beginDrag()
                dragMode = .resize(corner: corner, original: rect)
                return
            }
        }
        if let hit = model.doc.blocks.last(where: { $0.layoutRect.denormalized(to: model.pageSize).contains(p) }) {
            if extend {
                model.select(hit.id, extend: true)
            } else if !model.selection.contains(hit.id) {
                model.select(hit.id, extend: false)
            }
            // Dragging moves the whole selection.
            if model.selection.contains(hit.id) {
                model.beginDrag()
                dragMode = .move(start: p)
            }
        } else if clicks == 2 {
            model.addBlock(at: p)
        } else {
            dragMode = .marquee(start: p, base: extend ? model.selection : [])
            if !extend { model.selection = [] }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        mouse = p
        switch dragMode {
        case .none: break
        case .move(let start):
            model.dragSelection(by: CGPoint(x: p.x - start.x, y: p.y - start.y))
        case .marquee(let start, let base):
            let rect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
            marquee = rect
            model.selection = base
            model.select(in: rect, extend: true)
            needsDisplay = true
        case .resize(let corner, let original):
            // Opposite corner stays fixed.
            let fixed = corners(of: original)[3 - corner]
            let rect = CGRect(x: min(fixed.x, p.x), y: min(fixed.y, p.y), width: max(8, abs(p.x - fixed.x)), height: max(8, abs(p.y - fixed.y)))
            model.drag(to: rect)
        case .lasso:
            let clamped = CGPoint(x: min(max(0, p.x), model.pageSize.width), y: min(max(0, p.y), model.pageSize.height))
            if let last = lasso.last, hypot(clamped.x - last.x, clamped.y - last.y) * magnification < 2 { return }
            lasso.append(clamped)
            needsDisplay = true
        case .brush(let last):
            let dirty = model.stroke(to: p, from: last)
            dragMode = .brush(last: p)
            setNeedsDisplay(dirty.insetBy(dx: -4, dy: -4))
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch dragMode {
        case .move, .resize: model.endDrag()
        case .brush: model.endStroke()
        case .marquee: marquee = nil
        case .lasso:
            model.addFromLasso(lasso)
            lasso = []
        case .none: break
        }
        dragMode = .none
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        mouse = point(event)
        if model.tool.isBrush { needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        mouse = nil
        needsDisplay = true
    }

    /// Edit › Select All (⌘A) while the canvas has focus selects every text box.
    @objc override func selectAll(_ sender: Any?) {
        model.tool = .select
        model.selectAll()
    }

    /// Single-key shortcuts, only while the canvas (not a text field) has focus.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {   // delete, forward delete
            model.deleteSelected()
            return
        }
        if event.keyCode == 53 {   // escape
            if case .lasso = dragMode {
                dragMode = .none
                lasso = []
                needsDisplay = true
            } else {
                model.selection = []
            }
            return
        }
        if let key = event.charactersIgnoringModifiers?.first, let tool = EditorModel.Tool.allCases.first(where: { $0.key == key }) {
            model.tool = tool
            return
        }
        switch event.charactersIgnoringModifiers {
        case "[": model.brushSize = max(4, model.brushSize / 1.2)
        case "]": model.brushSize = min(200, model.brushSize * 1.2)
        default: super.keyDown(with: event)
        }
    }
}
