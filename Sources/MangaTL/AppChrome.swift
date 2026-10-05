import AppKit
import MangaTLCore
import SwiftUI
import UniformTypeIdentifiers

struct LanguageMenu: View {
    @Bindable var project: ProjectSession

    var body: some View {
        Menu {
            // nil = Auto: identified from each page's text when it is translated.
            Picker("Source language", selection: Binding<SourceLanguage?>(
                get: { project.settings.autoLanguage == true ? nil : project.settings.language },
                set: { language in
                    project.settings.autoLanguage = language == nil ? true : nil
                    if let language {
                        project.settings.language = language
                        project.settings.rightToLeft = language.defaultRightToLeft
                    }
                }
            )) {
                Text("Auto").tag(SourceLanguage?.none)
                Divider()
                ForEach(SourceLanguage.allCases) { Text($0.displayName).tag(SourceLanguage?.some($0)) }
            }
            .pickerStyle(.inline)
            Toggle("Read right to left", isOn: $project.settings.rightToLeft)
        } label: {
            Label(project.settings.autoLanguage == true ? "Auto · \(project.settings.language.displayName)" : project.settings.language.displayName,
                  systemImage: "globe")
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
        }
        .tip(project.settings.autoLanguage == true
             ? "Auto: each page's language is identified when it is translated (last found: \(project.settings.language.displayName))"
             : "Language the manga is written in")
    }
}

/// Which pages an Export sheet starts with.
enum ExportScope: Equatable {
    case all
    case pages([Int])
}

/// Project-level sheets opened from menus.
enum ProjectSheet: Identifiable, Equatable {
    case presets
    case export(ExportScope)

    var id: String {
        switch self {
        case .presets: "presets"
        case .export: "export"
        }
    }
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
            Divider()
            Button("Revert This Page to Original") { project.revert(page: editor?.index ?? position.page) }
                .disabled(editor != nil)
            Divider()
            Button("Export…") { onShow(.export(.all)) }
            Button(editor != nil ? "Export This Page…" : "Export Current Page…") {
                if let editor, editor.dirty { editor.save() }
                onShow(.export(.pages([editor?.index ?? position.page])))
            }
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
}

/// Bottom bar, shown in every mode: activity on the left, page and memory on the right.
struct StatusBar<Trailing: View, Leading: View>: View {
    let project: ProjectSession?
    let position: ReadingPosition?
    /// Editor work in progress (e.g. "Healing…").
    var activity: String?
    /// Mode-specific controls next to the page counter (zoom).
    @ViewBuilder var trailing: () -> Trailing
    /// Shown first (the problems count).
    @ViewBuilder var leading: () -> Leading

    var body: some View {
        HStack(spacing: 12) {
            leading()
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
