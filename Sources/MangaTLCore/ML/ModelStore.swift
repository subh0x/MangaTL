import Foundation

/// Locates the converted models produced by `tools/export_models.py`.
/// Search order: `$MANGATL_MODELS`, `~/Library/Application Support/MangaTL/models`, `./models`.
public enum ModelStore {
    public enum File: String, CaseIterable, Sendable {
        case detector = "detect/detector-v4-s_int8.onnx"
        case baberuVision = "ocr/baberu/vision_int4.onnx"
        case baberuPrefill = "ocr/baberu/decoder_prefill_int8.onnx"
        case baberuStep = "ocr/baberu/decoder_step_int8.onnx"
        case baberuVocab = "ocr/baberu/vocab.json"
        case inpainter = "inpaint/aot.onnx"
    }

    public static var candidates: [URL] {
        var dirs: [URL] = []
        if let env = ProcessInfo.processInfo.environment["MANGATL_MODELS"] { dirs.append(URL(fileURLWithPath: env)) }
        dirs.append(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MangaTL/models"))
        dirs.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("models"))
        return dirs
    }

    /// The first directory holding every model file, if any.
    public static var root: URL? {
        candidates.first { dir in File.allCases.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.rawValue).path) } }
    }

    public static func url(_ file: File) throws -> URL {
        guard let root else { throw PipelineError.modelsMissing(candidates.map(\.path)) }
        return root.appendingPathComponent(file.rawValue)
    }
}

public enum PipelineError: Error, LocalizedError {
    case modelsMissing([String])
    case model(String)
    case translationUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .modelsMissing(let paths):
            "OCR models not found. Run tools/export_models.py, then copy models/ to one of: \(paths.joined(separator: ", "))"
        case .model(let message): "Model error: \(message)"
        case .translationUnavailable(let lang):
            "The \(lang) → English language pack isn't installed. Download it in System Settings › General › Language & Region › Translation Languages."
        }
    }
}
