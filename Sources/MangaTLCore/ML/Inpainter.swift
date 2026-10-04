import CoreGraphics
import Foundation

/// Removes the original lettering. Produces a page-sized patch layer: erased pixels are opaque,
/// everything else transparent, so the source page is never modified.
///
/// Text on a flat balloon is filled with the balloon's own colour (exact and instant); text over
/// screentone is rebuilt along the tone's dot lattice (`ToneFill`); other artwork goes through
/// AOT-GAN (Koharu's default inpainter) in 256² tiles — the tile size Phase 0 measured at +150 MB
/// peak, versus +400 MB at 512².
enum Inpainter {
    static let tile = 256
    static let context = 24
    static let dilation = 3
    /// Luma distance from the balloon colour that counts as ink.
    static let inkThreshold = 48
    /// Max luma spread of the non-ink pixels for a region to count as a flat balloon.
    static let flatSpread = 14.0

    struct Job {
        var rect: CGRect           // pixels to consider (text rect, slightly grown)
        var mask: [Bool]           // rect-sized, true = erase
        var flatColor: (UInt8, UInt8, UInt8)?
    }

    static func patch(for page: PixelBuffer, regions: [CGRect]) throws -> PixelBuffer {
        var patch = PixelBuffer(width: page.width, height: page.height)
        let jobs = regions.map { job(page: page, region: $0) }
        for job in jobs { if let color = job.flatColor { fill(&patch, job: job, color: color) } }
        let artwork = jobs.filter { job in
            guard job.flatColor == nil else { return false }
            let others = jobs.map(\.rect).filter { $0 != job.rect }
            return !ToneFill.fill(&patch, page: page, rect: job.rect, mask: job.mask, avoid: others)
        }
        if !artwork.isEmpty {
            try OnnxModel.withSession(.inpainter) { session in
                for job in artwork { try inpaint(&patch, page: page, job: job, session: session) }
            }
        }
        return patch
    }

    /// Heals an arbitrary user-painted mask (editor brush): screentone along its lattice, else AOT.
    static func heal(_ page: PixelBuffer, rect: CGRect, mask: [Bool]) throws -> PixelBuffer {
        var patch = PixelBuffer(width: page.width, height: page.height)
        let job = Job(rect: rect, mask: mask, flatColor: nil)
        if !ToneFill.fill(&patch, page: page, rect: rect, mask: mask) {
            try OnnxModel.withSession(.inpainter) { session in try inpaint(&patch, page: page, job: job, session: session) }
        }
        return patch.cropped(to: rect)
    }

    /// Erases lettering inside a user-drawn outline (`area`: rect-sized, row-major, true = inside).
    /// On a flat balloon only the ink is filled; on artwork the whole outline is rebuilt, like the
    /// automatic clean-up. Returns a rect-sized buffer, erased pixels opaque.
    static func erase(_ page: PixelBuffer, rect: CGRect, area: [Bool]) throws -> PixelBuffer {
        var job = job(page: page, region: rect, grow: 0)
        let w = Int(rect.width), jw = Int(job.rect.width), jx = Int(job.rect.minX), jy = Int(job.rect.minY)
        for i in job.mask.indices {
            let x = jx + i % jw - Int(rect.minX), y = jy + i / jw - Int(rect.minY)
            let inside = x >= 0 && y >= 0 && x < w && y < Int(rect.height) && area[y * w + x]
            if !inside || job.flatColor == nil { job.mask[i] = inside }
        }
        var patch = PixelBuffer(width: page.width, height: page.height)
        if let color = job.flatColor {
            fill(&patch, job: job, color: color)
        } else if !ToneFill.fill(&patch, page: page, rect: job.rect, mask: job.mask) {
            try OnnxModel.withSession(.inpainter) { session in try inpaint(&patch, page: page, job: job, session: session) }
        }
        return patch.cropped(to: rect)
    }

    /// Builds the ink mask for one text region and decides whether a flat fill is enough.
    static func job(page: PixelBuffer, region: CGRect, grow: CGFloat = 4) -> Job {
        let rect = region.insetBy(dx: -grow, dy: -grow).integral.intersection(CGRect(x: 0, y: 0, width: page.width, height: page.height))
        let crop = page.cropped(to: rect)
        let luma = crop.luma()
        // Balloon colour = the most common luma bucket (glyphs are a minority of the box).
        var hist = [Int](repeating: 0, count: 32)
        for l in luma { hist[Int(l) >> 3] += 1 }
        let bucket = hist.indices.max { hist[$0] < hist[$1] }!
        let background = bucket * 8 + 4
        var mask = luma.map { abs(Int($0) - background) > inkThreshold }
        mask = dilate(mask, width: crop.width, height: crop.height, radius: dilation)

        let paper = luma.indices.filter { !mask[$0] }
        let fraction = Double(paper.count) / Double(max(1, luma.count))
        var flat: (UInt8, UInt8, UInt8)?
        if fraction > 0.3 {
            let values = paper.map { Double(luma[$0]) }
            let mean = values.reduce(0, +) / Double(values.count)
            let spread = (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
            if spread < flatSpread {
                let sum = paper.reduce((0, 0, 0)) { acc, i in
                    (acc.0 + Int(crop.bytes[i * 4]), acc.1 + Int(crop.bytes[i * 4 + 1]), acc.2 + Int(crop.bytes[i * 4 + 2]))
                }
                let n = paper.count
                flat = (UInt8(sum.0 / n), UInt8(sum.1 / n), UInt8(sum.2 / n))
            }
        }
        // Over artwork the thresholded mask misses anti-aliased edges and outlines; erase the box.
        if flat == nil { mask = [Bool](repeating: true, count: mask.count) }
        return Job(rect: rect, mask: mask, flatColor: flat)
    }

    static func dilate(_ mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        var horizontal = mask
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] {
                for dx in max(0, x - radius)...min(width - 1, x + radius) { horizontal[y * width + dx] = true }
            }
        }
        var out = horizontal
        for y in 0..<height {
            for x in 0..<width where horizontal[y * width + x] {
                for dy in max(0, y - radius)...min(height - 1, y + radius) { out[dy * width + x] = true }
            }
        }
        return out
    }

    private static func fill(_ patch: inout PixelBuffer, job: Job, color: (UInt8, UInt8, UInt8)) {
        let w = Int(job.rect.width), x0 = Int(job.rect.minX), y0 = Int(job.rect.minY)
        for (i, erase) in job.mask.enumerated() where erase {
            let p = ((y0 + i / w) * patch.width + x0 + i % w) * 4
            patch.bytes[p] = color.0; patch.bytes[p + 1] = color.1; patch.bytes[p + 2] = color.2; patch.bytes[p + 3] = 255
        }
    }

    /// Covers the job with 256² tiles; each tile carries `context` px of untouched surroundings.
    private static func inpaint(_ patch: inout PixelBuffer, page: PixelBuffer, job: Job, session: OnnxModel.Session) throws {
        let step = tile - 2 * context
        var ty = Int(job.rect.minY)
        repeat {
            var tx = Int(job.rect.minX)
            repeat {
                let core = CGRect(x: tx, y: ty, width: min(step, Int(job.rect.maxX) - tx), height: min(step, Int(job.rect.maxY) - ty))
                let window = CGRect(x: max(0, Int(core.midX) - tile / 2), y: max(0, Int(core.midY) - tile / 2), width: tile, height: tile)
                    .intersection(CGRect(x: 0, y: 0, width: page.width, height: page.height))
                try runTile(&patch, page: page, job: job, core: core, window: window, session: session)
                tx += step
            } while tx < Int(job.rect.maxX)
            ty += step
        } while ty < Int(job.rect.maxY)
    }

    private static func runTile(_ patch: inout PixelBuffer, page: PixelBuffer, job: Job, core: CGRect, window: CGRect, session: OnnxModel.Session) throws {
        // AOT needs sides divisible by 8.
        let w = Int(window.width) / 8 * 8, h = Int(window.height) / 8 * 8
        guard w >= 8, h >= 8 else { return }
        let wx = Int(window.minX), wy = Int(window.minY)
        let jw = Int(job.rect.width), jx = Int(job.rect.minX), jy = Int(job.rect.minY)
        var mask = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let px = wx + x, py = wy + y
                guard core.contains(CGPoint(x: px, y: py)) else { continue }
                if job.mask[(py - jy) * jw + (px - jx)] { mask[y * w + x] = 1 }
            }
        }
        guard mask.contains(1) else { return }
        let crop = page.cropped(to: CGRect(x: wx, y: wy, width: w, height: h))
        let plane = w * h
        var image = [Float](repeating: 0, count: plane * 3)
        for i in 0..<plane where mask[i] == 0 {
            for c in 0..<3 { image[c * plane + i] = Float(crop.bytes[i * 4 + c]) / 127.5 - 1 }
        }
        let out = try session.run([
            "image": try OnnxModel.tensor(image, shape: [1, 3, h, w]),
            "mask": try OnnxModel.tensor(mask, shape: [1, 1, h, w]),
        ], outputs: ["inpainted"])
        let result = try OnnxModel.floats(out["inpainted"]!)
        for i in 0..<plane where mask[i] == 1 {
            let p = ((wy + i / w) * patch.width + wx + i % w) * 4
            for c in 0..<3 { patch.bytes[p + c] = UInt8(max(0, min(255, (result[c * plane + i] + 1) * 127.5))) }
            patch.bytes[p + 3] = 255
        }
    }
}
