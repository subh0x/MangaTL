import AppKit
import ImageIO
import SwiftUI

/// Start screen: open or import a project on the left, recent projects on the right.
struct WelcomeView: View {
    let recents: RecentProjects
    var onOpen: (URL) -> Void
    var onOpenFolder: () -> Void
    var onImport: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "character.book.closed.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.tint)
                    Text("MangaTL").font(.largeTitle.weight(.semibold))
                    Text("Translate manga on this Mac.").foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Button(action: onOpenFolder) { Label("Open Folder…", systemImage: "folder") }
                        .keyboardShortcut("o")
                    Button(action: onImport) { Label("Import CBZ / PDF…", systemImage: "square.and.arrow.down") }
                        .keyboardShortcut("i", modifiers: [.command, .shift])
                }
                .buttonStyle(.borderless)
                .font(.title3)
                Spacer()
                Text("A project is a folder of page images. Its translations, layers and page order are saved in a hidden .mangatl folder inside it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(28)
            .frame(width: 300, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Recent Projects").font(.headline)
                    Spacer()
                    if !recents.entries.isEmpty {
                        Button("Clear") { recents.clear() }.buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                if recents.entries.isEmpty {
                    // Top-aligned, like Xcode's and Finder's empty lists.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No Recent Projects").foregroundStyle(.secondary)
                        Text("Open a folder of images, or drop one here.").font(.callout).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 20)
                } else {
                    List(recents.entries) { entry in
                        RecentRow(entry: entry)
                            .contentShape(Rectangle())
                            .onTapGesture { if entry.exists { onOpen(entry.url) } }
                            .contextMenu {
                                Button("Open") { onOpen(entry.url) }.disabled(!entry.exists)
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                                    .disabled(!entry.exists)
                                Divider()
                                Button("Remove from Recents") { recents.remove(entry) }
                            }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct RecentRow: View {
    let entry: RecentProjects.Entry
    @State private var cover: CGImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let cover {
                    Image(decorative: cover, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 40, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(.body.weight(.medium)).lineLimit(1)
                Text(entry.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(entry.exists ? "\(entry.translated) of \(entry.pages) pages translated" : "Folder not found")
                    .font(.caption)
                    .foregroundStyle(entry.exists ? .secondary : Color.red)
            }
            Spacer(minLength: 8)
            Text(entry.opened, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.vertical, 4)
        .opacity(entry.exists ? 1 : 0.55)
        .task(id: entry.path) { cover = await Self.loadCover(entry) }
    }

    /// A small cover from the first page, decoded at thumbnail size.
    static func loadCover(_ entry: RecentProjects.Entry) async -> CGImage? {
        guard let name = entry.cover else { return nil }
        let url = entry.url.appendingPathComponent(name)
        return await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: 112]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
    }
}
