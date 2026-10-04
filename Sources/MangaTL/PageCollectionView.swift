import AppKit
import IOSurface
import MangaTLCore
import SwiftUI

/// Reader zoom: a fixed page width, or fitted to the window.
enum ReaderZoom: Equatable {
    case column(CGFloat)
    case fitWidth
    case fitHeight
}

enum PageLayoutMode: Equatable {
    /// Thumbnail grid of the whole project.
    case grid
    /// One continuous vertical column of pages decoded at screen size.
    case reader
}

/// `NSCollectionView` (cell reuse + async decode with cancellation) wrapped for SwiftUI.
/// Only on-screen cells hold pixels; a cell drops its image as soon as it is reused.
struct PageCollectionView: NSViewRepresentable {
    let project: ProjectSession
    let mode: PageLayoutMode
    /// Reader shows untranslated originals when true.
    var showOriginal = false
    let position: ReadingPosition
    /// Grid thumbnail width in points.
    var gridSize: CGFloat = 150
    var readerZoom: ReaderZoom = .column(ReaderLayout.defaultColumnWidth)
    var onOpenPage: (Int) -> Void
    var onEditPage: (Int) -> Void = { _ in }
    /// Trackpad pinch: new grid size, or new reader zoom.
    var onGridSize: (CGFloat) -> Void = { _ in }
    var onReaderZoom: (ReaderZoom) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let collection = PageGridView()
        collection.collectionViewLayout = NSCollectionViewFlowLayout()
        collection.dataSource = context.coordinator
        collection.delegate = context.coordinator
        collection.isSelectable = true
        collection.backgroundColors = [.windowBackgroundColor]
        collection.register(PageItem.self, forItemWithIdentifier: PageItem.identifier)
        // Drag thumbnails to reorder; drop image files to add pages.
        collection.registerForDraggedTypes([PageGridView.pageType, .fileURL])
        collection.setDraggingSourceOperationMask(.move, forLocal: true)
        collection.menuProvider = { [weak coordinator = context.coordinator] index in coordinator?.menu(for: index) }
        collection.addGestureRecognizer(NSMagnificationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinched(_:))))
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleClicked(_:)))
        click.numberOfClicksRequired = 2
        click.delaysPrimaryMouseButtonEvents = false
        collection.addGestureRecognizer(click)

        let scroll = NSScrollView()
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.resized(_:)),
                                               name: NSView.frameDidChangeNotification, object: scroll)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        context.coordinator.collection = collection
        context.coordinator.setGridSize(gridSize, anchor: false)
        context.coordinator.readerZoom = readerZoom
        context.coordinator.apply(mode: mode, scrollTo: position.page)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.project !== project || coordinator.mode != mode || coordinator.showOriginal != showOriginal {
            coordinator.project = project
            coordinator.showOriginal = showOriginal
            coordinator.setGridSize(gridSize, anchor: false)
            coordinator.readerZoom = readerZoom
            coordinator.apply(mode: mode, scrollTo: position.page)
        } else {
            coordinator.setGridSize(gridSize, anchor: true)
            if coordinator.readerZoom != readerZoom {
                coordinator.readerZoom = readerZoom
                coordinator.applyReaderZoom()
            }
        }
        // Sidebar / page-number jumps.
        if let target = position.jump {
            DispatchQueue.main.async { position.jump = nil }
            coordinator.scroll(toPage: target)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        var parent: PageCollectionView
        var project: ProjectSession {
            didSet { observe(project) }
        }
        var cache: ThumbnailCache { project.cache }
        var mode: PageLayoutMode
        var showOriginal: Bool
        weak var collection: NSCollectionView?
        /// Two decode workers keep scrolling responsive without flooding memory.
        let queue: OperationQueue = {
            let q = OperationQueue()
            q.maxConcurrentOperationCount = 2
            q.qualityOfService = .userInitiated
            return q
        }()
        private let gridLayout: NSCollectionViewFlowLayout = {
            let layout = NSCollectionViewFlowLayout()
            layout.itemSize = NSSize(width: 150, height: 236)
            layout.minimumInteritemSpacing = 12
            layout.minimumLineSpacing = 16
            layout.sectionInset = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
            return layout
        }()
        private let readerLayout = ReaderLayout()
        var readerZoom: ReaderZoom = .column(ReaderLayout.defaultColumnWidth)
        private var gridSize: CGFloat = 150
        private var pinchStart: CGFloat = 0
        /// Reader page aspect ratios learned from full decodes (thumbnails fill the rest).
        private var readerAspects: [Int: CGFloat] = [:]
        private var focusUpdatePending = false
        static let readerMaxPixels = 2400

        init(_ parent: PageCollectionView) {
            self.parent = parent
            project = parent.project
            mode = parent.mode
            showOriginal = parent.showOriginal
            super.init()
            readerLayout.aspectProvider = { [unowned self] in readerAspects[$0] ?? cache.aspect($0) }
            observe(project)
        }

        /// Re-renders a page in place when its translation changes.
        private func observe(_ project: ProjectSession) {
            project.addObserver(self) { [weak self] index in
                guard let self, let collection = self.collection, index >= 0, index < collection.numberOfItems(inSection: 0) else { return }
                collection.reloadItems(at: [IndexPath(item: index, section: 0)])
            } pagesChanged: { [weak self] in
                guard let self else { return }
                self.readerAspects = [:]
                self.collection?.reloadData()
            }
        }

        // MARK: Zoom

        /// Grid thumbnail width; with `anchor`, the top visible page stays in view.
        func setGridSize(_ size: CGFloat, anchor: Bool) {
            guard size != gridSize || gridLayout.itemSize.width != size else { return }
            let top = anchor && mode == .grid ? collection?.indexPathsForVisibleItems().map(\.item).min() : nil
            let reloadTier = (gridSize > 170) != (size > 170)
            gridSize = size
            gridLayout.itemSize = NSSize(width: size.rounded(), height: (size * 1.42).rounded() + 20)
            gridLayout.minimumInteritemSpacing = max(8, size * 0.08)
            gridLayout.minimumLineSpacing = max(10, size * 0.1)
            guard mode == .grid, let collection else { return }
            if reloadTier { collection.reloadData() } else { gridLayout.invalidateLayout() }
            if let top {
                collection.layoutSubtreeIfNeeded()
                collection.scrollToItems(at: [IndexPath(item: top, section: 0)], scrollPosition: .top)
            }
        }

        /// Turns the reader zoom into a page width for the current window and keeps the top page in view.
        func applyReaderZoom() {
            guard let collection, let scroll = collection.enclosingScrollView else { return }
            let visible = scroll.contentSize
            let top = readerLayout.index(atY: scroll.contentView.bounds.minY + 1)
            let column: CGFloat = switch readerZoom {
            case .column(let width): width
            case .fitWidth: visible.width
            case .fitHeight:
                (visible.height - 2 * ReaderLayout.spacing) * (readerAspects[top] ?? cache.aspect(top) ?? ReaderLayout.defaultAspect)
            }
            let clamped = min(max(column, 200), 4000)
            guard abs(readerLayout.columnLimit - clamped) > 0.5 else { return }
            readerLayout.columnLimit = clamped
            guard mode == .reader else { return }
            collection.reloadData()   // decode size follows the width
            collection.layoutSubtreeIfNeeded()
            collection.scroll(NSPoint(x: 0, y: readerLayout.top(of: top) - ReaderLayout.spacing))
        }

        func scroll(toPage page: Int) {
            guard let collection, page >= 0, page < project.count else { return }
            collection.layoutSubtreeIfNeeded()
            switch mode {
            case .grid: collection.scrollToItems(at: [IndexPath(item: page, section: 0)], scrollPosition: .centeredVertically)
            case .reader: collection.scroll(NSPoint(x: 0, y: readerLayout.top(of: page) - ReaderLayout.spacing))
            }
        }

        @objc func resized(_ note: Notification) {
            if mode == .reader, readerZoom != .column(readerLayout.columnLimit) { applyReaderZoom() }
        }

        /// Trackpad pinch: grid thumbnail size, or reader page width.
        @objc func pinched(_ gesture: NSMagnificationGestureRecognizer) {
            switch gesture.state {
            case .began:
                pinchStart = mode == .grid ? gridSize : readerLayout.columnWidth
            case .changed, .ended:
                let value = pinchStart * (1 + gesture.magnification)
                if mode == .grid {
                    parent.onGridSize(min(max(value, 90), 360))
                } else {
                    parent.onReaderZoom(.column(min(max(value, ReaderLayout.columnRange.lowerBound), ReaderLayout.columnRange.upperBound)))
                }
            default: break
            }
        }

        func apply(mode: PageLayoutMode, scrollTo page: Int) {
            self.mode = mode
            queue.cancelAllOperations()
            readerAspects = [:]
            guard let collection else { return }
            collection.collectionViewLayout = mode == .grid ? gridLayout : readerLayout
            if mode == .reader {
                // Width for the zoom before the first layout.
                if case .column(let width) = readerZoom { readerLayout.columnLimit = width }
                DispatchQueue.main.async { self.applyReaderZoom() }
            }
            collection.reloadData()
            let count = project.count
            guard count > 0 else { return }
            let target = min(max(page, 0), count - 1)
            collection.layoutSubtreeIfNeeded()
            switch mode {
            case .grid:
                collection.scrollToItems(at: [IndexPath(item: target, section: 0)], scrollPosition: .centeredVertically)
            case .reader:
                collection.scroll(NSPoint(x: 0, y: readerLayout.top(of: target) - ReaderLayout.spacing))
            }
        }

        // MARK: Data source

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { project.count }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: PageItem.identifier, for: indexPath) as! PageItem
            let large = gridSize > 170
            let index = indexPath.item
            let translated = project.isTranslated(index)
            item.configure(index: index, caption: mode == .grid ? (translated ? "\(index + 1) ✓" : "\(index + 1)") : nil)
            switch mode {
            case .grid:
                if let image = cache.cached(index, large: large) {
                    item.show(image)
                } else {
                    load(into: item, index: index) { [cache] in try cache.load(index, large: large) }
                }
            case .reader:
                let pixels = readerPixelSize(collectionView)
                let (source, store, settings) = (project.source, project.store, project.settings)
                let composite = translated && !showOriginal
                let key = project.pageKey(index)
                load(into: item, index: index) {
                    var image = try source.image(at: index, maxPixelSize: pixels)
                    if composite, let doc = store.loadPage(key),
                       let rendered = PageRenderer.render(page: image, doc: doc, layers: store.visibleLayers(of: doc, page: key), settings: settings) {
                        image = rendered
                    }
                    return (DisplaySurface.make(from: image) as Any?) ?? image
                }
            }
            return item
        }

        /// Decodes off the main thread; `decode` returns layer contents (CGImage or IOSurface).
        private func load(into item: PageItem, index: Int, decode: @escaping @Sendable () throws -> Any) {
            let op = BlockOperation()
            op.addExecutionBlock { [weak op] in
                guard let op, !op.isCancelled, let contents = try? decode() else { return }
                let box = UncheckedContents(contents)
                OperationQueue.main.addOperation { [weak self, weak item] in
                    MainActor.assumeIsolated {
                        guard let self, let item, !op.isCancelled, item.index == index else { return }
                        item.show(box.contents)
                        self.learnAspect(of: box.contents, index: index)
                    }
                }
            }
            item.pending = op
            queue.addOperation(op)
        }

        private func learnAspect(of contents: Any, index: Int) {
            guard mode == .reader, let collection, let scroll = collection.enclosingScrollView else { return }
            let size: CGSize
            if CFGetTypeID(contents as CFTypeRef) == CGImage.typeID {
                let image = contents as! CGImage
                size = CGSize(width: image.width, height: image.height)
            } else if let surface = contents as? IOSurface {
                size = CGSize(width: surface.width, height: surface.height)
            } else { return }
            let aspect = size.width / max(1, size.height)
            readerAspects[index] = aspect
            let delta = readerLayout.setAspect(aspect, at: index, anchorY: scroll.contentView.bounds.minY)
            if delta != 0 {
                var origin = scroll.contentView.bounds.origin
                origin.y += delta
                scroll.contentView.scroll(to: origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }

        private func readerPixelSize(_ collectionView: NSCollectionView) -> Int {
            let scale = collectionView.window?.backingScaleFactor ?? 2
            return min(Self.readerMaxPixels, Int(readerLayout.columnWidth * scale / ReaderLayout.defaultAspect))
        }

        func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
            (item as? PageItem)?.clear()
        }

        // MARK: Reorder and add pages (grid)

        func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
            mode == .grid
        }

        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            let item = NSPasteboardItem()
            item.setString(String(indexPath.item), forType: PageGridView.pageType)
            return item
        }

        func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                            proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                            dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
            guard mode == .grid else { return [] }
            if dropOperation.pointee == .on { dropOperation.pointee = .before }
            let isInternal = draggingInfo.draggingSource as? NSCollectionView === collectionView
            return isInternal ? .move : .copy
        }

        func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
                            indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
            if draggingInfo.draggingSource as? NSCollectionView === collectionView {
                let moving = IndexSet(collectionView.selectionIndexPaths.map(\.item))
                let offsets = moving.isEmpty
                    ? IndexSet((draggingInfo.draggingPasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: PageGridView.pageType).flatMap(Int.init) })
                    : moving
                guard !offsets.isEmpty else { return false }
                project.move(fromOffsets: offsets, toOffset: indexPath.item)
                return true
            }
            let urls = draggingInfo.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            guard !urls.isEmpty else { return false }
            project.addImages(urls, at: indexPath.item)
            return true
        }

        /// Right-click menu for a page (nil = empty space).
        func menu(for index: Int?) -> NSMenu? {
            let menu = NSMenu()
            func add(_ title: String, enabled: Bool = true, _ action: @escaping () -> Void) {
                let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
                let target = MenuAction(action)
                item.target = target
                item.representedObject = target
                item.isEnabled = enabled
                menu.addItem(item)
            }
            guard let index, index < project.count else {
                add("Add Images…") { [weak self] in self?.chooseImages(at: self?.project.count ?? 0) }
                return menu
            }
            let selected = IndexSet((collection?.selectionIndexPaths ?? []).map(\.item))
            let targets = selected.contains(index) ? selected : IndexSet(integer: index)
            let label = targets.count > 1 ? "\(targets.count) Pages" : "Page"
            add("Open in Reader") { [weak self] in self?.parent.onOpenPage(index) }
            add("Edit Page") { [weak self] in self?.parent.onEditPage(index) }
            add(targets.count > 1 ? "Translate \(label)" : "Translate Page") { [weak self] in
                self?.project.translate(pages: Array(targets), redo: true)
            }
            menu.addItem(.separator())
            add("Move \(label) to Start", enabled: targets.first != 0) { [weak self] in self?.project.move(fromOffsets: targets, toOffset: 0) }
            add("Move \(label) to End", enabled: targets.last != project.count - 1) { [weak self] in
                guard let self else { return }
                self.project.move(fromOffsets: targets, toOffset: self.project.count)
            }
            add("Add Images After…") { [weak self] in self?.chooseImages(at: (targets.last ?? index) + 1) }
            menu.addItem(.separator())
            add("Show in Finder") { [weak self] in
                guard let self else { return }
                let url = self.project.source.folder.appendingPathComponent(self.project.pages[index].file)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            add("Remove \(label) from Project", enabled: targets.count < project.count) { [weak self] in
                self?.project.remove(atOffsets: targets)
            }
            return menu
        }

        func chooseImages(at index: Int) {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.allowedContentTypes = [.image]
            panel.prompt = "Add"
            panel.message = "The images are copied into the project folder."
            if panel.runModal() == .OK { project.addImages(panel.urls, at: index) }
        }

        // MARK: Events

        @objc func doubleClicked(_ gesture: NSClickGestureRecognizer) {
            guard let collection, let path = collection.indexPathForItem(at: gesture.location(in: collection)) else { return }
            parent.onOpenPage(path.item)
        }

        /// Publishes the top visible page at most ~6×/s so SwiftUI isn't re-rendered every frame.
        @objc func scrolled(_ note: Notification) {
            guard !focusUpdatePending else { return }
            focusUpdatePending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, let collection = self.collection else { return }
                self.focusUpdatePending = false
                let top = collection.enclosingScrollView?.contentView.bounds.minY ?? 0
                let page = self.mode == .reader
                    ? self.readerLayout.index(atY: top + 1)
                    : collection.indexPathsForVisibleItems().map(\.item).min() ?? 0
                if self.parent.position.page != page { self.parent.position.page = page }
            }
        }
    }
}

/// Collection view that asks its coordinator for a per-page context menu.
final class PageGridView: NSCollectionView {
    static let pageType = NSPasteboard.PasteboardType("local.mangatl.page-index")
    var menuProvider: (Int?) -> NSMenu? = { _ in nil }

    override func menu(for event: NSEvent) -> NSMenu? {
        let index = indexPathForItem(at: convert(event.locationInWindow, from: nil))?.item
        return menuProvider(index)
    }
}

/// Closure-backed target for NSMenuItem (kept alive via `representedObject`).
final class MenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}

/// CGImage / IOSurface handed from the decode worker to the main thread, never mutated after.
private struct UncheckedContents: @unchecked Sendable {
    let contents: Any
    init(_ contents: Any) { self.contents = contents }
}

/// Layer-backed cell: the CGImage goes straight into `layer.contents` (no NSImage, no extra copy).
final class PageItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PageItem")
    private(set) var index = -1
    var pending: Operation?
    private let imageLayerView = NSView()
    private let caption = NSTextField(labelWithString: "")
    private lazy var captionHeight = caption.heightAnchor.constraint(equalToConstant: 16)

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        imageLayerView.wantsLayer = true
        imageLayerView.layer?.contentsGravity = .resizeAspect
        imageLayerView.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        imageLayerView.translatesAutoresizingMaskIntoConstraints = false
        caption.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        caption.textColor = .secondaryLabelColor
        caption.alignment = .center
        caption.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageLayerView)
        view.addSubview(caption)
        NSLayoutConstraint.activate([
            imageLayerView.topAnchor.constraint(equalTo: view.topAnchor),
            imageLayerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageLayerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            caption.topAnchor.constraint(equalTo: imageLayerView.bottomAnchor, constant: 2),
            caption.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            caption.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            caption.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            captionHeight,
        ])
    }

    func configure(index: Int, caption text: String?) {
        clear()
        self.index = index
        caption.stringValue = text ?? ""
        caption.isHidden = text == nil
        captionHeight.constant = text == nil ? 0 : 16
    }

    #if DEBUG || BENCH
    var hasImage: Bool { imageLayerView.layer?.contents != nil }
    #endif

    /// `contents` is a CGImage (thumbnails) or an IOSurface (reader pages).
    func show(_ contents: Any) {
        imageLayerView.layer?.contents = contents
        imageLayerView.layer?.backgroundColor = nil
    }

    func clear() {
        pending?.cancel()
        pending = nil
        imageLayerView.layer?.contents = nil
        imageLayerView.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.borderWidth = isSelected ? 2 : 0
            view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        clear()
        index = -1
    }
}
