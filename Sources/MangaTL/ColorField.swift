import AppKit
import MangaTLCore
import SwiftUI

/// The macOS colour well plus a `#RRGGBB` field, kept in sync.
/// `.compact` (for toolbars) is a small swatch that opens the same controls in a popover; toolbars
/// stretch a `ColorPicker` into a pill and strip a text field's border.
struct ColorField: View {
    enum Style { case inline, compact }

    @Binding var color: RGBA
    var style: Style = .inline
    @State private var text = ""
    @State private var invalid = false
    @State private var showingPopover = false

    var body: some View {
        switch style {
        case .inline: inline
        case .compact: compact
        }
    }

    private var compact: some View {
        Button { showingPopover.toggle() } label: {
            Circle()
                .fill(Color(cgColor: color.cgColor))
                .overlay(Circle().strokeBorder(.secondary.opacity(0.6), lineWidth: 0.5))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .tip("Brush colour \(color.hex)")
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                inline
                HStack(spacing: 6) {
                    ForEach(RecentColors.shared.colors, id: \.self) { swatch in
                        Button { color = swatch } label: {
                            Circle()
                                .fill(Color(cgColor: swatch.cgColor))
                                .overlay(Circle().strokeBorder(.secondary.opacity(0.6), lineWidth: 0.5))
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.borderless)
                        .tip(swatch.hex)
                    }
                }
            }
            .padding(12)
        }
        .onChange(of: color) { _, new in RecentColors.shared.use(new) }
    }

    private var inline: some View {
        HStack(spacing: 6) {
            ColorPicker("", selection: rgbaBinding($color), supportsOpacity: false)
                .labelsHidden()
                .fixedSize()
            TextField("#RRGGBB", text: $text)
                .font(.body.monospaced())
                .frame(width: 84)
                .textFieldStyle(.roundedBorder)
                .foregroundStyle(invalid ? .red : .primary)
                .onSubmit(apply)
                .tip("Hex colour, e.g. #1A2B3C or #FFF")
        }
        .onAppear { text = color.hex }
        .onChange(of: color) { _, new in
            text = new.hex
            invalid = false
        }
    }

    private func apply() {
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

func rgbaBinding(_ binding: Binding<RGBA>) -> Binding<Color> {
    Binding(
        get: { Color(cgColor: binding.wrappedValue.cgColor) },
        set: { color in
            let c = NSColor(color).usingColorSpace(.sRGB) ?? .black
            binding.wrappedValue = RGBA(c.redComponent, c.greenComponent, c.blueComponent)
        }
    )
}
