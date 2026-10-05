import AppKit
import MangaTLCore
import SwiftUI

/// The one colour control used everywhere (inspector, presets, toolbar): a bordered button with a
/// swatch and the hex value that opens a popover with preset and recent swatches, a `#RRGGBB`
/// field and the system colour panel. SwiftUI's `ColorPicker` isn't used: it renders as a wide pill
/// in forms and toolbars, and a form shows a text field's title as a stray label.
struct ColorField: View {
    @Binding var color: RGBA
    /// The toolbar hides the hex text to save space; it is otherwise the same button.
    var showsHex = true
    var help = "Colour"
    @State private var showingPopover = false

    var body: some View {
        Button { showingPopover.toggle() } label: {
            HStack(spacing: 6) {
                ColorSwatch(color: color)
                    .frame(width: 20, height: 14)
                if showsHex {
                    Text(color.hex)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 2)
        }
        .buttonStyle(.bordered)
        .fixedSize()
        .tip("\(help) \(color.hex)")
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            ColorPopover(color: $color)
        }
        .onChange(of: color) { _, new in RecentColors.shared.use(new) }
    }
}

/// A rounded colour chip with a hairline edge (so white shows on light backgrounds).
private struct ColorSwatch: View {
    let color: RGBA
    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color(cgColor: color.cgColor))
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(.primary.opacity(0.25), lineWidth: 0.5))
    }
}

struct ColorPopover: View {
    @Binding var color: RGBA
    @State private var text = ""
    @State private var invalid = false
    @FocusState private var editingHex: Bool

    static let presets: [RGBA] = [
        .white, RGBA(0.75, 0.75, 0.75), RGBA(0.5, 0.5, 0.5), RGBA(0.25, 0.25, 0.25), .black, RGBA(0.86, 0.16, 0.16),
        RGBA(0.98, 0.55, 0.1), RGBA(0.98, 0.84, 0.15), RGBA(0.2, 0.7, 0.3), RGBA(0.12, 0.47, 0.95), RGBA(0.55, 0.3, 0.85), RGBA(0.95, 0.4, 0.65),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            swatches(Self.presets)
            let recent = RecentColors.shared.colors.filter { !Self.presets.contains($0) }
            if !recent.isEmpty {
                Text("Recent").font(.caption).foregroundStyle(.secondary)
                swatches(recent)
            }
            Divider()
            HStack(spacing: 8) {
                TextField("", text: $text, prompt: Text("#RRGGBB"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .frame(width: 96)
                    .foregroundStyle(invalid ? .red : .primary)
                    .focused($editingHex)
                    .onSubmit(apply)
                    .onChange(of: editingHex) { _, editing in if !editing { apply() } }
                    .tip("Hex colour, e.g. #1A2B3C or #FFF")
                Spacer(minLength: 0)
                Button("More Colours…") { ColorPanelBridge.shared.open(for: $color) }
            }
        }
        .padding(12)
        .frame(width: 252)
        // Opened from the toolbar, it would inherit the toolbar's large controls.
        .controlSize(.regular)
        .onAppear { text = color.hex }
        .onChange(of: color) { _, new in
            text = new.hex
            invalid = false
        }
    }

    private func swatches(_ colors: [RGBA]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 8), count: 6), spacing: 8) {
            ForEach(colors, id: \.self) { swatch in
                Button { color = swatch } label: {
                    ColorSwatch(color: swatch)
                        .frame(width: 28, height: 20)
                        .padding(2)
                        .overlay {
                            if swatch == color {
                                RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .tip(swatch.hex)
            }
        }
    }

    private func apply() {
        guard text != color.hex else { return }
        if let parsed = RGBA(hex: text) {
            color = parsed
            text = parsed.hex
            invalid = false
        } else {
            invalid = true
            NSSound.beep()
        }
    }
}

/// Connects the shared system colour panel to one colour binding at a time.
@MainActor final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var binding: Binding<RGBA>?

    func open(for binding: Binding<RGBA>) {
        self.binding = binding
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = NSColor(cgColor: binding.wrappedValue.cgColor) ?? .black
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.orderFront(nil)
    }

    @objc private func changed(_ panel: NSColorPanel) {
        let c = panel.color.usingColorSpace(.sRGB) ?? .black
        binding?.wrappedValue = RGBA(c.redComponent, c.greenComponent, c.blueComponent)
    }
}

/// White, black and the last colours picked (session only).
@MainActor final class RecentColors {
    static let shared = RecentColors()
    private(set) var colors: [RGBA] = [.white, .black]

    func use(_ color: RGBA) {
        let recent = colors.dropFirst(2).filter { $0 != color }
        guard color != .white, color != .black else { return }
        colors = [.white, .black] + Array(([color] + recent).prefix(6))
    }
}
