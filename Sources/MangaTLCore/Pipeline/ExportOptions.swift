import Foundation

/// How to export pages. Saved per project (last used) in `project.json`.
public struct ExportOptions: Codable, Equatable, Sendable {
    public enum Content: String, Codable, CaseIterable, Sendable {
        /// Page + visible layers + typeset text.
        case final
        /// Page + visible layers, no text (for typesetting elsewhere).
        case clean
        /// Only the typeset text on a transparent background.
        case textOnly
        /// The page as it came in.
        case original

        public var title: String {
            switch self {
            case .final: "Final (translated)"
            case .clean: "Clean (no text)"
            case .textOnly: "Text layer only"
            case .original: "Original"
            }
        }
    }

    public enum Format: String, Codable, CaseIterable, Sendable {
        case jpeg, png, heic
        public var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
        public var title: String { self == .jpeg ? "JPEG" : rawValue.uppercased() }
        public var hasQuality: Bool { self != .png }
    }

    public enum Size: Codable, Equatable, Hashable, Sendable {
        /// Full resolution (capped at 8192 px).
        case original
        /// The pipeline's working size (≤ 2400 px).
        case working
        /// Longest side in pixels.
        case custom(Int)

        public var maxPixels: Int {
            switch self {
            case .original: 8192
            case .working: 2400
            case .custom(let px): min(8192, max(64, px))
            }
        }
    }

    public enum Package: String, Codable, CaseIterable, Sendable {
        case folder, cbz, pdf
        public var title: String {
            switch self {
            case .folder: "Folder of images"
            case .cbz: "CBZ archive"
            case .pdf: "PDF"
            }
        }
    }

    public var content: Content = .final
    public var format: Format = .jpeg
    /// 0…1, for JPEG and HEIC.
    public var quality: Double = 0.92
    public var size: Size = .original
    public var package: Package = .folder
    /// File names in a folder/CBZ: `{n}` page number (zero-padded), `{name}` original file name,
    /// `{project}` project name.
    public var namePattern = "{n}"
    public var revealInFinder = true

    public init() {}

    /// Text-only output needs transparency, which JPEG can't hold.
    public var effectiveFormat: Format { content == .textOnly && format == .jpeg ? .png : format }

    /// Settings used to turn a CBZ/PDF into a project folder.
    public static var importArchive: ExportOptions {
        var options = ExportOptions()
        options.content = .original
        options.revealInFinder = false
        return options
    }

    /// File name (without extension) for page `index` (0-based) of `count`.
    public func fileName(index: Int, count: Int, originalName: String, project: String) -> String {
        let number = String(index + 1)
        let padded = String(repeating: "0", count: max(0, String(count).count - number.count)) + number
        let name = namePattern
            .replacingOccurrences(of: "{n}", with: padded)
            .replacingOccurrences(of: "{name}", with: (originalName as NSString).deletingPathExtension)
            .replacingOccurrences(of: "{project}", with: project)
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? padded : name
    }

    public enum RangeError: Error, LocalizedError {
        case invalid(String)
        public var errorDescription: String? {
            if case .invalid(let part) = self { return "\"\(part)\" isn't a page or range (e.g. 1-12, 15)." }
            return nil
        }
    }

    /// Parses "1-12, 15" into 0-based page indices (sorted, unique) for a book of `count` pages.
    public static func pages(fromRange text: String, count: Int) throws -> [Int] {
        var result = Set<Int>()
        for part in text.split(whereSeparator: { $0 == "," || $0 == ";" }).map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
            let bounds = part.split(whereSeparator: { "-–—".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
            guard (1...2).contains(bounds.count), let first = Int(bounds[0]), let last = Int(bounds.last!),
                  first >= 1, last <= count, first <= last else { throw RangeError.invalid(part) }
            result.formUnion((first - 1)...(last - 1))
        }
        guard !result.isEmpty else { throw RangeError.invalid(text) }
        return result.sorted()
    }
}
