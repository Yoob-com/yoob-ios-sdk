import XCTest
import CoreML
@testable import YoobRealistic

/// A call's own early drawing (`StreamingAvatar.setEarlyDrawing`): a direct WebRTC call draws Luna with 120 ms of future
/// audio, one frame at a time, mirrored, while the socket keeps the shipped static settings.
final class EarlyDrawingTests: XCTestCase {
    func testTheShippedDrawingIsTheStaticSettings() {
        XCTAssertEqual(StreamingAvatar.EarlyDrawing.shipped,
                       StreamingAvatar.EarlyDrawing(lookaheadFrames: StreamingAvatar.earlyLookaheadFrames, batchFrames: StreamingAvatar.earlyBatchFrames,
                                                    standIn: StreamingAvatar.standIn))
        XCTAssertEqual(StreamingAvatar.EarlyDrawing.shipped, StreamingAvatar.EarlyDrawing(lookaheadFrames: 6, batchFrames: 3, standIn: .silence))
        let clamped = StreamingAvatar.EarlyDrawing(lookaheadFrames: -2, batchFrames: 0, standIn: .mirror)
        XCTAssertEqual(clamped.lookaheadFrames, 0); XCTAssertEqual(clamped.batchFrames, 1)
    }

    func testTheMirroredStandInCarriesTheSoundOn() {
        XCTAssertEqual(StreamingAvatar.padded([1, 2, 3], count: 4, standIn: .mirror), [1, 2, 3, 3, 2, 1, 0])
        XCTAssertEqual(StreamingAvatar.padded([1, 2, 3], count: 2, standIn: .silence), [1, 2, 3, 0, 0])
    }

    /// With a pack (YOOB_REALISTIC_PACK, e.g. h08-v4): the call's own drawing gives exactly the crops the same values set
    /// as the static settings give, frame for frame, and a pipeline left at the shipped drawing is untouched by another's.
    func testACallsOwnDrawingMatchesTheSameStaticSettingsFrameForFrame() async throws {
        guard let path = ProcessInfo.processInfo.environment["YOOB_REALISTIC_PACK"] else { throw XCTSkip("no pack") }
        let pack = try AvatarPack(root: URL(fileURLWithPath: path))
        let models = try await AvatarModels.load(pack: pack, units: .cpuAndNeuralEngine, encoderUnits: .cpuOnly)
        // Three seconds of a voice-like signal: 180 Hz with its harmonics, in syllables, a pause in the middle.
        let pcm = Data((0..<72_000).flatMap { index -> [UInt8] in
            let t = Double(index) / 24_000, syllable = 0.5 + 0.5 * sin(2 * .pi * 4 * t)
            let voiced = (t > 1.2 && t < 1.6) ? 0 : syllable * (sin(2 * .pi * 180 * t) + 0.5 * sin(2 * .pi * 360 * t) + 0.25 * sin(2 * .pi * 720 * t))
            let value = Int16(max(-32_000, min(32_000, voiced * 9_000)))
            return [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
        })
        let instant = StreamingAvatar.EarlyDrawing(lookaheadFrames: 3, batchFrames: 1, standIn: .mirror)
        func crops(_ configure: (StreamingAvatar) async -> Void) async throws -> [Int: Data] {
            let pipeline = StreamingAvatar(models: models, pack: pack), store = CropStore()
            await configure(pipeline)
            await pipeline.observeCrops { frame, crop in store.add(frame, crop) }
            let converter = try AvatarResampler()
            for start in stride(from: 0, to: pcm.count, by: 960) {
                _ = try await pipeline.append(samples: converter.convert(pcm.subdata(in: start..<min(pcm.count, start + 960))))
            }
            _ = try await pipeline.flushTail(segment: 0)
            return store.all
        }
        let saved = StreamingAvatar.EarlyDrawing.shipped
        defer { StreamingAvatar.earlyLookaheadFrames = saved.lookaheadFrames; StreamingAvatar.earlyBatchFrames = saved.batchFrames; StreamingAvatar.standIn = saved.standIn }
        StreamingAvatar.earlyLookaheadFrames = 3; StreamingAvatar.earlyBatchFrames = 1; StreamingAvatar.standIn = .mirror
        let statics = try await crops { _ in }
        StreamingAvatar.earlyLookaheadFrames = saved.lookaheadFrames; StreamingAvatar.earlyBatchFrames = saved.batchFrames; StreamingAvatar.standIn = saved.standIn
        let own = try await crops { await $0.setEarlyDrawing(instant) }
        XCTAssertGreaterThan(statics.count, 60)
        XCTAssertEqual(own.count, statics.count)
        XCTAssertTrue(statics.allSatisfy { own[$0.key] == $0.value }, "every crop byte for byte")
        // The shipped drawing is another picture: what the socket draws stays its own.
        let shipped = try await crops { _ in }
        XCTAssertEqual(shipped.count, statics.count)
        XCTAssertFalse(shipped.allSatisfy { own[$0.key] == $0.value })
    }
}

private final class CropStore: @unchecked Sendable {
    private let lock = NSLock()
    private var crops: [Int: Data] = [:]
    func add(_ frame: Int, _ crop: Data) { lock.withLock { crops[frame] = crop } }
    var all: [Int: Data] { lock.withLock { crops } }
}
