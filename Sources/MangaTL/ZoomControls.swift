import SwiftUI

/// Status-bar zoom for the grid (thumbnail size) and the reader (page width, Fit Width/Height).
/// The editor has its own zoom in the toolbar.
struct ZoomControls: View {
    let mode: PageLayoutMode
    @Binding var gridSize: CGFloat
    @Binding var readerZoom: ReaderZoom
    /// The reader's current page width (for the slider when a fit mode is active).
    var readerColumn: CGFloat

    static let gridRange: ClosedRange<CGFloat> = 90...360
    static let gridDefault: CGFloat = 150

    var body: some View {
        HStack(spacing: 6) {
            Button { step(-1) } label: { Image(systemName: "minus.magnifyingglass") }
                .keyboardShortcut("-")
                .tip(mode == .grid ? "Smaller thumbnails" : "Zoom out", shortcut: "⌘-")
            Slider(value: sliderValue, in: range)
                .controlSize(.mini)
                .frame(width: 90)
                .tip(mode == .grid ? "Thumbnail size" : "Page width")
            Button { step(1) } label: { Image(systemName: "plus.magnifyingglass") }
                .keyboardShortcut("=")
                .tip(mode == .grid ? "Larger thumbnails" : "Zoom in", shortcut: "⌘=")
            if mode == .reader {
                Text(label).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                Button { readerZoom = .fitWidth } label: { Image(systemName: "arrow.left.and.right.square") }
                    .tip("Fit width")
                    .foregroundStyle(readerZoom == .fitWidth ? Color.accentColor : .primary)
                Button { readerZoom = .fitHeight } label: { Image(systemName: "arrow.up.and.down.square") }
                    .keyboardShortcut("0")
                    .tip("Fit height: a whole page on screen", shortcut: "⌘0")
                    .foregroundStyle(readerZoom == .fitHeight ? Color.accentColor : .primary)
            } else {
                Button { gridSize = Self.gridDefault } label: { Image(systemName: "square.grid.3x3") }
                    .keyboardShortcut("0")
                    .tip("Default thumbnail size", shortcut: "⌘0")
            }
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
    }

    private var range: ClosedRange<CGFloat> {
        mode == .grid ? Self.gridRange : ReaderLayout.columnRange
    }

    private var current: CGFloat {
        if mode == .grid { return gridSize }
        if case .column(let width) = readerZoom { return width }
        return readerColumn
    }

    private var sliderValue: Binding<CGFloat> {
        Binding(get: { min(max(current, range.lowerBound), range.upperBound) }, set: { set($0) })
    }

    private var label: String {
        switch readerZoom {
        case .fitWidth: "Width"
        case .fitHeight: "Page"
        case .column(let width): "\(Int((width / ReaderLayout.defaultColumnWidth * 100).rounded()))%"
        }
    }

    private func step(_ direction: CGFloat) {
        set(current * (direction > 0 ? 1.15 : 1 / 1.15))
    }

    private func set(_ value: CGFloat) {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        if mode == .grid { gridSize = clamped.rounded() } else { readerZoom = .column(clamped.rounded()) }
    }
}
