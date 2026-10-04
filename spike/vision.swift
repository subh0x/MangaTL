// Phase 0: Apple Vision OCR on detector boxes (v4s json) — accuracy eyeball + footprint.
import Foundation
import Vision
import ImageIO

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    return Double(info.phys_footprint) / 1_048_576
}
struct Det: Decodable { let cls: String; let box: [Double] }
let langs = ["kr": ["ko-KR"], "es": ["es-ES"], "fr": ["fr-FR"], "pt": ["pt-BR"], "ja": ["ja-JP"], "cn": ["zh-Hans"]]
var peak = footprintMB(); print(String(format: "baseline %.1f MB", peak))
for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    let code = String(url.lastPathComponent.prefix(2))
    let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
    let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
    let dets = try JSONDecoder().decode([Det].self, from: Data(contentsOf: url.deletingPathExtension().appendingPathExtension("v4s.json")))
    for d in dets where d.cls != "bubble" {
        let r = CGRect(x: d.box[0], y: d.box[1], width: d.box[2] - d.box[0], height: d.box[3] - d.box[1]).integral
        guard let crop = img.cropping(to: r) else { continue }
        var req = RecognizeTextRequest()
        req.recognitionLanguages = (langs[code] ?? ["en-US"]).map { Locale.Language(identifier: $0) }
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        let obs = try await req.perform(on: crop)
        let text = obs.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        peak = max(peak, footprintMB())
        print("\(url.lastPathComponent): \(text)")
    }
}
print(String(format: "vision peak footprint %.1f MB", peak))
