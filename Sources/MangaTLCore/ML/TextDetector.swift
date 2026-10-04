import CoreGraphics
import Foundation

/// A detected region in page pixel coordinates (origin top-left).
public struct Detection: Equatable, Sendable {
    public enum Kind: Int, Sendable { case bubble = 0, textInBubble = 1, freeText = 2 }
    public var kind: Kind
    public var rect: CGRect
    public var score: Float
}

/// ogkalu comic-text-and-bubble-detector (RT-DETR-v2, v4-s int8): bubbles, text in bubbles and
/// free text. Chosen over Koharu's RF-DETR in Phase 0 — same recall on dialogue at ~1/10 the memory.
enum TextDetector {
    static let inputSize = 640
    static let minScore: Float = 0.4

    static func detect(_ page: PixelBuffer) throws -> [Detection] {
        let input = PixelBuffer(page.makeImage(), width: inputSize, height: inputSize).chwFloats()
        return try OnnxModel.withSession(.detector) { session in
            let out = try session.run([
                "images": try OnnxModel.tensor(input, shape: [1, 3, inputSize, inputSize]),
                "orig_target_sizes": try OnnxModel.tensor([Int64(page.width), Int64(page.height)], shape: [1, 2]),
            ], outputs: ["labels", "boxes", "scores"])
            let labels = try OnnxModel.int64s(out["labels"]!)
            let boxes = try OnnxModel.floats(out["boxes"]!)
            let scores = try OnnxModel.floats(out["scores"]!)
            let bounds = CGRect(x: 0, y: 0, width: page.width, height: page.height)
            return labels.indices.compactMap { i in
                guard scores[i] >= minScore, let kind = Detection.Kind(rawValue: Int(labels[i])) else { return nil }
                let b = boxes[i * 4..<i * 4 + 4].map { CGFloat($0) }
                let rect = CGRect(x: b[0], y: b[1], width: b[2] - b[0], height: b[3] - b[1]).intersection(bounds)
                return rect.width >= 4 && rect.height >= 4 ? Detection(kind: kind, rect: rect, score: scores[i]) : nil
            }
        }
    }
}

/// Turns raw detections into ordered text regions, each paired with the bubble it sits in.
enum PageLayout {
    struct Region {
        var text: CGRect
        var bubble: CGRect?
    }

    static func regions(from detections: [Detection], rightToLeft: Bool) -> [Region] {
        let texts = suppress(detections.filter { $0.kind != .bubble })
        let bubbles = detections.filter { $0.kind == .bubble }
        let regions = texts.map { text -> Region in
            // The bubble that contains most of this text (≥ 60 % of its area).
            let bubble = bubbles
                .map { ($0.rect, $0.rect.intersection(text.rect).area / max(1, text.rect.area)) }
                .filter { $0.1 >= 0.6 }
                .max { $0.1 < $1.1 }?.0
            return Region(text: text.rect, bubble: bubble)
        }
        return readingOrder(regions, rightToLeft: rightToLeft)
    }

    /// Non-maximum suppression: the detector sometimes reports one balloon's text twice.
    static func suppress(_ detections: [Detection], iou threshold: CGFloat = 0.5) -> [Detection] {
        var kept: [Detection] = []
        for d in detections.sorted(by: { $0.score > $1.score }) where !kept.contains(where: { $0.rect.iou(d.rect) > threshold }) {
            kept.append(d)
        }
        return kept
    }

    /// Rows top-to-bottom (regions whose vertical extents overlap by half share a row), then
    /// right-to-left within a row for manga, left-to-right otherwise.
    static func readingOrder(_ regions: [Region], rightToLeft: Bool) -> [Region] {
        var rows: [[Region]] = []
        for region in regions.sorted(by: { $0.text.minY < $1.text.minY }) {
            if let i = rows.firstIndex(where: { row in
                row.contains { other in
                    let overlap = min(other.text.maxY, region.text.maxY) - max(other.text.minY, region.text.minY)
                    return overlap > 0.5 * min(other.text.height, region.text.height)
                }
            }) {
                rows[i].append(region)
            } else {
                rows.append([region])
            }
        }
        return rows.flatMap { row in row.sorted { rightToLeft ? $0.text.midX > $1.text.midX : $0.text.midX < $1.text.midX } }
    }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }

    func iou(_ other: CGRect) -> CGFloat {
        let inter = intersection(other).area
        return inter / max(1, area + other.area - inter)
    }
}
