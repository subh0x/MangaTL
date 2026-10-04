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

@Suite struct BalloonEraseTests {
    /// Beige art, a white balloon with a black outline, and black lettering; the text box crosses
    /// the outline at the top. Only the lettering inside the balloon may be painted.
    @Test func flatFillStaysInsideTheBalloon() {
        let w = 300, h = 300
        var page = PixelBuffer(width: w, height: h)
        let center = (x: 150.0, y: 170.0), radius = (x: 110.0, y: 120.0)
        func set(_ x: Int, _ y: Int, _ v: (UInt8, UInt8, UInt8)) {
            let i = (y * w + x) * 4
            page.bytes[i] = v.0; page.bytes[i + 1] = v.1; page.bytes[i + 2] = v.2; page.bytes[i + 3] = 255
        }
        func ellipse(_ x: Int, _ y: Int) -> Double {
            let dx = (Double(x) - center.x) / radius.x, dy = (Double(y) - center.y) / radius.y
            return (dx * dx + dy * dy).squareRoot()
        }
        for y in 0..<h {
            for x in 0..<w {
                let e = ellipse(x, y)
                set(x, y, e > 1.03 ? (225, 205, 170) : e > 1 ? (0, 0, 0) : (255, 255, 255))
                // Letters: vertical strokes inside the balloon.
                if e < 0.8, y > 70, y < 200, (x / 6) % 3 == 0 { set(x, y, (0, 0, 0)) }
            }
        }
        // Text box from above the balloon's top edge down into it.
        let patch = try! Inpainter.patch(for: page, regions: [CGRect(x: 60, y: 40, width: 180, height: 170)])
        var paintedOutside = 0, erasedLetters = 0, letters = 0
        for y in 0..<h {
            for x in 0..<w {
                let painted = patch.bytes[(y * w + x) * 4 + 3] != 0
                if ellipse(x, y) > 1 && painted { paintedOutside += 1 }
                if ellipse(x, y) < 0.8, y > 70, y < 200, (x / 6) % 3 == 0 {
                    letters += 1
                    if painted { erasedLetters += 1 }
                }
            }
        }
        #expect(paintedOutside == 0)
        #expect(erasedLetters == letters)
    }

    /// Draws a balloon of any shape (white inside, 3 px black outline, beige art beyond) with
    /// vertical letter strokes where `letter` says, erases `box`, and checks nothing outside the
    /// balloon was painted while every letter was.
    static func check(inside: (Int, Int) -> Bool, letter: (Int, Int) -> Bool, box: CGRect) throws -> (outside: Int, missed: Int) {
        let w = 320, h = 300
        var page = PixelBuffer(width: w, height: h)
        func within(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && inside(x, y) }
        for y in 0..<h {
            for x in 0..<w {
                let near = (-3...3).contains { dy in (-3...3).contains { dx in within(x + dx, y + dy) } }
                let v: (UInt8, UInt8, UInt8) = within(x, y) ? (letter(x, y) ? (0, 0, 0) : (255, 255, 255)) : near ? (0, 0, 0) : (225, 205, 170)
                let i = (y * w + x) * 4
                page.bytes[i] = v.0; page.bytes[i + 1] = v.1; page.bytes[i + 2] = v.2; page.bytes[i + 3] = 255
            }
        }
        let patch = try Inpainter.patch(for: page, regions: [box])
        var outside = 0, missed = 0
        for y in 0..<h {
            for x in 0..<w {
                let painted = patch.bytes[(y * w + x) * 4 + 3] != 0
                if !within(x, y) && painted { outside += 1 }
                if within(x, y) && letter(x, y) && !painted { missed += 1 }
            }
        }
        return (outside, missed)
    }

    /// A thought cloud: a ring of overlapping circles, so the edge is scalloped.
    @Test func cloudBalloonKeepsItsScallops() throws {
        let bumps = (0..<10).map { i -> (Double, Double) in
            let a = Double(i) / 10 * 2 * .pi
            return (160 + cos(a) * 95, 150 + sin(a) * 85)
        }
        func inside(_ x: Int, _ y: Int) -> Bool {
            let dx = (Double(x) - 160) / 95, dy = (Double(y) - 150) / 85
            return dx * dx + dy * dy < 1 || bumps.contains { (Double(x) - $0.0) * (Double(x) - $0.0) + (Double(y) - $0.1) * (Double(y) - $0.1) < 32 * 32 }
        }
        let result = try Self.check(inside: inside, letter: { x, y in x > 100 && x < 220 && y > 110 && y < 190 && (x / 6) % 3 == 0 },
                                    box: CGRect(x: 40, y: 30, width: 240, height: 200))
        #expect(result.outside == 0)
        #expect(result.missed == 0)
    }

    /// Two balloons that overlap, the text in the left one and its box reaching into the right one
    /// and the notch between them.
    @Test func overlappingBalloonsKeepTheirOutlines() throws {
        func left(_ x: Int, _ y: Int) -> Bool { let dx = (Double(x) - 110) / 80, dy = (Double(y) - 150) / 100; return dx * dx + dy * dy < 1 }
        func right(_ x: Int, _ y: Int) -> Bool { let dx = (Double(x) - 225) / 75, dy = (Double(y) - 140) / 90; return dx * dx + dy * dy < 1 }
        let result = try Self.check(inside: { left($0, $1) || right($0, $1) },
                                    letter: { x, y in x > 70 && x < 150 && y > 100 && y < 200 && (x / 6) % 3 == 0 },
                                    box: CGRect(x: 50, y: 20, width: 200, height: 250))
        #expect(result.outside == 0)
        #expect(result.missed == 0)
    }
}
