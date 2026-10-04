import AppKit
import MangaTLCore
import SwiftUI
import UniformTypeIdentifiers

/// Collapsible list of the project's pages (reader and editor): click to jump, drag to reorder.
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

    private var current: Int { editorPage ?? position.page }
    @State private var dropTarget: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(project.pages.indices, id: \.self) { index in
                        PageSidebarRow(project: project, index: index, pageID: project.pages[index].id, isCurrent: index == current)
                            .id(index)
                            .overlay(alignment: .top) {
                                if dropTarget == index {
                                    Rectangle().fill(Color.accentColor).frame(height: 2).offset(y: -2)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { if index != current { onSelect(index) } }
                            .onDrag { NSItemProvider(object: String(index) as NSString) }
                            .onDrop(of: [.text], delegate: PageDrop(index: index, project: project, target: $dropTarget))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .onAppear { proxy.scrollTo(current, anchor: .center) }
            .onChange(of: current) { _, page in proxy.scrollTo(page) }
        }
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
        .background(isCurrent ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
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
