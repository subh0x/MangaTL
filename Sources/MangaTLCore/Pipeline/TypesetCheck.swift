import CoreGraphics
import Foundation

/// Lints a page's lettering against common typesetting rules: everything fits, sizes are
/// consistent, no orphaned short word on the last line, text keeps clear of balloon edges.
public enum TypesetCheck {
    public enum Kind: String, Sendable, CaseIterable {
        case overflow, tooSmall, tooLarge, loneWord, mixedSizes, edgeTouch

        public var title: String {
            switch self {
            case .overflow: "Text doesn't fit"
            case .tooSmall: "Much smaller than the rest of the page"
            case .tooLarge: "Much larger than the rest of the page"
            case .loneWord: "Short word alone on the last line"
            case .mixedSizes: "Size differs from other boxes of this kind"
            case .edgeTouch: "Text touches the balloon edge"
            }
        }
    }

    /// A one-click fix the editor can apply to the block's style.
    public enum Fix: Hashable, Sendable {
        case autoFit
        case setSize(Double)
        case morePadding

        public var title: String {
            switch self {
            case .autoFit: "Auto-fit"
            case .setSize(let size): "Use \(Int(size.rounded())) px"
            case .morePadding: "Add space"
            }
        }

        public func apply(to style: inout TextStyle) {
            switch self {
            case .autoFit: style.fontSize = nil
            case .setSize(let size): style.fontSize = size
            case .morePadding: style.padding = min(0.3, style.padding + 0.04)
            }
        }
    }

    public struct Issue: Identifiable, Hashable, Sendable {
        public var block: UUID
        public var kind: Kind
        public var fix: Fix?
        public var id: String { "\(block)-\(kind.rawValue)" }
    }

    public static func check(_ doc: PageDoc, settings: ProjectSettings) -> [Issue] {
        let size = doc.workingSize
        let entries = doc.blocks.filter { !$0.hidden && !$0.translation.isEmpty }.compactMap { block -> (TextBlock, TextStyle, Typesetter.Layout)? in
            let style = settings.resolvedStyle(for: block)
            return PageRenderer.textLayout(block, style: style, pageSize: size, scale: 1).map { (block, style, $0) }
        }
        let pageMedian = Self.median(entries.map { Double($0.2.fontSize) })
        var issues: [Issue] = []
        for (block, style, layout) in entries {
            let fixed = style.fontSize != nil
            if layout.overflow {
                issues.append(Issue(block: block.id, kind: .overflow, fix: fixed ? .autoFit : nil))
                continue
            }
            // Auto-fit sizes vary with text length; only outliers are worth a look.
            if let pageMedian, Double(layout.fontSize) < pageMedian * 0.6 {
                issues.append(Issue(block: block.id, kind: .tooSmall, fix: fixed ? .autoFit : nil))
            }
            if let pageMedian, Double(layout.fontSize) > pageMedian * 1.5 {
                issues.append(Issue(block: block.id, kind: .tooLarge, fix: .setSize(pageMedian)))
            }
            if layout.lines.count > 1, let last = layout.lines.last, !last.text.contains(" "), last.text.count <= 4 {
                issues.append(Issue(block: block.id, kind: .loneWord, fix: fixed ? .autoFit : nil))
            }
            // Lines are laid out inside the padding, so filling it is fine; with (almost) no padding
            // a full line really does touch the balloon outline.
            if style.padding < 0.05, zip(layout.lines, layout.available).contains(where: { $0.width >= $1 * 0.985 }) {
                issues.append(Issue(block: block.id, kind: .edgeTouch, fix: fixed ? .autoFit : .morePadding))
            }
        }
        // Fixed sizes that stray from the others of the same role.
        let byRole = Dictionary(grouping: entries.filter { $0.1.fontSize != nil }) { $0.0.role ?? .dialogue }
        for (_, group) in byRole where group.count > 1 {
            guard let typical = Self.median(group.compactMap { $0.1.fontSize }) else { continue }
            for (block, style, _) in group where abs(style.fontSize! - typical) > typical * 0.15 {
                issues.append(Issue(block: block.id, kind: .mixedSizes, fix: .setSize(typical)))
            }
        }
        // In reading order.
        let order = Dictionary(uniqueKeysWithValues: doc.blocks.enumerated().map { ($1.id, $0) })
        return issues.sorted { (order[$0.block] ?? 0, $0.kind.rawValue) < (order[$1.block] ?? 0, $1.kind.rawValue) }
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }
}
