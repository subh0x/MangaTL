import CoreGraphics
import CoreText
import Foundation

/// Lays a translation into its balloon with Core Text: picks the largest font size at which the
/// whole text fits the balloon's usable area without breaking any word, then centres it.
public enum Typesetter {
    public static let minFontSize: CGFloat = 6

    /// Usable text area inside a layout rect: the rectangle inscribed in an ellipse is ~71 % of it;
    /// balloons are rarely perfect ellipses, so a slightly larger box reads better.
    public static func textBox(for rect: CGRect, shape: BlockShape) -> CGRect {
        switch shape {
        case .ellipse: rect.insetBy(dx: rect.width * 0.12, dy: rect.height * 0.14)
        case .rectangle: rect.insetBy(dx: rect.width * 0.05, dy: rect.height * 0.05)
        }
    }

    public struct Layout {
        public var frame: CTFrame
        public var box: CGRect
        public var fontSize: CGFloat
        /// Height actually used by the lines (for vertical centring).
        public var usedHeight: CGFloat
        /// The laid-out string (after uppercasing), as UTF-16 for line-range checks.
        var text: NSString
    }

    private final class CachedLayout { let layout: Layout?; init(_ l: Layout?) { layout = l } }
    /// The font-size search runs ~12 Core Text layouts; editors redraw every frame while dragging.
    nonisolated(unsafe) private static let cache: NSCache<NSString, CachedLayout> = {
        let cache = NSCache<NSString, CachedLayout>()
        cache.countLimit = 512
        return cache
    }()

    /// `box` is in a bottom-left-origin space (Core Text's).
    public static func layout(_ text: String, in box: CGRect, style: TextStyle, scale: CGFloat) -> Layout? {
        let key = "\(text)|\(box)|\(scale)|\(style)" as NSString
        if let hit = cache.object(forKey: key) { return hit.layout }
        let result = computeLayout(text, in: box, style: style, scale: scale)
        cache.setObject(CachedLayout(result), forKey: key)
        return result
    }

    private static func computeLayout(_ text: String, in box: CGRect, style: TextStyle, scale: CGFloat) -> Layout? {
        guard !text.isEmpty, box.width > 4, box.height > 4 else { return nil }
        if let fixed = style.fontSize {
            return make(text, box: box, style: style, size: CGFloat(fixed) * scale)
        }
        var lo = minFontSize, hi = max(minFontSize, min(box.height, box.width) / 1.5)
        var best = make(text, box: box, style: style, size: lo)
        for _ in 0..<12 {
            let mid = (lo + hi) / 2
            if let candidate = make(text, box: box, style: style, size: mid), fits(candidate) {
                best = candidate
                lo = mid
            } else {
                hi = mid
            }
        }
        return best
    }

    public static func draw(_ layout: Layout, style: TextStyle, in ctx: CGContext, scale: CGFloat) {
        ctx.saveGState()
        // Centre vertically: Core Text fills the frame from the top.
        ctx.translateBy(x: 0, y: -(layout.box.height - layout.usedHeight) / 2)
        if style.strokeWidth > 0 {
            ctx.setLineJoin(.round)
            ctx.setLineWidth(CGFloat(style.strokeWidth) * scale * 2)
            ctx.setStrokeColor(style.strokeColor.cgColor)
            ctx.setTextDrawingMode(.stroke)
            CTFrameDraw(layout.frame, ctx)
        }
        ctx.setTextDrawingMode(.fill)
        CTFrameDraw(layout.frame, ctx)
        ctx.restoreGState()
    }

    static func attributed(_ text: String, style: TextStyle, size: CGFloat) -> NSAttributedString {
        let font = CTFontCreateWithName(style.fontName as CFString, size, nil)
        var alignment: CTTextAlignment = switch style.alignment {
        case .left: .left
        case .center: .center
        case .right: .right
        }
        var lineBreak = CTLineBreakMode.byWordWrapping
        var multiple = CGFloat(style.lineHeight)
        let settings = [
            CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: &alignment),
            CTParagraphStyleSetting(spec: .lineBreakMode, valueSize: MemoryLayout<CTLineBreakMode>.size, value: &lineBreak),
            CTParagraphStyleSetting(spec: .lineHeightMultiple, valueSize: MemoryLayout<CGFloat>.size, value: &multiple),
        ]
        let paragraph = CTParagraphStyleCreate(settings, settings.count)
        return NSAttributedString(string: style.uppercase ? text.uppercased() : text, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: style.color.cgColor,
            kCTParagraphStyleAttributeName as NSAttributedString.Key: paragraph,
        ])
    }

    private static func make(_ text: String, box: CGRect, style: TextStyle, size: CGFloat) -> Layout? {
        let string = attributed(text, style: style, size: size)
        let setter = CTFramesetterCreateWithAttributedString(string)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: box, transform: nil), nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        guard !lines.isEmpty else { return nil }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        var descent: CGFloat = 0
        CTLineGetTypographicBounds(lines.last!, nil, &descent, nil)
        let used = box.height - (origins.last!.y - descent)
        return Layout(frame: frame, box: box, fontSize: size, usedHeight: min(box.height, used), text: string.string as NSString)
    }

    /// All characters placed and every line break falls between words.
    private static func fits(_ layout: Layout) -> Bool {
        let visible = CTFrameGetVisibleStringRange(layout.frame)
        guard visible.location + visible.length >= layout.text.length else { return false }
        for line in (CTFrameGetLines(layout.frame) as! [CTLine]).dropLast() {
            let range = CTLineGetStringRange(line)
            let end = range.location + range.length
            guard end > 0, end <= layout.text.length else { continue }
            let before = layout.text.character(at: end - 1)
            // Core Text keeps the trailing space on a wrapped line; anything else is a mid-word break.
            guard let scalar = UnicodeScalar(before), CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-—–")).contains(scalar) else {
                return false
            }
        }
        return true
    }
}
