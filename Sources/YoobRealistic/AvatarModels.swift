import Foundation
import Accelerate
import CryptoKit
@preconcurrency import CoreML

/// The realistic face's encoder and renderer. Immutable after load, and every prediction runs off the caller's actor
/// (nonisolated async), so the steady encoder (CPU) and the renderer (Neural Engine) work at the same time: the lip pipeline
/// encodes the next audio while it renders the frame before (`StreamingAvatar.append`). Core ML predictions are
/// thread-safe; the pipeline never runs one model twice at once anyway.
public final class AvatarModels: @unchecked Sendable {
    public let pack: AvatarPack
    private let encoder: MLModel
    private let renderer: MLModel
    private let steadyEncoder: MLModel
    private let encoderOutput: String
    private let rendererOutput: String
    private let steadyOutput: String
    /// `units` applies to the accelerated models (steady encoder and renderer). After an install `.all` specializes for the
    /// Neural Engine for ~72 s on an iPhone Air; `.cpuAndGPU` loads in ~0.3 s but costs ~4x more per frame.
    /// `encoderUnits` overrides `units` for the steady encoder alone.
    public static func load(pack: AvatarPack, cpuOnly: Bool = false, units: MLComputeUnits = .all, encoderUnits: MLComputeUnits? = nil,
                            priority: TaskPriority = .userInitiated, lowPrecisionGPU: Bool = false) async throws -> AvatarModels {
        try await Task.detached(priority: priority) {
            try AvatarModels(pack: pack, cpuOnly: cpuOnly, units: units, encoderUnits: encoderUnits, lowPrecisionGPU: lowPrecisionGPU)
        }.value
    }
    /// The GPU and Neural Engine loads start together after an install: each package compiles once, not twice at once.
    private static let compileLock = NSLock()
    /// `lowPrecisionGPU`: fp16 accumulation on the GPU (MLModelConfiguration.allowLowPrecisionAccumulationOnGPU).
    public init(pack: AvatarPack, cpuOnly: Bool = false, units: MLComputeUnits = .all, encoderUnits: MLComputeUnits? = nil,
                lowPrecisionGPU: Bool = false) throws {
        self.pack = pack
        func load(_ directory: String, units: MLComputeUnits) throws -> MLModel {
            let configuration = MLModelConfiguration(); configuration.computeUnits = units
            configuration.allowLowPrecisionAccumulationOnGPU = lowPrecisionGPU
            return try MLModel(contentsOf: try Self.compiled(directory, pack: pack), configuration: configuration)
        }
        encoder = try load(pack.manifest.runtimeEncoder, units: .cpuOnly)
        steadyEncoder = cpuOnly ? encoder : try load("encoder21.mlpackage", units: encoderUnits ?? units)
        renderer = try load("renderer.mlpackage", units: cpuOnly ? .cpuOnly : units)
        guard encoder.modelDescription.inputDescriptionsByName["audio"] != nil,
              let image = renderer.modelDescription.inputDescriptionsByName["image"],
              renderer.modelDescription.inputDescriptionsByName["audio"] != nil,
              encoder.modelDescription.outputDescriptionsByName.count == 1,
              renderer.modelDescription.outputDescriptionsByName.count == 1,
              let first = encoder.modelDescription.outputDescriptionsByName.keys.first,
              let second = renderer.modelDescription.outputDescriptionsByName.keys.first else { throw AvatarError.invalidPack("model interface") }
        guard let steady = steadyEncoder.modelDescription.outputDescriptionsByName.keys.first else { throw AvatarError.invalidPack("steady encoder") }
        // The renderer must be the size the manifest declares (`CropGeometry`): a mismatch fails here, not on the first frame.
        let geometry = pack.geometry
        func matches(_ description: MLFeatureDescription?, _ shape: [Int]) -> Bool {
            let declared = description?.multiArrayConstraint?.shape.map(\.intValue) ?? []
            return declared.isEmpty || declared == shape
        }
        guard matches(image, [1, 6, geometry.inner, geometry.inner]),
              matches(renderer.modelDescription.outputDescriptionsByName[second], [1, 3, geometry.output, geometry.output]) else {
            throw AvatarError.invalidPack("renderer size")
        }
        encoderOutput = first; rendererOutput = second; steadyOutput = steady
    }
    /// The verified package compiled once into Caches, keyed by its files' checksums.
    static func compiled(_ directory: String, pack: AvatarPack) throws -> URL {
        let path = try pack.verifyModel(directory)
        let receipts = pack.manifest.files.keys.filter { $0.hasPrefix(directory + "/") }.sorted()
            .map { $0 + ":" + pack.manifest.files[$0]!.sha256 }.joined(separator: "\n")
        let key = SHA256.hash(data: Data(receipts.utf8)).map { String(format: "%02x", $0) }.joined()
        let folder = URL.cachesDirectory.appendingPathComponent("LanguageCompanions/CoreML/" + key)
        let compiled = folder.appendingPathComponent("model.mlmodelc")
        try compileLock.withLock {
            if !FileManager.default.fileExists(atPath: compiled.path) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let result = try MLModel.compileModel(at: path)
                do { try FileManager.default.moveItem(at: result, to: compiled) }
                catch { if !FileManager.default.fileExists(atPath: compiled.path) { throw error } }
            }
        }
        return compiled
    }
    /// One steady encode and one render on silence, so a call's first frame never pays Core ML's first-prediction
    /// specialization (~6.7 s on the GPU after an install, measured on an iPhone Air).
    public func warmUp() async throws {
        if pack.manifest.encoderWindowFrames.contains(21) { _ = try encodeNow([Float](repeating: 0, count: 21 * 640 + 80), frameCount: 21) }
        _ = try renderCropNow(frame: 0, audio: [Float](repeating: 0, count: 40 * 1024))
    }
    /// Each prediction in its own autorelease pool: Core ML's output buffers are autoreleased, and a long run of predictions in
    /// one task (the lookahead study: 7 GB in 28 s, then Core ML aborted binding an output) otherwise keeps every one of them.
    public func encode(_ samples: [Float], frameCount: Int) async throws -> [Float] {
        try autoreleasepool { try encodeNow(samples, frameCount: frameCount) }
    }
    /// Returns BGR uint8 pixels at the output size square (`CropGeometry.output`: 288 for the 144 model), matching the
    /// exported model's channel convention.
    /// `referenceHost` optionally replaces the unmasked reference channels (0–2) with another host frame.
    /// Diagnostic only (`AvatarModelProbe --variants`): swapping the reference barely changes the silent
    /// mouth (about one grey level), so production rendering always uses the current host frame.
    public func renderCrop(frame: Int, audio: [Float], referenceHost: Int? = nil, host chosen: Int? = nil) async throws -> Data {
        try autoreleasepool { try renderCropNow(frame: frame, audio: audio, referenceHost: referenceHost, host: chosen) }
    }
    func encodeNow(_ samples: [Float], frameCount: Int) throws -> [Float] {
        guard pack.manifest.encoderWindowFrames.contains(frameCount), samples.count == frameCount * 640 + 80,
              samples.allSatisfy(\.isFinite) else { throw AvatarError.invalidAudio }
        let input = try MLMultiArray(shape: [1, NSNumber(value: samples.count)], dataType: .float32)
        let pointer = input.dataPointer.bindMemory(to: Float.self, capacity: input.count)
        // A true division per sample (vDSP's divide is not bit-exact); 13k samples, a few microseconds.
        let mean = pack.manifest.waveformMean, std = pack.manifest.waveformStd
        samples.withUnsafeBufferPointer { samples in for index in samples.indices { pointer[index] = (samples[index] - mean) / std } }
        let selected = frameCount == 21 ? steadyEncoder : encoder
        let result = try selected.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": input]))
        guard let output = result.featureValue(for: frameCount == 21 ? steadyOutput : encoderOutput)?.multiArrayValue,
              output.shape.map(\.intValue) == [1, frameCount * 2, 1024] else { throw AvatarError.invalidPack("encoder output") }
        return try Self.floats(output)
    }
    func renderCropNow(frame: Int, audio: [Float], referenceHost: Int? = nil, host chosen: Int? = nil) throws -> Data {
        guard audio.count == 40 * 1024, audio.allSatisfy(\.isFinite) else { throw AvatarError.invalidAudio }
        let geometry = pack.geometry, inner = geometry.inner, side = geometry.output, plane = inner * inner
        let host = chosen.map { min(max(0, $0), pack.manifest.frames.count - 1) } ?? pack.hostIndex(for: frame)
        let reference = referenceHost.map { min(max(0, $0), pack.manifest.frames.count - 1) } ?? host
        let image = try MLMultiArray(shape: [1, 6, NSNumber(value: inner), NSNumber(value: inner)], dataType: .float32)
        let pointer = image.dataPointer.bindMemory(to: Float.self, capacity: image.count)
        pack.innerPixels.withUnsafeBytes { crops in
            let pixels = crops.bindMemory(to: UInt8.self).baseAddress!
            Self.fillRendererImage(pointer, reference: pixels + reference * plane * 3, masked: pixels + host * plane * 3, geometry: geometry)
        }
        let sound = try MLMultiArray(shape: [1, 40, 1024], dataType: .float32)
        audio.withUnsafeBufferPointer { sound.dataPointer.copyMemory(from: $0.baseAddress!, byteCount: $0.count * 4) }
        let result = try renderer.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": image, "audio": sound]))
        guard let output = result.featureValue(for: rendererOutput)?.multiArrayValue,
              output.shape.map(\.intValue) == [1, 3, side, side] else { throw AvatarError.invalidPack("renderer output") }
        if output.dataType == .float32, output.strides.map(\.intValue) == [3 * side * side, side * side, side, 1] {
            let values = UnsafeBufferPointer(start: output.dataPointer.assumingMemoryBound(to: Float.self), count: output.count)
            guard values.allSatisfy(\.isFinite) else { throw AvatarError.invalidPack("nonfinite prediction") }
            return Self.bgrBytes(planar: values.baseAddress!, side: side)
        }
        return try Self.floats(output).withUnsafeBufferPointer { Self.bgrBytes(planar: $0.baseAddress!, side: side) }
    }

    /// The renderer's [1, 6, inner, inner] input from two inner-square BGR crops: channels 0-2 the reference, 3-5 the
    /// current host with the mouth hole zeroed (144: x 4..<139, y 4..<134), each byte / 255. Same values as the per-pixel
    /// loop it replaces (`AvatarConversionTests`).
    static func fillRendererImage(_ pointer: UnsafeMutablePointer<Float>, reference: UnsafePointer<UInt8>, masked: UnsafePointer<UInt8>,
                                  geometry: CropGeometry) {
        let inner = geometry.inner, hole = geometry.hole, plane = inner * inner
        var index = [Float](repeating: 0, count: plane)
        index.withUnsafeMutableBufferPointer { index in
            Self.byteScale.withUnsafeBufferPointer { table in
                for channel in 0..<3 {
                    // Byte to float index, then a gather from the exact byte / 255 table (vDSP's divide is not bit-exact).
                    vDSP_vfltu8(reference + channel, 3, index.baseAddress!, 1, vDSP_Length(plane))
                    vDSP_vindex(table.baseAddress!, index.baseAddress!, 1, pointer + channel * plane, 1, vDSP_Length(plane))
                    vDSP_vfltu8(masked + channel, 3, index.baseAddress!, 1, vDSP_Length(plane))
                    let maskedPlane = pointer + (channel + 3) * plane
                    vDSP_vindex(table.baseAddress!, index.baseAddress!, 1, maskedPlane, 1, vDSP_Length(plane))
                    for y in hole.y..<(hole.y + hole.height) { (maskedPlane + y * inner + hole.x).update(repeating: 0, count: hole.width) }
                }
            }
        }
    }
    private static let byteScale: [Float] = (0..<256).map { Float($0) / 255 }
    /// Planar [3, side, side] floats in 0...1 to interleaved BGR bytes: value * 255, clamped to 0...255, truncated, as
    /// `UInt8(max(0, min(255, v * 255)))` did per element.
    static func bgrBytes(planar: UnsafePointer<Float>, side: Int) -> Data {
        let count = side * side
        var bytes = Data(count: count * 3)
        var scaled = [Float](repeating: 0, count: count)
        var scale: Float = 255, low: Float = 0, high: Float = 255
        bytes.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: UInt8.self).baseAddress!
            scaled.withUnsafeMutableBufferPointer { scaled in
                for channel in 0..<3 {
                    vDSP_vsmul(planar + channel * count, 1, &scale, scaled.baseAddress!, 1, vDSP_Length(count))
                    vDSP_vclip(scaled.baseAddress!, 1, &low, &high, scaled.baseAddress!, 1, vDSP_Length(count))
                    vDSP_vfixu8(scaled.baseAddress!, 1, out + channel, 3, vDSP_Length(count))
                }
            }
        }
        return bytes
    }
    private static func floats(_ array: MLMultiArray) throws -> [Float] {
        guard array.dataType == .float32 || array.dataType == .float16 else { throw AvatarError.invalidPack("model output dtype") }
        let shape = array.shape.map(\.intValue), strides = array.strides.map(\.intValue)
        let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
        let halfPointer = array.dataPointer.assumingMemoryBound(to: Float16.self)
        var expected = 1, contiguous = true
        for axis in shape.indices.reversed() {
            if shape[axis] > 1 && strides[axis] != expected { contiguous = false }
            expected *= shape[axis]
        }
        if contiguous {
            let result = array.dataType == .float32 ? Array(UnsafeBufferPointer(start: pointer, count: array.count)) : UnsafeBufferPointer(start: halfPointer, count: array.count).map(Float.init)
            guard result.allSatisfy(\.isFinite) else { throw AvatarError.invalidPack("nonfinite prediction") }
            return result
        }
        var result = [Float](repeating: 0, count: array.count)
        for linear in 0..<array.count {
            var remainder = linear, offset = 0
            for axis in shape.indices.reversed() { offset += (remainder % shape[axis]) * strides[axis]; remainder /= shape[axis] }
            result[linear] = array.dataType == .float32 ? pointer[offset] : Float(halfPointer[offset])
        }
        guard result.allSatisfy(\.isFinite) else { throw AvatarError.invalidPack("nonfinite prediction") }
        return result
    }
}
