import AppKit
import MangaTLCore
import SwiftUI
import UniformTypeIdentifiers

struct LanguageMenu: View {
    @Bindable var project: ProjectSession

    var body: some View {
        Menu {
            Picker("Source language", selection: Binding(
                get: { project.settings.language },
                set: { language in
                    project.settings.language = language
                    project.settings.rightToLeft = language.defaultRightToLeft
                }
            )) {
                ForEach(SourceLanguage.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.inline)
            Toggle("Read right to left", isOn: $project.settings.rightToLeft)
        } label: {
            Label(project.settings.language.displayName, systemImage: "globe")
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
        }
        .tip("Language the manga is written in")
    }
}

/// Project-level sheets opened from the Translate menu.
enum ProjectSheet: String, Identifiable {
    case presets, typesetCheck
    var id: String { rawValue }
}

struct TranslateMenu: View {
    let project: ProjectSession
    let position: ReadingPosition
    /// Set while editing: translating saves the page first, and selected boxes can be re-done.
    var editor: EditorModel?
    var onShow: (ProjectSheet) -> Void = { _ in }

    var body: some View {
        Menu {
            Button("Translate This Page") { translateCurrentPage() }
                .keyboardShortcut("t")
            Button("Translate All Untranslated Pages") { project.translate(pages: Array(0..<project.count)) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            if let editor {
                Divider()
                Button("Translate Selected Text Again") { editor.retranslateSelected() }
                    .disabled(editor.selectedBlocks.isEmpty)
                Button("Read Selected Text Again") { editor.rereadSelected() }
                    .disabled(editor.selectedBlock == nil)
            }
            Divider()
            Button("Typesetting Presets…") { onShow(.presets) }
            Button("Typeset Check…") { onShow(.typesetCheck) }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Divider()
            Button("Revert This Page to Original") { project.revert(page: editor?.index ?? position.page) }
                .disabled(editor != nil)
            Divider()
            Button("Export as CBZ…") { exportCBZ() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Export as Images…") { exportFolder() }
            if project.isTranslating {
                Divider()
                Button("Stop") { project.cancel() }
                    .keyboardShortcut(".")
            }
        } label: {
            Label("Translate", systemImage: "translate")
        }
        .tip("Detect, read, translate and letter pages on this Mac (⌘T: this page)")
    }

    private func translateCurrentPage() {
        if let editor {
            if editor.dirty { editor.save() }
            project.translate(pages: [editor.index], redo: true)
        } else {
            project.translate(pages: [position.page], redo: true)
        }
    }

    private func exportCBZ() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cbz") ?? .zip]
        panel.nameFieldStringValue = "\(project.source.title) (English).cbz"
        if panel.runModal() == .OK, let url = panel.url { project.export(to: url, format: .cbz) }
    }

    private func exportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Pages are written as 001.jpg, 002.jpg… in a new folder inside the one you choose."
        if panel.runModal() == .OK, let url = panel.url {
            project.export(to: url.appendingPathComponent("\(project.source.title) (English)"), format: .folder)
        }
    }
}

/// Bottom bar, shown in every mode: activity on the left, page and memory on the right.
struct StatusBar<Trailing: View>: View {
    let project: ProjectSession?
    let position: ReadingPosition?
    /// Editor work in progress (e.g. "Healing…").
    var activity: String?
    /// Mode-specific controls next to the page counter (zoom).
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            if let project {
                TranslationStatus(project: project)
            }
            if let activity {
                ProgressView().controlSize(.mini)
                Text(activity).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
            Spacer(minLength: 0)
            trailing()
            if let project, let position {
                PageIndicator(position: position, count: project.count)
                Divider().frame(height: 12)
            }
            FootprintLabel()
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .frame(height: 26)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

struct TranslationStatus: View {
    let project: ProjectSession

    var body: some View {
        if let p = project.progress {
            HStack(spacing: 6) {
                ProgressView(value: Double(p.done), total: Double(max(1, p.total)))
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .frame(width: 80)
                Text("Page \(p.page + 1) · \(p.stage)\(p.total > 1 ? " · \(p.done + 1)/\(p.total)" : "")")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}

/// The top visible page. Kept in its own observable object and read only by `PageIndicator`,
/// so scrolling re-renders that label instead of the whole window.
@Observable final class ReadingPosition {
    var page = 0
    /// Set to scroll the grid/reader to a page (consumed by the collection view).
    var jump: Int?
}

struct PageIndicator: View {
    let position: ReadingPosition
    let count: Int

    var body: some View {
        Text("Page \(min(position.page, max(0, count - 1)) + 1) of \(count)")
            .lineLimit(1)
            .fixedSize()
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
}

struct FootprintLabel: View {
    @State private var megabytes = MemoryFootprint.megabytes()

    var body: some View {
        Label(String(format: "%.0f MB", megabytes), systemImage: "memorychip")
            .lineLimit(1)
            .fixedSize()
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .tip("Memory footprint of this app")
            .task {
                while !Task.isCancelled {
                    megabytes = MemoryFootprint.megabytes()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
    }
}
