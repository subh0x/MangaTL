import Foundation


/// Baberu OCR (manga-trained, Japanese + Chinese, vertical text, furigana), ported from
/// genshiai-daichi/baberu-ocr `onnx_infer.py`. The vision tower embeds every crop first and is
/// released before the decoder graphs load, so only one model is resident at a time.
enum MangaOCR {
    static let inputSize = 224
    static let mean: [Float] = [0.485, 0.456, 0.406]
    static let std: [Float] = [0.229, 0.224, 0.225]
    static let maxNewTokens = 128
    static let repetitionPenalty: Float = 1.2
    static let maxContentRun = 12
    static let bos: Int64 = 1, eos: Int64 = 2
    static let past = (0..<6).map { "past_k\($0)" } + (0..<6).map { "past_v\($0)" }
    static let present = (0..<6).map { "present_k\($0)" } + (0..<6).map { "present_v\($0)" }

    static func recognize(_ crops: [PixelBuffer]) throws -> [String] {
        guard !crops.isEmpty else { return [] }
        let embeds: [OnnxModel.Value] = try OnnxModel.withSession(.baberuVision) { vision in
            try crops.map { crop in
                let pixels = PixelBuffer(crop.makeImage(), width: inputSize, height: inputSize).chwFloats(mean: mean, std: std)
                return try vision.run(["pixel_values": try OnnxModel.tensor(pixels, shape: [1, 3, inputSize, inputSize])],
                                      outputs: ["vision_embeds"])["vision_embeds"]!
            }
        }
        let vocab = try Vocab.shared()
        return try OnnxModel.withSession(.baberuPrefill) { prefill in
            try OnnxModel.withSession(.baberuStep) { step in
                try embeds.map { try decode(embeds: $0, prefill: prefill, step: step, vocab: vocab) }
            }
        }
    }

    private static func decode(embeds: OnnxModel.Value, prefill: OnnxModel.Session, step: OnnxModel.Session, vocab: Vocab) throws -> String {
        var out = try prefill.run(["vision_embeds": embeds, "input_ids": try OnnxModel.tensor([bos], shape: [1, 1])],
                                  outputs: ["logits"] + present)
        var position = Int64(try OnnxModel.shape(embeds)[1] + 1)
        var seen: Set<Int> = [Int(bos)]
        var tokens: [Int] = []
        for _ in 0..<maxNewTokens {
            var logits = try OnnxModel.floats(out["logits"]!)
            logits = Array(logits.suffix(vocab.size))
            for id in seen where id < logits.count {
                logits[id] = logits[id] < 0 ? logits[id] * repetitionPenalty : logits[id] / repetitionPenalty
            }
            if let last = tokens.last, vocab.isContent(last) {
                let run = tokens.reversed().prefix { $0 == last }.count
                if run >= maxContentRun { logits[last] = -.infinity }
            }
            let next = logits.indices.max { logits[$0] < logits[$1] }!
            if next == Int(eos) { break }
            tokens.append(next)
            seen.insert(next)
            var feed: [String: OnnxModel.Value] = [
                "input_ids": try OnnxModel.tensor([Int64(next)], shape: [1, 1]),
                "position_ids": try OnnxModel.tensor([position], shape: [1, 1]),
            ]
            for (p, q) in zip(past, present) { feed[p] = out[q] }
            out = try step.run(feed, outputs: ["logits"] + present)
            position += 1
        }
        return vocab.decode(tokens)
    }

    /// Character vocabulary: ids 0…3 are special, id ≥ 4 maps to `charset[id - 4]`.
    final class Vocab: @unchecked Sendable {
        let charset: [String]
        let content: Set<Int>
        var size: Int { charset.count + 4 }

        private nonisolated(unsafe) static var cached: Vocab?
        private static let lock = NSLock()

        static func shared() throws -> Vocab {
            try lock.withLock {
                if let cached { return cached }
                let data = try Data(contentsOf: try ModelStore.url(.baberuVocab))
                let vocab = Vocab(charset: try JSONDecoder().decode([String].self, from: data))
                cached = vocab
                return vocab
            }
        }

        init(charset: [String]) {
            self.charset = charset
            // Letters/numbers (not long-vowel marks or tildes) get the repeat cap.
            content = Set(charset.indices.filter { i in
                let s = charset[i]
                guard s.unicodeScalars.count == 1, !"ーｰ〜~".contains(s), let scalar = s.unicodeScalars.first else { return false }
                switch scalar.properties.generalCategory {
                case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                     .decimalNumber, .letterNumber, .otherNumber: return true
                default: return false
                }
            }.map { $0 + 4 })
        }

        func isContent(_ id: Int) -> Bool { content.contains(id) }
        func decode(_ ids: [Int]) -> String { ids.compactMap { $0 >= 4 && $0 - 4 < charset.count ? charset[$0 - 4] : nil }.joined() }
    }
}
