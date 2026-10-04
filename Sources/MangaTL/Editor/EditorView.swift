import AppKit
import MangaTLCore
import SwiftUI
import UniformTypeIdentifiers

/// Editor content: the canvas, with the layers + inspector panel on the right. Its controls live
/// in the window toolbar (`EditorToolbar`) so every mode shares one chrome.
struct EditorView: View {
    @Bindable var model: EditorModel
    /// The user's choice (⌥⌘I); the panel also hides itself when the window is too narrow.
    let inspectorPreferred: Bool
    @State private var width: CGFloat = 1200
    static let inspectorMinWindowWidth: CGFloat = 900

    var body: some View {
        HStack(spacing: 0) {
            EditorCanvas(model: model)
                .frame(minWidth: 420)
            if inspectorPreferred && width >= Self.inspectorMinWindowWidth {
                Divider()
                VStack(spacing: 0) {
                    LayersPanel(model: model)
                    Divider()
                    Inspector(model: model)
                }
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 320)
                .transition(.move(edge: .trailing))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .alert("Editor", isPresented: .constant(model.error != nil), presenting: model.error) { _ in
            Button("OK") { model.error = nil }
        } message: { Text($0) }
    }
}

/// Editor controls for the window toolbar. Items the window can't fit go into its "»" menu.
struct EditorToolbar: ToolbarContent {
    @Bindable var model: EditorModel
    let pageCount: Int
    @Binding var inspectorVisible: Bool
    var onClose: () -> Void
    var onOpenPage: (Int) -> Void
    var onExport: () -> Void

    var body: some ToolbarContent {
        // UndoManager isn't observable; reading these re-evaluates canUndo/canRedo after each edit.
        let _ = (model.doc, model.pixelsVersion)
        ToolbarItem(placement: .navigation) {
            Button { onClose() } label: { Label("Done", systemImage: "checkmark") }
                .keyboardShortcut(.return, modifiers: .command)
                .tip("Save and return to the pages", shortcut: "⌘↩")
        }
        ToolbarItemGroup(placement: .navigation) {
            Button { onOpenPage(model.index - 1) } label: { Label("Previous Page", systemImage: "chevron.left") }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(model.index == 0)
                .tip("Previous page, saving this one", shortcut: "⌘[")
            Button { onOpenPage(model.index + 1) } label: { Label("Next Page", systemImage: "chevron.right") }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(model.index + 1 >= pageCount)
                .tip("Next page, saving this one", shortcut: "⌘]")
        }
        ToolbarItem {
            Picker("Tool", selection: $model.tool) {
                ForEach(EditorModel.Tool.allCases) { tool in
                    Label(tool.rawValue, systemImage: tool.symbol).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .tip("Text (T) · Erase (E) · Heal (H) · Clone (C) · Unpaint (R)")
        }
        if model.tool != .select {
            ToolbarItem {
                HStack(spacing: 6) {
                    Image(systemName: "circle.dotted").foregroundStyle(.secondary)
                    Slider(value: $model.brushSize, in: 4...200).frame(width: 90)
                    Text("\(Int(model.brushSize)) px")
                        .monospacedDigit().foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 52, alignment: .leading)
                }
                .tip("Brush size ([ and ])")
            }
        }
        if model.tool == .erase {
            ToolbarSpacer(.fixed)
            ToolbarItem {
                HStack(spacing: 8) {
                    Toggle(isOn: Binding(get: { model.brushColor == nil }, set: { model.brushColor = $0 ? nil : .white })) {
                        Label("Auto Colour", systemImage: "eyedropper")
                    }
                    .toggleStyle(.button)
                    .tip("Auto: use the colour under the start of each stroke")
                    // Picking a colour turns Auto off.
                    ColorField(color: Binding(get: { model.brushColor ?? .white }, set: { model.brushColor = $0 }), style: .compact)
                        .opacity(model.brushColor == nil ? 0.45 : 1)
                }
            }
        }
        ToolbarSpacer(.fixed)
        ToolbarItemGroup {
            Button { model.undo.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .keyboardShortcut("z").disabled(!model.undo.canUndo).tip("Undo", shortcut: "⌘Z")
            Button { model.undo.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.undo.canRedo).tip("Redo", shortcut: "⇧⌘Z")
        }
        ToolbarItemGroup {
            Button { model.zoomCommand = .zoomOut } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                .keyboardShortcut("-").tip("Zoom out", shortcut: "⌘-")
            Button { model.zoomCommand = .fit } label: { Label("Fit Page", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
                .keyboardShortcut("0").tip("Fit page", shortcut: "⌘0")
            Button { model.zoomCommand = .fitWidth } label: { Label("Fit Width", systemImage: "arrow.left.and.right.square") }
                .tip("Fit width")
            Button { model.zoomCommand = .fitHeight } label: { Label("Fit Height", systemImage: "arrow.up.and.down.square") }
                .tip("Fit height")
            Button { model.zoomCommand = .zoomIn } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                .keyboardShortcut("=").tip("Zoom in", shortcut: "⌘=")
        }
        ToolbarItem {
            Button { onExport() } label: { Label("Export Page", systemImage: "square.and.arrow.up") }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .tip("Export this page", shortcut: "⌥⌘E")
        }
        ToolbarItem {
            Toggle(isOn: $inspectorVisible) { Label("Inspector", systemImage: "sidebar.right") }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .tip("Show or hide the layers and inspector panel", shortcut: "⌥⌘I")
        }
    }
}

/// Text boxes and image layers of the page. Everything here is saved with the page and stays
/// editable later: text stays live text, each image layer is its own file.
private struct LayersPanel: View {
    @Bindable var model: EditorModel
    @State private var renaming: ImageLayer.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Layers").font(.headline)
                Spacer()
                Button { model.addLayer() } label: { Image(systemName: "plus") }
                    .tip("New image layer for erasing or retouching")
                Button { if let id = model.activeLayer { model.deleteLayer(id) } } label: { Image(systemName: "minus") }
                    .disabled(model.activeLayer == nil)
                    .tip("Delete the selected image layer")
                Button { if let id = model.activeLayer { model.moveLayer(id, by: 1) } } label: { Image(systemName: "chevron.up") }
                    .disabled(model.activeLayer == nil || model.doc.layers.last?.id == model.activeLayer)
                    .tip("Move layer up")
                Button { if let id = model.activeLayer { model.moveLayer(id, by: -1) } } label: { Image(systemName: "chevron.down") }
                    .disabled(model.activeLayer == nil || model.doc.layers.first?.id == model.activeLayer)
                    .tip("Move layer down")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            List {
                Section("Text (\(model.doc.blocks.count))") {
                    ForEach(model.doc.blocks) { block in
                        row(visible: !block.hidden, selected: model.selection.contains(block.id),
                            symbol: "textformat", title: block.translation.isEmpty ? "Empty text" : block.translation) { visible in
                            model.change(visible ? "Show Text" : "Hide Text") { doc in
                                if let i = doc.blocks.firstIndex(where: { $0.id == block.id }) { doc.blocks[i].hidden = !visible }
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.tool = .select
                            model.select(block.id, extend: NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift))
                        }
                    }
                }
                Section("Images (\(model.doc.layers.count))") {
                    // Front-most first, as in image editors.
                    ForEach(model.doc.layers.reversed()) { layer in
                        Group {
                            if renaming == layer.id {
                                TextField("Name", text: Binding(get: { layer.name }, set: { model.renameLayer(layer.id, $0) }))
                                    .onSubmit { renaming = nil }
                            } else {
                                row(visible: layer.visible, selected: model.activeLayer == layer.id,
                                    symbol: "photo", title: layer.name) { model.setLayerVisible(layer.id, $0) }
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { renaming = layer.id }
                        .onTapGesture { model.activate(layer.id) }
                    }
                    if model.doc.layers.isEmpty {
                        Text("Brush strokes create a layer automatically.").foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(minHeight: 160, maxHeight: 260)
        }
    }

    private func row(visible: Bool, selected: Bool, symbol: String, title: String, setVisible: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 8) {
            Button { setVisible(!visible) } label: {
                Image(systemName: visible ? "eye" : "eye.slash").foregroundStyle(visible ? .primary : .tertiary)
            }
            .buttonStyle(.borderless)
            .tip(visible ? "Hide" : "Show")
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(title).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(selected ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 5))
    }
}

/// Text and style controls for the selected text boxes (one or several).
struct Inspector: View {
    @Bindable var model: EditorModel
    @State private var importingFont = false
    @State private var choosingFont = false

    var body: some View {
        let blocks = model.selectedBlocks
        if let first = blocks.first {
            Form {
                if blocks.count == 1 {
                    Section("Original") {
                        TextEditor(text: blockBinding(\.sourceText, "Edit Original", first)).frame(minHeight: 44).font(.body)
                        HStack {
                            Button("Read Again") { model.rereadSelected() }.tip("Run OCR again on the original lettering")
                            Button("Translate") { model.retranslateSelected() }.disabled(first.sourceText.isEmpty)
                        }
                    }
                    Section("Translation") {
                        TextEditor(text: blockBinding(\.translation, "Edit Translation", first)).frame(minHeight: 70).font(.body)
                    }
                } else {
                    Section {
                        Text("\(blocks.count) text boxes selected").font(.headline)
                        Text("Style changes apply to all of them.").foregroundStyle(.secondary)
                        Button("Translate Again") { model.retranslateSelected() }
                    }
                }
                Section("Role") {
                    Picker("Role", selection: Binding(
                        get: { current(first).role ?? .dialogue },
                        set: { role in model.updateSelected("Role") { $0.role = role == .dialogue ? nil : role } })) {
                        ForEach(TextRole.allCases) { Text($0.displayName).tag($0) }
                    }
                    .tip("Each role has its own style preset (Translate › Typesetting Presets…)")
                }
                Section("Font") {
                    fontPicker(first)
                    HStack {
                        Toggle(isOn: styleBinding(\.bold, "Bold", first)) { Image(systemName: "bold") }
                            .toggleStyle(.button)
                            .tip("Bold face (if the font has one)")
                        Toggle(isOn: styleBinding(\.italic, "Italic", first)) { Image(systemName: "italic") }
                            .toggleStyle(.button)
                            .tip("Italic face, e.g. for thoughts")
                        Spacer()
                    }
                    sizeControl(blocks)
                    Picker("Alignment", selection: styleBinding(\.alignment, "Alignment", first)) {
                        Image(systemName: "text.alignleft").tag(MangaTLCore.TextAlignment.left)
                        Image(systemName: "text.aligncenter").tag(MangaTLCore.TextAlignment.center)
                        Image(systemName: "text.alignright").tag(MangaTLCore.TextAlignment.right)
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("Line height") {
                        Slider(value: styleBinding(\.lineHeight, "Line Height", first), in: 0.7...1.8)
                    }
                    Toggle("Uppercase", isOn: styleBinding(\.uppercase, "Uppercase", first))
                    LabeledContent("Width") {
                        percentSlider(styleBinding(\.horizontalScale, "Width", first), in: 0.7...1.3)
                    }
                    .tip("Narrow wide lines (about 90%) without changing the size")
                    LabeledContent("Height") {
                        percentSlider(styleBinding(\.verticalScale, "Height", first), in: 0.8...1.6)
                    }
                    .tip("Taller letters for shouting (120–150%)")
                    LabeledContent("Space inside") {
                        percentSlider(styleBinding(\.padding, "Space Inside", first), in: 0...0.3)
                    }
                    .tip("Empty space kept between the text and the balloon edge")
                }
                Section("Colour") {
                    LabeledContent("Text") { ColorField(color: styleBinding(\.color, "Text Colour", first)) }
                    LabeledContent("Outline") { ColorField(color: styleBinding(\.strokeColor, "Outline Colour", first)) }
                    LabeledContent("Outline width") {
                        Slider(value: styleBinding(\.strokeWidth, "Outline Width", first), in: 0...12)
                    }
                }
                Section("Box") {
                    Picker("Shape", selection: blockBinding(\.shape, "Shape", first)) {
                        Text("Balloon").tag(BlockShape.ellipse)
                        Text("Box").tag(BlockShape.rectangle)
                    }
                    LabeledContent("Rotation") {
                        HStack {
                            Slider(value: blockBinding(\.rotation, "Rotate", first), in: -45...45)
                            Text("\(Int(current(first).rotation))°").monospacedDigit().frame(width: 34)
                        }
                    }
                }
                Section {
                    let role = current(first).role ?? .dialogue
                    Button("Use This Style for All \(role.displayName) Text") { model.useAsPreset(current(first)) }
                        .tip("Saves it as the project's \(role.displayName) preset and applies it to every \(role.displayName.lowercased()) box on this page")
                    Button("Reset to \(role.displayName) Preset") { model.updateSelected("Reset Style") { $0.style = nil } }
                        .disabled(blocks.allSatisfy { $0.style == nil })
                    Button(blocks.count > 1 ? "Delete \(blocks.count) Text Boxes" : "Delete Text Box", role: .destructive) { model.deleteSelected() }
                }
            }
            .formStyle(.grouped)
            .safeAreaInset(edge: .bottom, spacing: 0) { TypesetCheckBar(model: model) }
            .fileImporter(isPresented: $importingFont, allowedContentTypes: [.font]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let name = try model.project.store.importFont(url)
                    setStyle("Font") { $0.fontName = name }
                } catch {
                    model.error = "Couldn't load that font: \(error.localizedDescription)"
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("No text selected").font(.headline)
                Text("Click a text box to edit it; ⇧-click or drag across several to select them together. Double-click empty space to add a box.")
                    .foregroundStyle(.secondary)
                Button("Add Text Box") { model.addBlock() }
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .safeAreaInset(edge: .bottom, spacing: 0) { TypesetCheckBar(model: model) }
        }
    }

    private func percentSlider(_ value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        HStack(spacing: 6) {
            Slider(value: value, in: range)
            Text("\(Int((value.wrappedValue * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }

    /// Font size in page pixels: a number field + stepper, or Auto to fit the balloon.
    private func sizeControl(_ blocks: [TextBlock]) -> some View {
        let styles = blocks.map { model.style(of: current($0)) }
        let fixed = styles.compactMap(\.fontSize)
        let isAuto = fixed.isEmpty
        let shown: Double = fixed.first ?? blocks.compactMap { model.fittedFontSize(of: current($0)) }.first ?? 24
        let size = Binding<Double>(
            get: { shown.rounded() },
            set: { v in setStyle("Font Size") { $0.fontSize = min(400, max(4, v.rounded())) } }
        )
        return Group {
            Toggle("Auto-fit to balloon", isOn: Binding(
                get: { isAuto },
                set: { auto in setStyle("Font Size") { $0.fontSize = auto ? nil : shown.rounded() } }))
            LabeledContent("Size") {
                if isAuto {
                    Text("Auto · \(Int(shown.rounded())) px").monospacedDigit().foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 4) {
                        TextField("Size", value: size, format: .number)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 56)
                        Stepper("Size", value: size, in: 4...400, step: 1).labelsHidden()
                        Text("px").foregroundStyle(.secondary)
                    }
                    .fixedSize()
                }
            }
            if !isAuto {
                Slider(value: size, in: 6...160) { Text("Size") }
                    .labelsHidden()
            }
            if fixed.count > 1, Set(fixed).count > 1 {
                Text("Selected boxes have different sizes; changing it sets them all.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func fontPicker(_ block: TextBlock) -> some View {
        HStack {
            Button(CTFontCopyFamilyName(CTFontCreateWithName(model.style(of: current(block)).fontName as CFString, 12, nil)) as String) {
                choosingFont = true
            }
            .popover(isPresented: $choosingFont, arrowEdge: .leading) {
                FontFamilyList { family in
                    setStyle("Font") { $0.fontName = family.map(Self.preferredMember) ?? TextStyle.defaultFontName }
                    choosingFont = false
                }
            }
            Button("Add…") { importingFont = true }.tip("Use a TTF/OTF font file; it is copied into the project's .mangatl folder")
        }
    }

    /// The bold member of a family if it has one (manga lettering is usually bold), else the first.
    static func preferredMember(of family: String) -> String {
        let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
        let names = members.compactMap { ($0.first as? String, $0.count > 1 ? $0[1] as? String : nil) }
        return (names.first { $0.1?.localizedCaseInsensitiveContains("bold") == true } ?? names.first)?.0 ?? family
    }

    /// The live copy of `block`, or `block` itself once it's gone. SwiftUI can still read a control's
    /// binding for a moment after the selection is cleared or the box is deleted.
    private func current(_ block: TextBlock) -> TextBlock {
        model.doc.blocks.first { $0.id == block.id } ?? block
    }

    /// Applies a style change to every selected box (each keeps its other settings).
    private func setStyle(_ name: String, _ body: (inout TextStyle) -> Void) {
        let settings = project.settings
        model.updateSelected(name) { block in
            var style = settings.resolvedStyle(for: block)
            body(&style)
            block.style = style
        }
    }

    private var project: ProjectSession { model.project }

    private func blockBinding<T>(_ key: WritableKeyPath<TextBlock, T>, _ name: String, _ block: TextBlock) -> Binding<T> {
        Binding(get: { current(block)[keyPath: key] }, set: { value in model.updateSelected(name) { $0[keyPath: key] = value } })
    }

    private func styleBinding<T>(_ key: WritableKeyPath<TextStyle, T>, _ name: String, _ block: TextBlock) -> Binding<T> {
        Binding(get: { model.style(of: current(block))[keyPath: key] }, set: { value in setStyle(name) { $0[keyPath: key] = value } })
    }
}

/// Searchable list of installed font families. Built only while the popover is open: a menu with
/// every family cost ~60 MB for as long as the inspector was visible.
struct FontFamilyList: View {
    /// nil = the default (CC Wild Words).
    var onPick: (String?) -> Void
    @State private var query = ""
    @State private var families: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search fonts", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            List {
                Button("CC Wild Words (default)") { onPick(nil) }
                ForEach(families.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }, id: \.self) { family in
                    Button(family) { onPick(family) }
                }
            }
            .buttonStyle(.plain)
        }
        .frame(width: 260, height: 360)
        .onAppear { families = NSFontManager.shared.availableFontFamilies }
    }
}

/// Typesetting warnings for this page, with one-click fixes; clicking one selects its box.
private struct TypesetCheckBar: View {
    @Bindable var model: EditorModel
    @State private var expanded = true

    var body: some View {
        let issues = model.typesetIssues
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button { expanded.toggle() } label: {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        Text("Typeset Check · \(issues.count)").font(.headline)
                        Spacer()
                        Image(systemName: expanded ? "chevron.down" : "chevron.up").foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(issues) { issue in
                                HStack(spacing: 8) {
                                    Button {
                                        model.tool = .select
                                        model.selection = [issue.block]
                                    } label: {
                                        Text("\(model.blockNumber(issue.block)). \(issue.kind.title)")
                                            .lineLimit(2)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                    if let fix = issue.fix {
                                        Button(fix.title) { model.apply(fix, to: issue.block) }
                                            .controlSize(.small)
                                    }
                                }
                                .font(.callout)
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                }
            }
            .padding(12)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }
}
