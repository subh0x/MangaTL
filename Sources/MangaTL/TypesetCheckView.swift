import MangaTLCore
import SwiftUI

/// Typeset Check for the whole project: every page's warnings, grouped by page.
/// Choosing one opens that page in the editor with the box selected.
struct TypesetCheckView: View {
    let project: ProjectSession
    var onOpen: (_ page: Int, _ block: UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var results: [(page: Int, doc: PageDoc, issues: [TypesetCheck.Issue])]?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Typeset Check").font(.headline)
                Spacer()
                if let results {
                    Text("\(results.reduce(0) { $0 + $1.issues.count }) warnings on \(results.count) pages")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            Divider()
            Group {
                if let results, results.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No problems found").foregroundStyle(.secondary)
                        Text("Every translated page passes the typesetting checks.").font(.callout).foregroundStyle(.tertiary)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else if let results {
                    List {
                        ForEach(results, id: \.page) { entry in
                            Section("Page \(entry.page + 1)") {
                                ForEach(entry.issues) { issue in
                                    Button {
                                        dismiss()
                                        onOpen(entry.page, issue.block)
                                    } label: {
                                        HStack {
                                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                                            Text(issue.kind.title)
                                            Spacer()
                                            Text(snippet(entry.doc, issue.block)).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                } else {
                    ProgressView("Checking pages…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 480)
        .task { await scan() }
    }

    private func snippet(_ doc: PageDoc, _ block: UUID) -> String {
        doc.blocks.first { $0.id == block }?.translation ?? ""
    }

    private func scan() async {
        let (store, settings, keys) = (project.store, project.settings, project.pages.map(\.id))
        let found = await Task.detached(priority: .userInitiated) {
            keys.enumerated().compactMap { index, key -> (Int, PageDoc, [TypesetCheck.Issue])? in
                guard let doc = store.loadPage(key) else { return nil }
                let issues = TypesetCheck.check(doc, settings: settings)
                return issues.isEmpty ? nil : (index, doc, issues)
            }
        }.value
        results = found.map { (page: $0.0, doc: $0.1, issues: $0.2) }
    }
}
