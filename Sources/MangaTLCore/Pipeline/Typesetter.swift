import CoreGraphics
import CoreText
import Foundation

/// Letters a translation into its balloon the way scanlation typesetters do by hand:
/// the text block forms a "diamond" (short lines at the top and bottom, the longest in the
/// middle, following the balloon's curve), lines break between words, hyphenation is a last
/// resort, and the largest size that fits is chosen.
public enum Typesetter {
    public static let minFontSize: CGFloat = 6

    public struct Line {
        public var line: CTLine
        public var width: CGFloat
        public var text: String
    }

    public struct Layout {
        public var lines: [Line]
        public var fontSize: CGFloat
        /// Distance between baselines and the font's ascent/descent (unscaled).
        public var lineAdvance: CGFloat
        public var ascent: CGFloat
        public var descent: CGFloat
        /// The usable area (bottom-left origin) before glyph scaling.
        public var box: CGRect
        /// Space available to each line (unscaled), for alignment and the typeset check.
        public var available: [CGFloat]
        /// Nothing fit, even at the minimum size (or at the fixed size); drawn best-effort.
        public var overflow: Bool
        public var hyphenated: Bool
    }

    /// The area text may use inside a block's frame: `padding` of the size is kept clear on each side.
    public static func usableBox(for rect: CGRect, padding: Double) -> CGRect {
        let p = CGFloat(min(0.4, max(0, padding)))
        return rect.insetBy(dx: rect.width * p, dy: rect.height * p)
    }

    // MARK: Layout

    private final class CachedLayout { let layout: Layout?; init(_ l: Layout?) { layout = l } }
    /// The size search runs many layouts; editors redraw every frame while dragging.
    nonisolated(unsafe) private static let cache: NSCache<NSString, CachedLayout> = {
        let cache = NSCache<NSString, CachedLayout>()
        cache.countLimit = 512
        return cache
    }()

    /// `rect` is the block's frame in a bottom-left-origin space (Core Text's).
    public static func layout(_ text: String, in rect: CGRect, shape: BlockShape, style: TextStyle, scale: CGFloat) -> Layout? {
        let key = "\(text)|\(rect)|\(shape)|\(scale)|\(style.hashValue)" as NSString
        if let hit = cache.object(forKey: key) { return hit.layout }
        let result = computeLayout(text, in: rect, shape: shape, style: style, scale: scale)
        cache.setObject(CachedLayout(result), forKey: key)
        return result
    }

    private static func computeLayout(_ text: String, in rect: CGRect, shape: BlockShape, style: TextStyle, scale: CGFloat) -> Layout? {
        let content = (style.uppercase ? text.uppercased() : text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, rect.width > 4, rect.height > 4 else { return nil }
        // Work in unscaled glyph space: a 1.3× tall shout has 1/1.3 of the height to fill.
        let usable = usableBox(for: rect, padding: style.padding)
        let hs = CGFloat(max(0.5, style.horizontalScale)), vs = CGFloat(max(0.5, style.verticalScale))
        let box = CGRect(x: usable.midX - usable.width / hs / 2, y: usable.midY - usable.height / vs / 2,
                         width: usable.width / hs, height: usable.height / vs)
        let geometry = Geometry(box: box, shape: shape, alignment: style.alignment)

        if let fixed = style.fontSize {
            let size = CGFloat(fixed) * scale
            return arrange(content, size: size, style: style, geometry: geometry, allowHyphens: true)
                ?? fallback(content, size: size, style: style, geometry: geometry)
        }
        // Largest size that fits, first without hyphenation; hyphenate only if that buys a lot.
        let plain = search(content, style: style, geometry: geometry, allowHyphens: false)
        let hyphenated = plain == nil || content.split(whereSeparator: \.isWhitespace).contains { $0.count >= 6 }
            ? search(content, style: style, geometry: geometry, allowHyphens: true) : nil
        var chosen = plain
        if let h = hyphenated, plain == nil || h.fontSize > plain!.fontSize * 1.35 { chosen = h }
        guard var layout = chosen else {
            return fallback(content, size: minFontSize, style: style, geometry: geometry)
        }
        // Whispers etc. sit smaller than the largest size that fits.
        if style.sizeFactor != 1, let scaled = arrange(content, size: max(minFontSize, layout.fontSize * CGFloat(style.sizeFactor)),
                                                        style: style, geometry: geometry, allowHyphens: layout.hyphenated) {
            layout = scaled
        }
        return layout
    }

    private static func search(_ text: String, style: TextStyle, geometry: Geometry, allowHyphens: Bool) -> Layout? {
        var lo = minFontSize, hi = max(minFontSize, min(geometry.box.height, geometry.box.width) / 1.2)
        var best = arrange(text, size: lo, style: style, geometry: geometry, allowHyphens: allowHyphens)
        guard best != nil else { return nil }
        for _ in 0..<12 {
            let mid = (lo + hi) / 2
            if let candidate = arrange(text, size: mid, style: style, geometry: geometry, allowHyphens: allowHyphens) {
                best = candidate
                lo = mid
            } else {
                hi = mid
            }
        }
        return best
    }

    /// The balloon's shape: how wide a line may be at a given height.
    struct Geometry {
        var box: CGRect
        var shape: BlockShape
        var alignment: TextAlignment

        /// Width available to a band of text between `y0` and `y1` (bottom-left space).
        func width(from y0: CGFloat, to y1: CGFloat) -> CGFloat {
            guard shape == .ellipse else { return box.width }
            let b = box.height / 2, cy = box.midY
            // The band edge farthest from the centre is the narrowest point the line must clear.
            let dy = max(abs(y0 - cy), abs(y1 - cy))
            guard dy < b else { return 0 }
            return box.width * (1 - (dy / b) * (dy / b)).squareRoot()
        }
    }

    struct Token {
        var text: String
        var width: CGFloat
        /// A line must end after this token (explicit newline, or first half of a hyphenated word).
        var breakAfter: Bool
    }

    /// Breaks `text` into a diamond at `size`, or nil if it can't fit.
    static func arrange(_ text: String, size: CGFloat, style: TextStyle, geometry: Geometry, allowHyphens: Bool) -> Layout? {
        let font = Self.font(style, size: size)
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let advance = (ascent + descent) * CGFloat(style.lineHeight)
        let maxLines = Int(geometry.box.height / advance)
        guard maxLines >= 1 else { return nil }
        let space = measure(" ", font: font)
        var tokens = tokenize(text, font: font)
        if allowHyphens {
            tokens = hyphenate(tokens, limit: geometry.width(from: geometry.box.midY - advance / 2, to: geometry.box.midY + advance / 2),
                               font: font)
        }
        guard !tokens.isEmpty else { return nil }

        var best: (cost: CGFloat, breaks: [Int], available: [CGFloat])?
        for n in 1...min(maxLines, tokens.count) {
            let available = (0..<n).map { k -> CGFloat in
                // Lines are stacked and centred vertically in the box.
                let top = geometry.box.midY + CGFloat(n) * advance / 2 - CGFloat(k) * advance
                return geometry.width(from: top - advance, to: top)
            }
            if let (cost, breaks) = bestBreaks(tokens, lines: n, available: available, space: space, diamond: geometry.shape == .ellipse) {
                let total = cost + CGFloat(n) * 0.02   // prefer fewer lines when shapes are equally good
                if best == nil || total < best!.cost { best = (total, breaks, available) }
            }
        }
        guard let best else { return nil }
        var lines: [Line] = []
        var start = 0
        for end in best.breaks {
            let words = tokens[start..<end].map(\.text)
            let joined = words.joined(separator: " ")
            lines.append(Line(line: ctLine(joined, font: font, color: style.color), width: measure(joined, font: font), text: joined))
            start = end
        }
        return Layout(lines: lines, fontSize: size, lineAdvance: advance, ascent: ascent, descent: descent, box: geometry.box,
                      available: best.available, overflow: false, hyphenated: tokens.contains { $0.text.hasSuffix("-") && $0.breakAfter })
    }

    /// Dynamic programme over break points: `n` lines, each within its available width, closest to
    /// the target shape (a diamond in balloons, even lines in boxes). Returns line end indices.
    static func bestBreaks(_ tokens: [Token], lines n: Int, available: [CGFloat], space: CGFloat, diamond: Bool)
        -> (CGFloat, [Int])? {
        let count = tokens.count
        var prefix = [CGFloat](repeating: 0, count: count + 1)
        for i in 0..<count { prefix[i + 1] = prefix[i] + tokens[i].width }
        func width(_ i: Int, _ j: Int) -> CGFloat { prefix[j] - prefix[i] + CGFloat(j - i - 1) * space }
        let average = (prefix[count] + CGFloat(count - n) * space) / CGFloat(n)
        let inf = CGFloat.greatestFiniteMagnitude
        // cost[k][j]: best cost with k lines covering tokens 0..<j.
        var cost = [[CGFloat]](repeating: [CGFloat](repeating: inf, count: count + 1), count: n + 1)
        var from = [[Int]](repeating: [Int](repeating: -1, count: count + 1), count: n + 1)
        cost[0][0] = 0
        for k in 1...n {
            let limit = available[k - 1]
            guard limit > 0 else { continue }
            let target = diamond ? limit * 0.9 : min(limit, average)
            for j in k...count {
                for i in (k - 1)..<j where cost[k - 1][i] < inf {
                    // A forced break inside the line is not allowed.
                    if (i..<(j - 1)).contains(where: { tokens[$0].breakAfter }) { continue }
                    let w = width(i, j)
                    if w > limit { continue }
                    let miss = (target - w) / max(1, limit)
                    var c = cost[k - 1][i] + miss * miss
                    // A lone short word on the last line reads badly.
                    if k == n, n > 1, j - i == 1, tokens[i].text.count <= 4 { c += 0.5 }
                    if c < cost[k][j] {
                        cost[k][j] = c
                        from[k][j] = i
                    }
                }
            }
        }
        guard cost[n][count] < inf else { return nil }
        var breaks: [Int] = []
        var j = count
        for k in stride(from: n, to: 0, by: -1) {
            breaks.append(j)
            j = from[k][j]
        }
        return (cost[n][count] / CGFloat(n), breaks.reversed())
    }

    static func tokenize(_ text: String, font: CTFont) -> [Token] {
        var tokens: [Token] = []
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: true) {
            for word in paragraph.split(whereSeparator: \.isWhitespace) {
                tokens.append(Token(text: String(word), width: measure(String(word), font: font), breakAfter: false))
            }
            if !tokens.isEmpty { tokens[tokens.count - 1].breakAfter = true }
        }
        if !tokens.isEmpty { tokens[tokens.count - 1].breakAfter = false }
        return tokens
    }

    /// Splits words wider than `limit` once, near the middle, at a dictionary hyphenation point.
    /// Short words (under 6 letters) are never split.
    static func hyphenate(_ tokens: [Token], limit: CGFloat, font: CTFont) -> [Token] {
        tokens.flatMap { token -> [Token] in
            guard token.width > limit, token.text.count >= 6 else { return [token] }
            let ns = token.text as NSString
            let location = CFStringGetHyphenationLocationBeforeIndex(ns, ns.length / 2 + 1, CFRange(location: 0, length: ns.length),
                                                                     0, Locale(identifier: "en") as CFLocale, nil)
            guard location > 1, location < ns.length - 1 else { return [token] }
            let head = ns.substring(to: location) + "-", tail = ns.substring(from: location)
            return [Token(text: head, width: measure(head, font: font), breakAfter: true),
                    Token(text: tail, width: measure(tail, font: font), breakAfter: token.breakAfter)]
        }
    }

    /// Greedy wrap at `size`, ignoring the shape: used when nothing fits, so the text is still shown.
    private static func fallback(_ text: String, size: CGFloat, style: TextStyle, geometry: Geometry) -> Layout? {
        let font = Self.font(style, size: size)
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let space = measure(" ", font: font)
        var lines: [[Token]] = [[]]
        var width: CGFloat = 0
        for token in tokenize(text, font: font) {
            if !lines[lines.count - 1].isEmpty, width + space + token.width > geometry.box.width {
                lines.append([])
                width = 0
            }
            width += (lines[lines.count - 1].isEmpty ? 0 : space) + token.width
            lines[lines.count - 1].append(token)
            if token.breakAfter { lines.append([]); width = 0 }
        }
        let built = lines.filter { !$0.isEmpty }.map { words -> Line in
            let joined = words.map(\.text).joined(separator: " ")
            return Line(line: ctLine(joined, font: font, color: style.color), width: measure(joined, font: font), text: joined)
        }
        guard !built.isEmpty else { return nil }
        return Layout(lines: built, fontSize: size, lineAdvance: (ascent + descent) * CGFloat(style.lineHeight), ascent: ascent,
                      descent: descent, box: geometry.box, available: built.map { _ in geometry.box.width }, overflow: true,
                      hyphenated: false)
    }

    // MARK: Drawing

    public static func draw(_ layout: Layout, style: TextStyle, in ctx: CGContext, scale: CGFloat) {
        let box = layout.box
        ctx.saveGState()
        // Glyph scaling about the box centre (layout was computed in unscaled space).
        ctx.translateBy(x: box.midX, y: box.midY)
        ctx.scaleBy(x: CGFloat(style.horizontalScale), y: CGFloat(style.verticalScale))
        ctx.translateBy(x: -box.midX, y: -box.midY)
        ctx.textMatrix = .identity

        let total = CGFloat(layout.lines.count) * layout.lineAdvance
        let top = box.midY + total / 2
        let gap = layout.lineAdvance - (layout.ascent + layout.descent)
        let origins: [CGPoint] = layout.lines.enumerated().map { k, line in
            let baseline = top - CGFloat(k) * layout.lineAdvance - gap / 2 - layout.ascent
            let room = layout.available.indices.contains(k) ? min(layout.available[k], box.width) : box.width
            let x: CGFloat = switch style.alignment {
            case .center: box.midX - line.width / 2
            case .left: box.midX - room / 2
            case .right: box.midX + room / 2 - line.width
            }
            return CGPoint(x: x, y: baseline)
        }
        // Outline first at twice the width, fill on top: the visible stroke sits outside the glyphs.
        if style.strokeWidth > 0 {
            ctx.setLineJoin(.round)
            ctx.setLineWidth(CGFloat(style.strokeWidth) * scale * 2)
            ctx.setStrokeColor(style.strokeColor.cgColor)
            ctx.setTextDrawingMode(.stroke)
            for (line, origin) in zip(layout.lines, origins) {
                ctx.textPosition = origin
                CTLineDraw(line.line, ctx)
            }
        }
        ctx.setTextDrawingMode(.fill)
        for (line, origin) in zip(layout.lines, origins) {
            ctx.textPosition = origin
            CTLineDraw(line.line, ctx)
        }
        ctx.restoreGState()
    }

    // MARK: Fonts

    /// The style's font at `size`, switched to the family's bold/italic face when requested.
    static func font(_ style: TextStyle, size: CGFloat) -> CTFont {
        let base = CTFontCreateWithName(style.fontName as CFString, size, nil)
        var traits = CTFontSymbolicTraits()
        if style.bold { traits.insert(.traitBold) }
        if style.italic { traits.insert(.traitItalic) }
        guard !traits.isEmpty else { return base }
        if let styled = CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, [.traitBold, .traitItalic]) { return styled }
        // Families like CC Wild Words ship Italic and Bold Italic but no plain Bold.
        if traits.contains(.traitBold),
           let italicBold = CTFontCreateCopyWithSymbolicTraits(base, size, nil, [.traitBold, .traitItalic], [.traitBold, .traitItalic]) {
            return italicBold
        }
        return base
    }

    static func measure(_ text: String, font: CTFont) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(ctLine(text, font: font, color: CGColor(gray: 0, alpha: 1)), nil, nil, nil))
    }

    static func ctLine(_ text: String, font: CTFont, color: CGColor) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: color,
        ]))
    }

    static func ctLine(_ text: String, font: CTFont, color: RGBA) -> CTLine { ctLine(text, font: font, color: color.cgColor) }
}
