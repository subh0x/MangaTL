import AppKit
import MangaTLCore
import SwiftUI

/// Per-role lettering presets for the project (dialogue, thought, shout, whisper, narration, SFX),
/// with a live preview. Boxes without their own style follow these.
struct PresetsView: View {
    @Bindable var project: ProjectSession
    @Environment(\.dismiss) private var dismiss
    @State private var role: TextRole = .dialogue
    @State private var choosingFont = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                List(TextRole.allCases, selection: $role) { role in
                    Label(role.displayName, systemImage: Self.symbol(role)).tag(role)
                }
                .listStyle(.sidebar)
                .frame(width: 170)
                Divider()
                VStack(spacing: 0) {
                    PresetPreview(text: Self.sample(role), style: style.wrappedValue,
                                  shape: role == .narration ? .rectangle : .ellipse)
                        .frame(height: 170)
                        .padding(12)
                    Divider()
                    Form { controls }
                        .formStyle(.grouped)
                }
            }
            Divider()
            HStack {
                Button("Reset \(role.displayName) to Default") { reset() }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 640, height: 600)
    }

    /// The preset being edited: dialogue is the project's base style, other roles override it.
    private var style: Binding<TextStyle> {
        Binding(
            get: { project.settings.style(for: role) },
            set: { new in
                if role == .dialogue {
                    project.settings.style = new
                } else {
                    var presets = project.settings.roleStyles ?? [:]
                    presets[role] = new
                    project.settings.roleStyles = presets
                }
                project.stylesChanged()
            }
        )
    }

    private func field<T>(_ key: WritableKeyPath<TextStyle, T>) -> Binding<T> {
        Binding(get: { style.wrappedValue[keyPath: key] }, set: { style.wrappedValue[keyPath: key] = $0 })
    }

    @ViewBuilder private var controls: some View {
        Section("Font") {
            LabeledContent("Family") {
                Button(CTFontCopyFamilyName(CTFontCreateWithName(style.wrappedValue.fontName as CFString, 12, nil)) as String) {
                    choosingFont = true
                }
                .popover(isPresented: $choosingFont, arrowEdge: .trailing) {
                    FontFamilyList { family in
                        field(\.fontName).wrappedValue = family.map(Inspector.preferredMember) ?? TextStyle.defaultFontName
                        choosingFont = false
                    }
                }
            }
            Toggle("Bold", isOn: field(\.bold))
            Toggle("Italic", isOn: field(\.italic))
            Toggle("Uppercase", isOn: field(\.uppercase))
            Picker("Alignment", selection: field(\.alignment)) {
                Image(systemName: "text.alignleft").tag(MangaTLCore.TextAlignment.left)
                Image(systemName: "text.aligncenter").tag(MangaTLCore.TextAlignment.center)
                Image(systemName: "text.alignright").tag(MangaTLCore.TextAlignment.right)
            }
            .pickerStyle(.segmented)
        }
        Section("Size") {
            LabeledContent("Auto-fit scale") { percent(field(\.sizeFactor), 0.6...1.2) }
                .tip("How large text is relative to the largest size that fits (e.g. 85% for whispers)")
            LabeledContent("Width") { percent(field(\.horizontalScale), 0.7...1.3) }
            LabeledContent("Height") { percent(field(\.verticalScale), 0.8...1.6) }
            LabeledContent("Line height") { percent(field(\.lineHeight), 0.7...1.8) }
            LabeledContent("Space inside") { percent(field(\.padding), 0...0.3) }
        }
        Section("Colour") {
            LabeledContent("Text") { ColorField(color: field(\.color)) }
            LabeledContent("Outline") { ColorField(color: field(\.strokeColor)) }
            LabeledContent("Outline width") {
                HStack {
                    Slider(value: field(\.strokeWidth), in: 0...12)
                    Text("\(Int(style.wrappedValue.strokeWidth)) px").monospacedDigit().foregroundStyle(.secondary).frame(width: 40)
                }
            }
        }
    }

    private func percent(_ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack(spacing: 6) {
            Slider(value: value, in: range)
            Text("\(Int((value.wrappedValue * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }

    private func reset() {
        if role == .dialogue {
            project.settings.style = TextStyle()
        } else {
            project.settings.roleStyles?[role] = nil
        }
        project.stylesChanged()
    }

    static func symbol(_ role: TextRole) -> String {
        switch role {
        case .dialogue: "bubble.left"
        case .thought: "cloud"
        case .shout: "exclamationmark.bubble"
        case .whisper: "ellipsis.bubble"
        case .narration: "text.alignleft"
        case .sfx: "burst"
        }
    }

    static func sample(_ role: TextRole) -> String {
        switch role {
        case .dialogue: "Wait, you came all this way just to see me?"
        case .thought: "(I hope nobody noticed...)"
        case .shout: "GET OUT OF THE WAY!!"
        case .whisper: "Psst... over here."
        case .narration: "Three days later, at the edge of the city."
        case .sfx: "BOOM"
        }
    }
}

/// Renders sample text in a balloon with the shared typesetter, exactly as pages are lettered.
private struct PresetPreview: View {
    let text: String
    let style: TextStyle
    let shape: BlockShape

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let frame = CGRect(x: size.width * 0.2, y: 8, width: size.width * 0.6, height: size.height - 16)
                let outline = shape == .ellipse ? Path(ellipseIn: frame) : Path(roundedRect: frame, cornerRadius: 4)
                context.fill(outline, with: .color(.white))
                context.stroke(outline, with: .color(.black), lineWidth: 2)
                context.withCGContext { ctx in
                    // Typesetter draws bottom-left; flip into SwiftUI's top-left canvas.
                    ctx.translateBy(x: 0, y: size.height)
                    ctx.scaleBy(x: 1, y: -1)
                    let flipped = CGRect(x: frame.minX, y: size.height - frame.maxY, width: frame.width, height: frame.height)
                    if let layout = Typesetter.layout(text, in: flipped, shape: shape, style: style, scale: 1) {
                        Typesetter.draw(layout, style: style, in: ctx, scale: 1)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color(nsColor: .underPageBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}
