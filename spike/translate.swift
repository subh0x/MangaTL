// Phase 0: Apple Translation availability + memory spike.
// swiftc -O spike/translate.swift -o spike/translate && spike/translate
import Foundation
import Translation

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

let samples: [(String, [String])] = [
    ("ja", ["お前、本当にそれでいいのか？", "魔法のポーションを作るよ！"]),
    ("zh-Hans", ["你真的觉得这样就好了吗？", "我要做一个魔法药水！"]),
    ("ko", ["너 정말 그걸로 괜찮아?", "마법 물약을 만들 거야!"]),
    ("es", ["¿De verdad estás bien con eso?", "¡Voy a preparar una poción mágica!"]),
    ("fr", ["Tu es vraiment d'accord avec ça ?", "Je vais préparer une potion magique !"]),
    ("pt", ["Você está mesmo bem com isso?", "Vou fazer uma poção mágica!"]),
]

let english = Locale.Language(identifier: "en")
let availability = LanguageAvailability()
print(String(format: "baseline footprint %.1f MB", footprintMB()))
let only = CommandLine.arguments.dropFirst().first
for (code, lines) in samples where only == nil || only == code {
    let source = Locale.Language(identifier: code)
    let status = await availability.status(from: source, to: english)
    guard status == .installed else {
        print("\(code): \(status == .supported ? "supported, language pack NOT installed" : "unsupported")")
        continue
    }
    let session = TranslationSession(installedSource: source, target: english)
    let start = Date()
    do {
        let out = try await session.translations(from: lines.map { .init(sourceText: $0) })
        print(String(format: "%@ (%.2fs, app %.1f MB): ", code, Date().timeIntervalSince(start), footprintMB()) + out.map(\.targetText).joined(separator: " | "))
    } catch {
        print("\(code): error \(error)")
    }
}
