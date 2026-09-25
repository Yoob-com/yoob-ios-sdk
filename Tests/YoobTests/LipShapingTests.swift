import XCTest
import CoreML
@testable import YoobRealistic

/// Lip shaping on the renderer window (`LipShaping`, the Luna app's study): off leaves every crop byte for byte.
final class LipShapingTests: XCTestCase {
    func testTheGainPushesTheWindowAwayFromTheClosedMouth() {
        let closed: [Float] = [0, 1, -1, 0.5]
        var window: [Float] = [1, 1, 0, 0.5]
        LipShaping(articulationGain: 1.5).apply(to: &window, closed: closed)
        XCTAssertEqual(window, [1.5, 1, 0.5, 0.5])
        // A sealed frame (the window is the closed one) stays exactly closed.
        var sealed = closed
        LipShaping(articulationGain: 1.2).apply(to: &sealed, closed: closed)
        XCTAssertEqual(sealed, closed)
    }

    func testGainOneIsIdentityAndTheGainIsClamped() {
        let closed: [Float] = [0.3, -0.7]
        var window: [Float] = [0.123456, 9.87654]
        let before = window
        let identity = LipShaping(articulationGain: 1)
        XCTAssertTrue(identity.isIdentity)
        identity.apply(to: &window, closed: closed)
        XCTAssertEqual(window, before)
        XCTAssertEqual(LipShaping(articulationGain: 7).articulationGain, 2)
        XCTAssertEqual(LipShaping(articulationGain: 0).articulationGain, 0.5)
        // A window of another length is left alone.
        var short: [Float] = [1]
        LipShaping(articulationGain: 1.5).apply(to: &short, closed: closed)
        XCTAssertEqual(short, [1])
    }

    /// With a pack (YOOB_REALISTIC_PACK, e.g. h08-v4), drawn as a direct WebRTC call draws Luna: no shaping, shaping nil and
    /// a gain of 1 give the same crops byte for byte; a gain of 1.1 changes her speaking mouth.
    func testOffIsByteIdenticalAndTheGainOnlyMovesTheSpeakingMouth() async throws {
        guard let path = ProcessInfo.processInfo.environment["YOOB_REALISTIC_PACK"] else { throw XCTSkip("no pack") }
        let pack = try AvatarPack(root: URL(fileURLWithPath: path))
        let models = try await AvatarModels.load(pack: pack, units: .cpuAndNeuralEngine, encoderUnits: .cpuOnly)
        let pcm = Data((0..<72_000).flatMap { index -> [UInt8] in
            let t = Double(index) / 24_000, syllable = 0.5 + 0.5 * sin(2 * .pi * 4 * t)
            let voiced = (t > 1.2 && t < 1.6) ? 0 : syllable * (sin(2 * .pi * 180 * t) + 0.5 * sin(2 * .pi * 360 * t) + 0.25 * sin(2 * .pi * 720 * t))
            let value = Int16(max(-32_000, min(32_000, voiced * 9_000)))
            return [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
        })
        let instant = StreamingAvatar.EarlyDrawing(lookaheadFrames: 3, batchFrames: 1, standIn: .mirror)
        func crops(_ shaping: LipShaping??) async throws -> [Int: Data] {
            let pipeline = StreamingAvatar(models: models, pack: pack), store = ShapedCropStore()
            await pipeline.setEarlyDrawing(instant)
            if let shaping { await pipeline.setLipShaping(shaping) }
            await pipeline.observeCrops { frame, crop in store.add(frame, crop) }
            let converter = try AvatarResampler()
            for start in stride(from: 0, to: pcm.count, by: 480) {
                _ = try await pipeline.append(samples: converter.convert(pcm.subdata(in: start..<min(pcm.count, start + 480))))
            }
            _ = try await pipeline.flushTail(segment: 0)
            return store.all
        }
        let untouched = try await crops(nil)
        let none = try await crops(.some(nil))
        let one = try await crops(.some(LipShaping(articulationGain: 1)))
        XCTAssertGreaterThan(untouched.count, 60)
        XCTAssertEqual(none, untouched, "shaping nil: every crop byte for byte")
        XCTAssertEqual(one, untouched, "gain 1: every crop byte for byte")
        let shaped = try await crops(.some(LipShaping(articulationGain: 1.1)))
        XCTAssertEqual(Set(shaped.keys), Set(untouched.keys))
        let changed = untouched.keys.filter { shaped[$0] != untouched[$0] }
        XCTAssertGreaterThan(changed.count, untouched.count / 2, "the speaking mouth moves")
    }
}

private final class ShapedCropStore: @unchecked Sendable {
    private let lock = NSLock()
    private var crops: [Int: Data] = [:]
    func add(_ frame: Int, _ crop: Data) { lock.withLock { crops[frame] = crop } }
    var all: [Int: Data] { lock.withLock { crops } }
}
