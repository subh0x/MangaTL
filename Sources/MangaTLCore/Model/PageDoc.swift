import CoreGraphics
import Foundation

/// Source languages the pipeline can read. Raw values are BCP-47 codes used by Vision / Translation.
public enum SourceLanguage: String, Codable, CaseIterable, Sendable, Identifiable {
    case japanese = "ja"
    case chineseSimplified = "zh-Hans"
    case chineseTraditional = "zh-Hant"
    case korean = "ko"
    case spanish = "es"
    case french = "fr"
    case portuguese = "pt"

    public var id: String { rawValue }

    public var displayName: String {
        Locale.current.localizedString(forIdentifier: rawValue) ?? rawValue
    }

    /// Baberu (manga-trained) reads Japanese and Chinese; Vision handles Korean and Latin scripts.
    public var usesMangaOCR: Bool { self == .japanese || self == .chineseSimplified || self == .chineseTraditional }

    /// Manga in these languages is read right-to-left.
    public var defaultRightToLeft: Bool { self == .japanese || self == .chineseTraditional }
}

/// Per-book settings, stored as `project.json` next to the page docs.
public struct ProjectSettings: Codable, Equatable, Sendable {
    public var language: SourceLanguage
    /// "Auto": each page's language is identified when it is translated, and `language` follows
    /// the last one found (so the editor and the next pages use it).
    public var autoLanguage: Bool?
    public var rightToLeft: Bool
    /// The project's base lettering style (dialogue).
    public var style: TextStyle
    /// Per-role overrides of `TextRole.preset`; nil/missing roles use the preset.
    public var roleStyles: [TextRole: TextStyle]?

    public init(language: SourceLanguage = .japanese) {
        self.language = language
        rightToLeft = language.defaultRightToLeft
        style = TextStyle()
    }

    /// The style a role uses unless a block overrides it.
    public func style(for role: TextRole) -> TextStyle {
        roleStyles?[role] ?? role.preset(from: style)
    }

    /// Block style → role preset → project style.
    public func resolvedStyle(for block: TextBlock) -> TextStyle {
        block.style ?? style(for: block.role ?? .dialogue)
    }
}

/// What kind of lettering a block is; each role has its own style preset.
public enum TextRole: String, Codable, CaseIterable, Identifiable, Sendable, CodingKeyRepresentable {
    case dialogue, thought, shout, whisper, narration, sfx

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .dialogue: "Dialogue"
        case .thought: "Thought"
        case .shout: "Shout"
        case .whisper: "Whisper"
        case .narration: "Narration"
        case .sfx: "Sound Effect"
        }
    }

    /// Defaults from common scanlation typesetting practice: italic thoughts, bold-italic shouts
    /// set taller, smaller whispers, and an outline only on lettering that sits over artwork.
    public func preset(from base: TextStyle) -> TextStyle {
        var style = base
        switch self {
        case .dialogue:
            break
        case .thought:
            style.italic = true
        case .shout:
            style.bold = true
            style.italic = true
            style.verticalScale = 1.3
        case .whisper:
            style.sizeFactor = 0.85
        case .narration:
            style.padding = 0.06
            style.strokeWidth = max(style.strokeWidth, 3)
        case .sfx:
            style.bold = true
            style.italic = true
            style.strokeWidth = max(style.strokeWidth, 3)
        }
        return style
    }
}

public struct RGBA: Codable, Equatable, Hashable, Sendable {
    public var r, g, b, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { (self.r, self.g, self.b, self.a) = (r, g, b, a) }
    public static let black = RGBA(0, 0, 0)
    public static let white = RGBA(1, 1, 1)
    public var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

extension RGBA {
    /// Accepts "#RGB", "RGB", "#RRGGBB" or "RRGGBB" (any case).
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    public var hex: String {
        let c = { (v: Double) in Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }
}

public enum TextAlignment: String, Codable, CaseIterable, Hashable, Sendable { case left, center, right }

public struct TextStyle: Codable, Equatable, Hashable, Sendable {
    /// CC Wild Words (Comicraft), the usual manga lettering face; Core Text falls back to the
    /// system font if it isn't installed.
    public static let defaultFontName = "CCWildWordsRoman"
    /// The default before CC Wild Words; projects still on it are moved to the new default.
    public static let previousDefaultFontName = "Helvetica-Bold"

    /// PostScript name of an installed or project-registered font.
    public var fontName: String = TextStyle.defaultFontName
    /// Use the family's bold / italic face (when it has one).
    public var bold = false
    public var italic = false
    /// Fixed size in page pixels; nil = fit the shape automatically.
    public var fontSize: Double?
    /// Multiplies the auto-fitted size (e.g. 0.85 for whispers).
    public var sizeFactor: Double = 1
    public var color: RGBA = .black
    public var strokeColor: RGBA = .white
    /// Outline width in page pixels, drawn outside the glyphs (0 = none).
    public var strokeWidth: Double = 0
    public var alignment: TextAlignment = .center
    public var lineHeight: Double = 1.05
    public var uppercase = false
    /// Glyph scale: 0.9 narrows a wide line, 1.3 makes a shout taller.
    public var horizontalScale: Double = 1
    public var verticalScale: Double = 1
    /// Empty space kept inside the balloon, as a fraction of its size on each side.
    public var padding: Double = 0.12

    public init() {}

    public init(from decoder: Decoder) throws {
        // Every field is optional on disk so older project files keep loading.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TextStyle()
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? d.fontName
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? d.bold
        italic = try c.decodeIfPresent(Bool.self, forKey: .italic) ?? d.italic
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize)
        sizeFactor = try c.decodeIfPresent(Double.self, forKey: .sizeFactor) ?? d.sizeFactor
        color = try c.decodeIfPresent(RGBA.self, forKey: .color) ?? d.color
        strokeColor = try c.decodeIfPresent(RGBA.self, forKey: .strokeColor) ?? d.strokeColor
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? d.strokeWidth
        alignment = try c.decodeIfPresent(TextAlignment.self, forKey: .alignment) ?? d.alignment
        lineHeight = try c.decodeIfPresent(Double.self, forKey: .lineHeight) ?? d.lineHeight
        uppercase = try c.decodeIfPresent(Bool.self, forKey: .uppercase) ?? d.uppercase
        horizontalScale = try c.decodeIfPresent(Double.self, forKey: .horizontalScale) ?? d.horizontalScale
        verticalScale = try c.decodeIfPresent(Double.self, forKey: .verticalScale) ?? d.verticalScale
        padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? d.padding
    }
}

public enum BlockShape: String, Codable, Sendable { case ellipse, rectangle }

/// One piece of lettering on a page. All rects are normalised to the page (0…1, origin top-left)
/// so they survive any decode size.
public struct TextBlock: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    /// Where the original lettering is (what gets erased).
    public var textRect: CGRect
    /// Where the translation is laid out: the bubble if one contains the text, else the text rect.
    public var layoutRect: CGRect
    public var shape: BlockShape
    public var sourceText: String
    public var translation: String
    /// Overrides the project's style for this block's role when set.
    public var style: TextStyle?
    /// Dialogue when nil.
    public var role: TextRole?
    /// Degrees, clockwise.
    public var rotation: Double = 0
    public var hidden = false

    public init(textRect: CGRect, layoutRect: CGRect, shape: BlockShape, sourceText: String, translation: String = "") {
        self.textRect = textRect
        self.layoutRect = layoutRect
        self.shape = shape
        self.sourceText = sourceText
        self.translation = translation
    }
}

/// A raster layer over the page (erased lettering, retouching). Pixels are stored cropped to
/// `rect` as `patches/<page>/<id>.png`; layers draw bottom-to-top in `PageDoc.layers` order.
public struct ImageLayer: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Made by translation; replaced when the page is translated again. Other layers are the user's.
        case cleanup
    }

    public var id = UUID()
    public var name: String
    public var visible = true
    /// Where the stored pixels go, in working-size pixels (top-left origin).
    public var rect: CGRect
    public var kind: Kind?

    public init(id: UUID = UUID(), name: String, rect: CGRect, kind: Kind? = nil) {
        self.id = id
        self.name = name
        self.rect = rect
        self.kind = kind
    }

    /// Id given to the single full-page patch written by versions before layers existed.
    public static let legacyID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}

/// Everything known about one translated page; stored as `pages/<index>.json`.
public struct PageDoc: Codable, Equatable, Sendable {
    public var blocks: [TextBlock]
    /// Pixel size the layers were produced at.
    public var workingSize: CGSize
    /// Bottom to top.
    public var layers: [ImageLayer]
    /// The language "Auto" identified for this page when it was translated (nil when chosen by hand).
    public var detectedLanguage: SourceLanguage?

    public init(blocks: [TextBlock] = [], workingSize: CGSize, layers: [ImageLayer] = []) {
        self.blocks = blocks
        self.workingSize = workingSize
        self.layers = layers
    }

    private enum CodingKeys: String, CodingKey { case blocks, workingSize, layers, hasPatch, detectedLanguage }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blocks = try c.decode([TextBlock].self, forKey: .blocks)
        workingSize = try c.decode(CGSize.self, forKey: .workingSize)
        if let layers = try c.decodeIfPresent([ImageLayer].self, forKey: .layers) {
            self.layers = layers
        } else if try c.decodeIfPresent(Bool.self, forKey: .hasPatch) == true {
            // Pre-layer docs: one full-page patch file.
            layers = [ImageLayer(id: ImageLayer.legacyID, name: "Text Clean-up", rect: CGRect(origin: .zero, size: workingSize), kind: .cleanup)]
        } else {
            layers = []
        }
        detectedLanguage = try c.decodeIfPresent(SourceLanguage.self, forKey: .detectedLanguage)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(blocks, forKey: .blocks)
        try c.encode(workingSize, forKey: .workingSize)
        try c.encode(layers, forKey: .layers)
        try c.encodeIfPresent(detectedLanguage, forKey: .detectedLanguage)
    }
}

extension CGRect {
    /// Converts a normalised rect into pixel space of an image of `size`.
    public func denormalized(to size: CGSize) -> CGRect {
        CGRect(x: minX * size.width, y: minY * size.height, width: width * size.width, height: height * size.height)
    }

    public func normalized(in size: CGSize) -> CGRect {
        CGRect(x: minX / size.width, y: minY / size.height, width: width / size.width, height: height / size.height)
    }
}
