import MangaTLCore
import SwiftUI

/// Bottom panel listing what failed or needs attention (like VS Code's Problems), each with Retry.
struct ProblemsPanel: View {
    let project: ProjectSession
    var onGoToPage: (Int) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if project.problems.isEmpty {
                Text("No problems. Failed translations, exports and edits show up here with a Retry button.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(project.problems.reversed()) { problem in
                            row(problem)
                            Divider().padding(.leading, 36)
                        }
                    }
                }
            }
        }
        .frame(height: 170)
        .background(.background)
        .overlay(alignment: .top) { Divider() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Problems").font(.headline)
            if !project.problems.isEmpty {
                Text("\(project.problems.count)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            Spacer()
            Button("Retry All") {
                for problem in project.problems where problem.retry != nil { project.retry(problem) }
            }
            .disabled(!project.problems.contains { $0.retry != nil })
            .tip("Run every failed operation again")
            Button("Clear") { project.clearProblems() }
                .disabled(project.problems.isEmpty)
                .tip("Remove all problems from the list")
            Button { onClose() } label: { Label("Hide", systemImage: "chevron.down") }
                .labelStyle(.iconOnly)
                .tip("Hide the Problems panel", shortcut: "⇧⌘M")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .frame(height: 30)
    }

    private func row(_ problem: Problem) -> some View {
        let page = problem.pageID.flatMap(project.index(of:))
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: problem.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(problem.severity == .error ? .red : .yellow)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(page.map { "Page \($0 + 1) · \(problem.operation)" } ?? problem.operation).fontWeight(.medium)
                    Text(problem.date, style: .relative).foregroundStyle(.tertiary).font(.caption)
                }
                Text(problem.message)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                if problem.retry != nil {
                    Button("Retry") { project.retry(problem) }
                        .tip("Run this operation again")
                }
                if let page {
                    Button { onGoToPage(page) } label: { Label("Go to Page", systemImage: "arrow.right.circle") }
                        .labelStyle(.iconOnly)
                        .tip("Show page \(page + 1)")
                }
                Button { project.dismiss(problem) } label: { Label("Dismiss", systemImage: "xmark") }
                    .labelStyle(.iconOnly)
                    .tip("Remove from the list")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}

/// Status-bar button showing the problem count; toggles the panel.
struct ProblemsButton: View {
    let project: ProjectSession
    @Binding var visible: Bool

    var body: some View {
        let errors = project.problems.filter { $0.severity == .error }.count
        let warnings = project.problems.count - errors
        Button { visible.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "xmark.octagon").foregroundStyle(errors > 0 ? .red : .secondary)
                Text("\(errors)").monospacedDigit()
                Image(systemName: "exclamationmark.triangle").foregroundStyle(warnings > 0 ? .yellow : .secondary)
                Text("\(warnings)").monospacedDigit()
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("m", modifiers: [.command, .shift])
        .tip(visible ? "Hide problems" : "Show problems", shortcut: "⇧⌘M")
    }
}
