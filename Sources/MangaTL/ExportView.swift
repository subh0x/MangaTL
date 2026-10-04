import AppKit
import MangaTLCore
import SwiftUI
import UniformTypeIdentifiers

/// Export sheet: which pages, what content (final / clean / text only / original), image format,
/// size and package (folder, CBZ, PDF). The choices are remembered per project.
struct ExportView: View {
    let project: ProjectSession
    let scope: ExportScope
    @Environment(\.dismiss) private var dismiss
    @State private var options: ExportOptions
    @State private var pages: PageChoice
    @State private var rangeText: String
    @State private var customSize: Int
    @State private var problem: String?

    enum PageChoice: String, CaseIterable, Identifiable {
        case all, chosen, range, translated
        var id: String { rawValue }
    }

    init(project: ProjectSession, scope: ExportScope) {
        self.project = project
        self.scope = scope
        let saved = project.source.exportOptions ?? ExportOptions()
        _options = State(initialValue: saved)
        if case .pages(let list) = scope, !list.isEmpty {
            _pages = State(initialValue: .chosen)
            _rangeText = State(initialValue: Self.describe(list))
        } else {
            _pages = State(initialValue: .all)
            _rangeText = State(initialValue: "1-\(project.count)")
        }
        if case .custom(let px) = saved.size { _customSize = State(initialValue: px) } else { _customSize = State(initialValue: 2000) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Pages") {
                    Picker("Pages", selection: $pages) {
                        Text("All \(project.count) pages").tag(PageChoice.all)
                        if case .pages(let list) = scope, !list.isEmpty {
                            Text(list.count == 1 ? "Page \(list[0] + 1)" : "\(list.count) selected pages").tag(PageChoice.chosen)
                        }
                        Text("Range").tag(PageChoice.range)
                        Text("Translated pages only").tag(PageChoice.translated)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    if pages == .range {
                        TextField("Pages", text: $rangeText, prompt: Text("1-12, 15"))
                            .textFieldStyle(.roundedBorder)
                            .tip("Page numbers and ranges, separated by commas")
                    }
                }
                Section("Content") {
                    Picker("Content", selection: $options.content) {
                        ForEach(ExportOptions.Content.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Text(contentHelp).font(.callout).foregroundStyle(.secondary)
                }
                Section("Image") {
                    Picker("Format", selection: $options.format) {
                        ForEach(ExportOptions.Format.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if options.effectiveFormat.hasQuality {
                        LabeledContent("Quality") {
                            HStack {
                                Slider(value: $options.quality, in: 0.5...1)
                                Text("\(Int((options.quality * 100).rounded()))").monospacedDigit().foregroundStyle(.secondary).frame(width: 30)
                            }
                        }
                    }
                    if options.content == .textOnly && options.format == .jpeg {
                        Text("Text-only pages are saved as PNG to keep the transparency.").font(.callout).foregroundStyle(.secondary)
                    }
                    Picker("Size", selection: sizeChoice) {
                        Text("Original resolution").tag(0)
                        Text("Working size (≤ 2400 px)").tag(1)
                        Text("Custom").tag(2)
                    }
                    if case .custom = options.size {
                        LabeledContent("Longest side") {
                            HStack(spacing: 4) {
                                TextField("Pixels", value: $customSize, format: .number)
                                    .labelsHidden()
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 70)
                                    .onChange(of: customSize) { _, px in options.size = .custom(px) }
                                Text("px").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Save As") {
                    Picker("Package", selection: $options.package) {
                        ForEach(ExportOptions.Package.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    if options.package != .pdf {
                        LabeledContent("File names") {
                            TextField("Pattern", text: $options.namePattern)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 150)
                        }
                        .tip("{n} page number, {name} original file name, {project} project name")
                        Text("e.g. \(options.fileName(index: 0, count: project.count, originalName: project.pages.first?.file ?? "page.jpg", project: project.title)).\(options.effectiveFormat.fileExtension)")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Toggle("Show in Finder when done", isOn: $options.revealInFinder)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(2)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") { export() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 480, height: 640)
    }

    private var contentHelp: String {
        switch options.content {
        case .final: "Pages as they look in MangaTL: clean-up and visible layers plus the English text."
        case .clean: "Text removed but no new text, for lettering in another app."
        case .textOnly: "Only the typeset English on a transparent background."
        case .original: "The source pages, unchanged."
        }
    }

    private var sizeChoice: Binding<Int> {
        Binding(
            get: {
                switch options.size {
                case .original: 0
                case .working: 1
                case .custom: 2
                }
            },
            set: { options.size = [0: .original, 1: .working][$0] ?? .custom(customSize) }
        )
    }

    private func resolvedPages() throws -> [Int]? {
        switch pages {
        case .all: return nil
        case .chosen:
            if case .pages(let list) = scope { return list }
            return nil
        case .range: return try ExportOptions.pages(fromRange: rangeText, count: project.count)
        case .translated:
            let list = (0..<project.count).filter(project.isTranslated)
            if list.isEmpty { throw ExportOptions.RangeError.invalid("No translated pages yet") }
            return list
        }
    }

    private func export() {
        let list: [Int]?
        do { list = try resolvedPages() } catch {
            problem = error.localizedDescription
            return
        }
        guard let url = chooseDestination() else { return }
        project.export(pages: list, options: options, to: url)
        dismiss()
    }

    private func chooseDestination() -> URL? {
        let name = "\(project.title) (English)"
        switch options.package {
        case .folder:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Export Here"
            panel.message = "A new folder \"\(name)\" is created inside the folder you choose."
            return panel.runModal() == .OK ? panel.url?.appendingPathComponent(name) : nil
        case .cbz, .pdf:
            let panel = NSSavePanel()
            let ext = options.package.rawValue
            panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
            panel.nameFieldStringValue = "\(name).\(ext)"
            return panel.runModal() == .OK ? panel.url : nil
        }
    }

    /// "3, 5-7" style summary of 0-based pages.
    static func describe(_ pages: [Int]) -> String {
        var parts: [String] = []
        var start: Int?, previous: Int?
        for page in pages.sorted() {
            if let p = previous, page == p + 1 { previous = page; continue }
            if let s = start, let p = previous { parts.append(s == p ? "\(s + 1)" : "\(s + 1)-\(p + 1)") }
            start = page
            previous = page
        }
        if let s = start, let p = previous { parts.append(s == p ? "\(s + 1)" : "\(s + 1)-\(p + 1)") }
        return parts.joined(separator: ", ")
    }
}
