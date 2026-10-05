import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Per-page work of a project, inside the project folder:
///
///     <folder>/.mangatl/pages/<page id>.json               PageDoc
///                       layers/<page id>/<layer id>.png    one PNG per image layer, cropped to its rect
///                       fonts/                             imported TTF/OTF
///
/// Pages are keyed by the stable id in `project.json`, never by position, so reordering or adding
/// pages can't detach their translations. Every write is atomic.
public final class ProjectStore: Sendable {
    public let directory: URL

    /// `directory` is the project's `.mangatl` folder.
    public init(directory: URL) {
        self.directory = directory
        for sub in ["pages", "layers", "fonts"] {
            try? FileManager.default.createDirectory(at: directory.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
    }

    private func pageURL(_ page: String) -> URL { directory.appendingPathComponent("pages/\(page).json") }
    private func layerDir(_ page: String) -> URL { directory.appendingPathComponent("layers/\(page)") }
    private func layerURL(_ page: String, _ id: UUID) -> URL { layerDir(page).appendingPathComponent("\(id.uuidString).png") }
    private var fontsURL: URL { directory.appendingPathComponent("fonts") }

    // MARK: Fonts

    /// Copies a TTF/OTF into the project and registers it for this process; returns its PostScript name.
    public func importFont(_ url: URL) throws -> String {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first,
              let name = CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let dest = fontsURL.appendingPathComponent(url.lastPathComponent)
        if !FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.copyItem(at: url, to: dest)
            CTFontManagerRegisterFontsForURL(dest as CFURL, .process, nil)
        }
        return name
    }

    /// Registers every font the project has imported (call once when the project opens).
    public func registerFonts() {
        let files = (try? FileManager.default.contentsOfDirectory(at: fontsURL, includingPropertiesForKeys: nil)) ?? []
        for file in files { CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil) }
    }

    // MARK: Pages

    public func hasPage(_ page: String) -> Bool { FileManager.default.fileExists(atPath: pageURL(page).path) }

    /// When the page's work was last saved (nil if it has none). Layers are saved with the page doc.
    public func pageModified(_ page: String) -> Date? {
        try? pageURL(page).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    public func loadPage(_ page: String) -> PageDoc? {
        guard let data = try? Data(contentsOf: pageURL(page)) else { return nil }
        return try? JSONDecoder().decode(PageDoc.self, from: data)
    }

    public func save(_ doc: PageDoc, page: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(doc).write(to: pageURL(page), options: .atomic)
    }

    public func deletePage(_ page: String) {
        try? FileManager.default.removeItem(at: pageURL(page))
        try? FileManager.default.removeItem(at: layerDir(page))
    }

    // MARK: Layers

    public func loadLayer(_ page: String, _ id: UUID) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(layerURL(page, id) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    public func saveLayer(_ image: CGImage, page: String, id: UUID) throws {
        let url = layerURL(page, id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.writePNG(image, to: url)
    }

    /// Deletes layer files of `page` that `doc` no longer references.
    public func pruneLayers(page: String, keeping doc: PageDoc) {
        let keep = Set(doc.layers.map(\.id))
        for file in (try? FileManager.default.contentsOfDirectory(at: layerDir(page), includingPropertiesForKeys: nil)) ?? [] {
            if let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !keep.contains(id) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// The page's visible layers, bottom to top, ready for `PageRenderer`.
    public func visibleLayers(of doc: PageDoc, page: String) -> [PageRenderer.Layer] {
        doc.layers.filter(\.visible).compactMap { layer in
            loadLayer(page, layer.id).map { PageRenderer.Layer(rect: layer.rect, image: $0) }
        }
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        let tmp = url.appendingPathExtension("tmp")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }

    // MARK: Migration from the pre-project store

    /// Where builds before projects kept a book's work (Application Support, keyed by source id).
    public static func legacyDirectory(forSourceID id: String) -> URL {
        let key = SHA256.hash(data: Data(id.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MangaTL/projects/\(key)", isDirectory: true)
    }

    /// Copies old index-keyed pages/layers/fonts into this store, mapping index `i` to `pageIDs[i]`.
    /// Returns the old settings, if any. The legacy folder is left untouched.
    @discardableResult
    public func importLegacy(from legacy: URL, pageIDs: [String]) -> ProjectSettings? {
        let fm = FileManager.default
        for (index, page) in pageIDs.enumerated() {
            let oldPage = legacy.appendingPathComponent("pages/\(index).json")
            guard fm.fileExists(atPath: oldPage.path), !hasPage(page) else { continue }
            try? fm.copyItem(at: oldPage, to: pageURL(page))
            try? fm.createDirectory(at: layerDir(page), withIntermediateDirectories: true)
            // Single full-page patch from before layers existed.
            let flat = legacy.appendingPathComponent("patches/\(index).png")
            if fm.fileExists(atPath: flat.path) { try? fm.copyItem(at: flat, to: layerURL(page, ImageLayer.legacyID)) }
            let dir = legacy.appendingPathComponent("patches/\(index)")
            for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.copyItem(at: file, to: layerDir(page).appendingPathComponent(file.lastPathComponent))
            }
        }
        for font in (try? fm.contentsOfDirectory(at: legacy.appendingPathComponent("fonts"), includingPropertiesForKeys: nil)) ?? [] {
            try? fm.copyItem(at: font, to: fontsURL.appendingPathComponent(font.lastPathComponent))
        }
        guard let data = try? Data(contentsOf: legacy.appendingPathComponent("project.json")) else { return nil }
        return try? JSONDecoder().decode(ProjectSettings.self, from: data)
    }
}
