import COnnxRuntime
import Foundation

/// Minimal Swift wrapper over ONNX Runtime's C API.
///
/// Every session is opened for the duration of `withSession` and released when it returns, with
/// the CPU memory arena and memory-pattern planning disabled. The arena kept freed activations
/// resident between runs (Baberu: +470 MB via the Objective-C API vs +143 MB with it off).
enum OnnxModel {
    nonisolated(unsafe) static let api: OrtApi = OrtGetApiBase().pointee.GetApi(UInt32(ORT_API_VERSION))!.pointee

    /// The C API documents OrtEnv as thread-safe; one per process.
    nonisolated(unsafe) private static let env: OpaquePointer? = {
        var env: OpaquePointer?
        let status = api.CreateEnv(ORT_LOGGING_LEVEL_WARNING, "MangaTL", &env)
        return status == nil ? env : nil
    }()

    static func check(_ status: OpaquePointer?) throws {
        guard let status else { return }
        let message = api.GetErrorMessage(status).map { String(cString: $0) } ?? "unknown error"
        api.ReleaseStatus(status)
        throw PipelineError.model(message)
    }

    static func withSession<T>(_ file: ModelStore.File, threads: Int32 = 4, _ body: (Session) throws -> T) throws -> T {
        guard let env else { throw PipelineError.model("ONNX Runtime failed to start") }
        var options: OpaquePointer?
        try check(api.CreateSessionOptions(&options))
        defer { api.ReleaseSessionOptions(options) }
        try check(api.SetIntraOpNumThreads(options, threads))
        try check(api.SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL))
        try check(api.DisableCpuMemArena(options))
        try check(api.DisableMemPattern(options))
        var session: OpaquePointer?
        try check(api.CreateSession(env, try ModelStore.url(file).path, options, &session))
        defer {
            api.ReleaseSession(session)
            // The allocator keeps freed model buffers dirty (and counted in the footprint) until told.
            malloc_zone_pressure_relief(nil, 0)
        }
        return try body(Session(handle: session!))
    }

    struct Session {
        let handle: OpaquePointer

        /// Runs the graph; outputs are owned by the returned `Value`s.
        func run(_ inputs: [String: Value], outputs: [String]) throws -> [String: Value] {
            let names = Array(inputs.keys)
            let values: [OpaquePointer?] = names.map { inputs[$0]!.handle }
            var results = [OpaquePointer?](repeating: nil, count: outputs.count)
            try withCStrings(names) { inNames in
                try withCStrings(outputs) { outNames in
                    try check(api.Run(handle, nil, inNames, values, names.count, outNames, outputs.count, &results))
                }
            }
            return Dictionary(uniqueKeysWithValues: zip(outputs, results.map { Value(owned: $0!) }))
        }
    }

    /// An OrtValue tensor. Input tensors keep their Swift buffer alive for as long as the value.
    final class Value: @unchecked Sendable {
        let handle: OpaquePointer
        private let storage: UnsafeMutableRawPointer?

        init(owned handle: OpaquePointer) {
            self.handle = handle
            storage = nil
        }

        init<T>(_ values: [T], shape: [Int], type: ONNXTensorElementDataType) throws {
            let bytes = values.count * MemoryLayout<T>.stride
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(bytes, 1), alignment: 64)
            values.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress!, byteCount: bytes) }
            var info: OpaquePointer?
            try check(api.CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &info))
            defer { api.ReleaseMemoryInfo(info) }
            var value: OpaquePointer?
            let dims = shape.map(Int64.init)
            do {
                try check(api.CreateTensorWithDataAsOrtValue(info, buffer, bytes, dims, dims.count, type, &value))
            } catch {
                buffer.deallocate()
                throw error
            }
            handle = value!
            storage = buffer
        }

        deinit {
            api.ReleaseValue(handle)
            storage?.deallocate()
        }

        var shape: [Int] {
            var info: OpaquePointer?
            guard api.GetTensorTypeAndShape(handle, &info) == nil else { return [] }
            defer { api.ReleaseTensorTypeAndShapeInfo(info) }
            var count = 0
            _ = api.GetDimensionsCount(info, &count)
            var dims = [Int64](repeating: 0, count: count)
            _ = api.GetDimensions(info, &dims, count)
            return dims.map(Int.init)
        }

        func elements<T>(_: T.Type) throws -> [T] {
            var data: UnsafeMutableRawPointer?
            try check(api.GetTensorMutableData(handle, &data))
            let count = shape.reduce(1, *)
            return Array(UnsafeBufferPointer(start: data!.assumingMemoryBound(to: T.self), count: count))
        }
    }

    static func tensor(_ values: [Float], shape: [Int]) throws -> Value { try Value(values, shape: shape, type: ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) }
    static func tensor(_ values: [Int64], shape: [Int]) throws -> Value { try Value(values, shape: shape, type: ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64) }
    static func floats(_ value: Value) throws -> [Float] { try value.elements(Float.self) }
    static func int64s(_ value: Value) throws -> [Int64] { try value.elements(Int64.self) }
    static func shape(_ value: Value) throws -> [Int] { value.shape }
}

/// Passes `strings` to C as a `const char* const*` for the duration of `body`.
private func withCStrings<R>(_ strings: [String], _ body: ([UnsafePointer<CChar>?]) throws -> R) throws -> R {
    let duplicated = strings.map { strdup($0) }
    defer { duplicated.forEach { free($0) } }
    return try body(duplicated.map { UnsafePointer($0) })
}
