import CoreGraphics
import Foundation

/// Rebuilds erased screentone by copying it along its own dot lattice.
///
/// Manga tones are regular dot (or line) screens. A learned inpainter at 256² smears them into a
/// grey blob; instead, find the screen's lattice vectors from the surroundings and fill each erased
/// pixel from the nearest untouched pixels that sit on the same lattice position. Those samples
/// share the dot phase, so dots stay crisp and aligned, and blending the samples from opposite
/// sides (weighted by distance) carries gradient and duotone ramps across the hole.
enum ToneFill {
    /// Surroundings examined around the erased rect.
    static let ring = 48
    /// Longest lattice vector looked for (px at working resolution).
    static let maxShift = 40
    /// Minimum autocorrelation for a lattice peak, and how far it must rise above the dip before it.
    static let minPeak: Float = 0.4
    static let minRise: Float = 0.25
    /// Below this luma spread the area is flat, not a tone.
    static let minSpread: Float = 12

    /// Fills the masked pixels of `rect` (page pixels; `mask` rect-sized, row-major) into `patch`.
    /// Pixels inside `avoid` (other text being erased) are never used as samples. Returns false and
    /// leaves `patch` untouched when the surroundings aren't a regular tone.
    static func fill(_ patch: inout PixelBuffer, page: PixelBuffer, rect: CGRect, mask: [Bool], avoid: [CGRect] = []) -> Bool {
        let bounds = CGRect(x: 0, y: 0, width: page.width, height: page.height)
        let r = rect.insetBy(dx: -CGFloat(ring), dy: -CGFloat(ring)).integral.intersection(bounds)
        guard !r.isNull, r.width > 8, r.height > 8 else { return false }
        let area = Area(page: page, region: r, rect: rect, mask: mask, avoid: avoid)
        guard let vectors = lattice(area) else { return false }
        let inks = area.inks()

        var directions = [vectors.0, -vectors.0]
        if let v2 = vectors.1 { directions += [v2, -v2, vectors.0 + v2, -(vectors.0 + v2), vectors.0 - v2, -(vectors.0 - v2)] }
        let w = Int(rect.width), x0 = Int(rect.minX), y0 = Int(rect.minY)
        var out: [(Int, (UInt8, UInt8, UInt8))] = []
        out.reserveCapacity(mask.count)
        for (i, erase) in mask.enumerated() where erase {
            let p = SIMD2<Double>(Double(x0 + i % w), Double(y0 + i / w))
            var sum = SIMD3<Double>(repeating: 0), weights = 0.0
            for d in directions {
                let length = (d * d).sum().squareRoot()
                var k = 1
                while Double(k) * length < Double(max(r.width, r.height)) {
                    let q = p + d * Double(k)
                    guard area.contains(q) else { break }
                    if let sample = area.sample(q) {
                        let weight = 1 / (Double(k) * length)
                        sum += sample * weight
                        weights += weight
                        break
                    }
                    k += 1
                }
            }
            guard weights > 0 else { return false }
            var c = sum / weights
            // Blending dots of neighbouring sizes leaves soft grey rims; on a two-colour (or duotone)
            // screen, snap back towards its two inks so dots keep their crisp edge.
            if let (dark, light) = inks {
                let span = light - dark
                let t = ((c - dark) * span).sum() / max(1, (span * span).sum())
                let e = max(0, min(1, (t - 0.3) / 0.4))
                c = dark + span * (e * e * (3 - 2 * e))
            }
            out.append((i, (UInt8(max(0, min(255, c.x.rounded()))), UInt8(max(0, min(255, c.y.rounded()))), UInt8(max(0, min(255, c.z.rounded()))))))
        }
        for (i, c) in out {
            let p = ((y0 + i / w) * patch.width + x0 + i % w) * 4
            patch.bytes[p] = c.0; patch.bytes[p + 1] = c.1; patch.bytes[p + 2] = c.2; patch.bytes[p + 3] = 255
        }
        return true
    }

    /// The examined region: luma and which pixels are untouched (usable as samples).
    struct Area {
        let page: PixelBuffer
        let region: CGRect
        let width: Int, height: Int
        var luma: [Float]
        var known: [Bool]

        init(page: PixelBuffer, region: CGRect, rect: CGRect, mask: [Bool], avoid: [CGRect]) {
            self.page = page
            self.region = region
            width = Int(region.width)
            height = Int(region.height)
            luma = [Float](repeating: 0, count: width * height)
            known = [Bool](repeating: true, count: width * height)
            let rw = Int(rect.width), rx = Int(rect.minX), ry = Int(rect.minY)
            for y in 0..<height {
                for x in 0..<width {
                    let px = Int(region.minX) + x, py = Int(region.minY) + y, i = (py * page.width + px) * 4
                    luma[y * width + x] = 0.299 * Float(page.bytes[i]) + 0.587 * Float(page.bytes[i + 1]) + 0.114 * Float(page.bytes[i + 2])
                    let point = CGPoint(x: px, y: py)
                    if rect.contains(point), mask[(py - ry) * rw + px - rx] { known[y * width + x] = false }
                    if avoid.contains(where: { $0.contains(point) }) { known[y * width + x] = false }
                }
            }
        }

        /// The screen's two inks (dark dots, light paper) when nearly every known pixel is close to
        /// one of them; nil for continuous-tone surroundings.
        func inks() -> (SIMD3<Double>, SIMD3<Double>)? {
            let values = luma.indices.filter { known[$0] }.map { luma[$0] }.sorted()
            guard values.count > 100 else { return nil }
            let lo = values[values.count / 20], hi = values[values.count * 19 / 20]
            guard hi - lo > 60 else { return nil }
            let band = (hi - lo) * 0.25
            var dark = SIMD3<Double>(repeating: 0), light = SIMD3<Double>(repeating: 0), nd = 0.0, nl = 0.0, near = 0
            for i in luma.indices where known[i] {
                let px = Int(region.minX) + i % width, py = Int(region.minY) + i / width, j = (py * page.width + px) * 4
                let color = SIMD3(Double(page.bytes[j]), Double(page.bytes[j + 1]), Double(page.bytes[j + 2]))
                if luma[i] <= lo + band { dark += color; nd += 1; near += 1 } else if luma[i] >= hi - band { light += color; nl += 1; near += 1 }
            }
            // Anti-aliased rims sit between the inks; a bilevel screen still has most pixels near one.
            guard nd > 0, nl > 0, Double(near) > 0.75 * Double(values.count) else { return nil }
            return (dark / nd, light / nl)
        }

        func contains(_ p: SIMD2<Double>) -> Bool {
            p.x >= region.minX && p.y >= region.minY && p.x <= region.maxX - 1 && p.y <= region.maxY - 1
        }

        /// Bilinear colour at `p` (page pixels) if all four neighbours are known.
        func sample(_ p: SIMD2<Double>) -> SIMD3<Double>? {
            let fx = p.x - region.minX, fy = p.y - region.minY
            let x = Int(fx.rounded(.down)), y = Int(fy.rounded(.down))
            let x1 = min(x + 1, width - 1), y1 = min(y + 1, height - 1)
            guard known[y * width + x], known[y * width + x1], known[y1 * width + x], known[y1 * width + x1] else { return nil }
            let tx = fx - Double(x), ty = fy - Double(y)
            func color(_ cx: Int, _ cy: Int) -> SIMD3<Double> {
                let i = ((Int(region.minY) + cy) * page.width + Int(region.minX) + cx) * 4
                return SIMD3(Double(page.bytes[i]), Double(page.bytes[i + 1]), Double(page.bytes[i + 2]))
            }
            let top = color(x, y) * (1 - tx) + color(x1, y) * tx
            let bottom = color(x, y1) * (1 - tx) + color(x1, y1) * tx
            return top * (1 - ty) + bottom * ty
        }
    }

    /// The tone's lattice vectors (sub-pixel), from autocorrelation of the known pixels. The second
    /// is nil for line tones. Nil when there's no clear periodic peak.
    static func lattice(_ area: Area) -> (SIMD2<Double>, SIMD2<Double>?)? {
        // Sample positions: known pixels, thinned to keep the cost bounded.
        let all = area.known.indices.filter { area.known[$0] }
        guard all.count > 400 else { return nil }
        let stride = max(1, all.count / 6000)
        let samples = Swift.stride(from: 0, to: all.count, by: stride).map { all[$0] }
        let mean = samples.reduce(Float(0)) { $0 + area.luma[$1] } / Float(samples.count)
        let variance = samples.reduce(Float(0)) { $0 + (area.luma[$1] - mean) * (area.luma[$1] - mean) } / Float(samples.count)
        guard variance.squareRoot() >= minSpread else { return nil }

        func correlation(_ dx: Int, _ dy: Int) -> Float {
            var sum: Float = 0, n = 0
            area.luma.withUnsafeBufferPointer { luma in
                area.known.withUnsafeBufferPointer { known in
                    for i in samples {
                        let x = i % area.width + dx, y = i / area.width + dy
                        guard x >= 0, y >= 0, x < area.width, y < area.height else { continue }
                        let j = y * area.width + x
                        guard known[j] else { continue }
                        sum += (luma[i] - mean) * (luma[j] - mean)
                        n += 1
                    }
                }
            }
            return n < 100 ? -1 : sum / Float(n) / variance
        }

        // Half-plane of shifts (the other half mirrors it).
        let m = maxShift, side = 2 * m + 1
        var grid = [Float](repeating: -1, count: side * side)
        func at(_ dx: Int, _ dy: Int) -> Float {
            guard abs(dx) <= m, abs(dy) <= m else { return -1 }
            return dy > 0 || (dy == 0 && dx >= 0) ? grid[(dy + m) * side + dx + m] : grid[(-dy + m) * side - dx + m]
        }
        for dy in 0...m {
            for dx in -m...m where dy > 0 || dx > 0 { grid[(dy + m) * side + dx + m] = correlation(dx, dy) }
        }
        grid[m * side + m] = 1

        // Lowest correlation reached within each radius: a real lattice peak rises above that dip.
        var dip = [Float](repeating: 1, count: m * 2 + 2)
        for dy in 0...m {
            for dx in -m...m where dy > 0 || dx > 0 {
                let radius = Int((Double(dx * dx + dy * dy)).squareRoot().rounded(.up))
                if radius < dip.count { dip[radius] = min(dip[radius], at(dx, dy)) }
            }
        }
        for i in 1..<dip.count { dip[i] = min(dip[i], dip[i - 1]) }

        var peaks: [(v: SIMD2<Double>, value: Float)] = []
        for dy in 0...m {
            for dx in -m...m where dy > 0 || dx > 0 {
                let value = at(dx, dy), length = Double(dx * dx + dy * dy).squareRoot()
                guard length >= 2.5, value >= minPeak else { continue }
                let isMax = (-1...1).allSatisfy { ny in (-1...1).allSatisfy { nx in (nx == 0 && ny == 0) || at(dx + nx, dy + ny) <= value } }
                guard isMax, value - dip[max(0, Int(length.rounded(.down)) - 1)] >= minRise else { continue }
                peaks.append((SIMD2(Double(dx), Double(dy)), value))
            }
        }
        peaks.sort { ($0.v * $0.v).sum() < ($1.v * $1.v).sum() }
        guard let first = peaks.first else { return nil }
        let second = peaks.first { candidate in
            let cross = abs(first.v.x * candidate.v.y - first.v.y * candidate.v.x)
            return cross > 0.5 * (first.v * first.v).sum().squareRoot() * (candidate.v * candidate.v).sum().squareRoot()
        }

        // Screens rarely have whole-pixel periods: measure ever farther multiples of the vector and
        // divide, so copying several periods away stays in phase. Each step's estimate is within a
        // pixel of the next multiple, so a ±1 search finds it.
        func refine(_ v: SIMD2<Double>) -> SIMD2<Double> {
            var v = v
            let limit = Int(Double(m) / (v * v).sum().squareRoot())
            guard limit >= 2 else { return v }
            for n in 2...limit {
                let guess = v * Double(n)
                var best = (value: -Float.infinity, offset: guess)
                for oy in -1...1 {
                    for ox in -1...1 {
                        let dx = Int(guess.x.rounded()) + ox, dy = Int(guess.y.rounded()) + oy
                        let value = correlation(dx, dy)
                        if value > best.value { best = (value, SIMD2(Double(dx), Double(dy))) }
                    }
                }
                v = best.offset / Double(n)
            }
            return v
        }
        return (refine(first.v), second.map { refine($0.v) })
    }
}
