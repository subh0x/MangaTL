import AppKit
import MangaTLCore
import SwiftUI
import UniformTypeIdentifiers

/// Collapsible list of the project's pages (reader and editor): click to jump, drag to reorder,
/// ⌘/⇧-click to select several, Delete or the context menu to remove them from the project.
///
/// A lazy stack rather than `List`: List re-diffed all rows whenever the current page changed
/// (several times a second while reading), which cost ~15% of the main thread at 2500 pages.
/// Here only visible rows exist, and only they react to the current page.
struct PageSidebar: View {
    let project: ProjectSession
    /// Observed here (not by the window) so page changes while reading only re-render the sidebar.
    let position: ReadingPosition
    /// The editor's page, when editing.
    var editorPage: Int?
    var onSelect: (Int) -> Void
    var onRemove: (IndexSet) -> Void

    private var current: Int { editorPage ?? position.page }
    @State private var dropTarget: Int?
    /// Selected pages by id (indices shift when pages move or are removed).
    @State private var selection: Set<String> = []
    @State private var anchor: Int?
    @State private var confirming: IndexSet?
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(project.pages.indices, id: \.self) { index in
                        PageSidebarRow(project: project, index: index, pageID: project.pages[index].id, isCurrent: index == current,
                                       isSelected: selection.contains(project.pages[index].id))
                            .id(index)
                            .overlay(alignment: .top) {
                                if dropTarget == index {
                                    Rectangle().fill(Color.accentColor).frame(height: 2).offset(y: -2)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { tap(index) }
                            .contextMenu {
                                let pages = targets(clicked: index)
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting(pages.map { project.source.folder.appendingPathComponent(project.pages[$0].file) })
                                }
                                Divider()
                                Button(pages.count > 1 ? "Delete \(pages.count) Pages from Project…" : "Delete Page from Project…", role: .destructive) {
                                    confirming = pages
                                }
                                .disabled(pages.count >= project.count)
                            }
                            .onDrag { NSItemProvider(object: String(index) as NSString) }
                            .onDrop(of: [.text], delegate: PageDrop(index: index, project: project, target: $dropTarget))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                let pages = targets(clicked: nil)
                guard pages.count < project.count else { return .ignored }
                confirming = pages
                return .handled
            }
            .onAppear { proxy.scrollTo(current, anchor: .center) }
            .onChange(of: current) { _, page in proxy.scrollTo(page) }
            .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
                Button("Delete", role: .destructive) {
                    if let pages = confirming { onRemove(pages) }
                    confirming = nil
                    selection = []
                    anchor = nil
                }
            } message: {
                Text("The pages leave this project and their translations are discarded. The image files stay in the folder; Add Images brings them back.")
            }
        }
    }

    private var confirmTitle: String {
        let n = confirming?.count ?? 0
        return n == 1 ? "Delete page \((confirming?.first ?? 0) + 1) from the project?" : "Delete \(n) pages from the project?"
    }

    /// Click: go to the page. ⌘-click: add or remove it from the selection. ⇧-click: select a range.
    private func tap(_ index: Int) {
        focused = true
        let id = project.pages[index].id, flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.isEmpty { selection = [project.pages[current].id] }
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = index
        } else if flags.contains(.shift) {
            let from = anchor ?? current
            selection = Set(project.pages[min(from, index)...max(from, index)].map(\.id))
        } else {
            selection = [id]
            anchor = index
            if index != current { onSelect(index) }
        }
    }

    /// Pages an action applies to: the selection when it includes the clicked page (or for keys),
    /// else just the clicked page; the current page when nothing is selected.
    private func targets(clicked: Int?) -> IndexSet {
        let selected = IndexSet(project.pages.indices.filter { selection.contains(project.pages[$0].id) })
        if let clicked { return selected.contains(clicked) ? selected : [clicked] }
        return selected.isEmpty ? [current] : selected
    }
}

/// The sidebar's right edge: a hairline with a wider invisible handle for dragging its width.
struct SidebarResizer: View {
    @Binding var width: Double
    static let range = 160.0...260.0
    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear
                    .frame(width: 7)
                    .contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.columnResize.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { drag in
                            let base = start ?? width
                            start = base
                            width = min(Self.range.upperBound, max(Self.range.lowerBound, base + drag.translation.width))
                        }
                        .onEnded { _ in start = nil })
            }
            .accessibilityHidden(true)
    }
}

/// Dropping a dragged page row before `index` moves it there.
private struct PageDrop: DropDelegate {
    let index: Int
    let project: ProjectSession
    @Binding var target: Int?

    func dropEntered(info: DropInfo) { target = index }
    func dropExited(info: DropInfo) { if target == index { target = nil } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        target = nil
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let from = (object as? String).flatMap(Int.init) else { return }
            Task { @MainActor in
                if from != index { project.move(fromOffsets: [from], toOffset: index) }
            }
        }
        return true
    }
}

private struct PageSidebarRow: View {
    let project: ProjectSession
    let index: Int
    let pageID: String
    let isCurrent: Bool
    let isSelected: Bool
    @State private var thumbnail: CGImage?

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 44, height: 62)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(index + 1)").font(.body.monospacedDigit().weight(.medium))
                // Read in body so the mark appears as soon as the page is translated or saved.
                if project.translatedIDs.contains(pageID) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                        .accessibilityLabel("Translated")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(isCurrent ? Color.accentColor.opacity(0.25) : isSelected ? Color.accentColor.opacity(0.14) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .task(id: pageID) {
            let cache = project.cache
            let index = index
            if let hit = cache.cached(index) {
                thumbnail = hit
            } else {
                thumbnail = await Task.detached(priority: .utility) { try? cache.load(index) }.value
            }
        }
    }
}
