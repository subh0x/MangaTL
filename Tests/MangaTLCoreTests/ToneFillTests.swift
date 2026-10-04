import CoreGraphics
import Foundation
import Testing
@testable import MangaTLCore

@Suite struct ToneFillTests {
    /// A 45° dot screen with a non-integer period whose dots grow from left to right (a gradient tone).
    static func tone(width: Int = 360, height: Int = 260, period: Double = 6.4, gradient: Bool = true) -> PixelBuffer {
        var page = PixelBuffer(width: width, height: height, fill: 255)
        for y in 0..<height {
            for x in 0..<width {
                let u = (Double(x) + Double(y)) / 2.squareRoot() / period, v = (Double(x) - Double(y)) / 2.squareRoot() / period
                let du = (u - u.rounded()) * period, dv = (v - v.rounded()) * period
                let radius = gradient ? 0.8 + 2.4 * Double(x) / Double(width) : 2
                // 2× supersampled edge so dots have anti-aliased rims like scans.
                let distance = (du * du + dv * dv).squareRoot()
                let ink = max(0, min(1, radius + 0.5 - distance))
                let value = UInt8(255 - 255 * ink)
                let i = (y * width + x) * 4
                page.bytes[i] = value; page.bytes[i + 1] = value; page.bytes[i + 2] = value
            }
        }
        return page
    }

    static let hole = CGRect(x: 150, y: 100, width: 70, height: 50)

    /// Mean absolute luma error of `patch` against `truth` inside the hole.
    static func error(_ patch: PixelBuffer, truth: PixelBuffer) -> Double {
        var total = 0.0, n = 0.0
        for y in Int(hole.minY)..<Int(hole.maxY) {
            for x in Int(hole.minX)..<Int(hole.maxX) {
                let i = (y * truth.width + x) * 4
                total += abs(Double(patch.bytes[i]) - Double(truth.bytes[i]))
                n += 1
            }
        }
        return total / n
    }

    @Test func rebuildsGradientDotsInPhase() {
        let truth = Self.tone()
        var page = truth
        // Lettering over the tone.
        for y in Int(Self.hole.minY) + 10..<Int(Self.hole.maxY) - 10 {
            for x in Int(Self.hole.minX) + 5..<Int(Self.hole.maxX) - 5 where (x / 4) % 2 == 0 {
                let i = (y * page.width + x) * 4
                page.bytes[i] = 0; page.bytes[i + 1] = 0; page.bytes[i + 2] = 0
            }
        }
        let mask = [Bool](repeating: true, count: Int(Self.hole.width * Self.hole.height))
        var patch = PixelBuffer(width: page.width, height: page.height)
        #expect(ToneFill.fill(&patch, page: page, rect: Self.hole, mask: mask))

        // Baseline: the hole filled with the tone's average grey (what a blurry inpaint converges to).
        var average = PixelBuffer(width: page.width, height: page.height)
        let mean = UInt8(truth.luma().reduce(0) { $0 + Int($1) } / (truth.width * truth.height))
        for i in 0..<average.width * average.height { average.bytes[i * 4] = mean }
        let filled = Self.error(patch, truth: truth), blurred = Self.error(average, truth: truth)
        #expect(filled < blurred * 0.25, "tone fill error \(filled) vs flat \(blurred)")
    }

    @Test func findsTheLattice() throws {
        let page = Self.tone(gradient: false)
        let area = ToneFill.Area(page: page, region: CGRect(x: 0, y: 0, width: 200, height: 200), rect: .zero, mask: [], avoid: [])
        let (v1, v2) = try #require(ToneFill.lattice(area))
        // 45° screen with period 6.4: vectors of length 6.4 along the diagonals.
        for v in [v1, try #require(v2)] {
            #expect(abs((v * v).sum().squareRoot() - 6.4) < 0.25, "\(v)")
            #expect(abs(abs(v.x) - abs(v.y)) < 0.4, "\(v)")
        }
    }

    @Test func ignoresFlatAndIrregularAreas() {
        let flat = PixelBuffer(width: 200, height: 200, fill: 255)
        var noise = flat
        var rng = SystemRandomNumberGenerator()
        for i in 0..<200 * 200 { let v = UInt8.random(in: 0...255, using: &rng); noise.bytes[i * 4] = v; noise.bytes[i * 4 + 1] = v; noise.bytes[i * 4 + 2] = v }
        let rect = CGRect(x: 70, y: 70, width: 60, height: 60)
        let mask = [Bool](repeating: true, count: 3600)
        for page in [flat, noise] {
            var patch = PixelBuffer(width: 200, height: 200)
            #expect(!ToneFill.fill(&patch, page: page, rect: rect, mask: mask))
            #expect(patch.opaqueBounds() == nil)
        }
    }
}
