import Foundation
import CoreGraphics
import CoreML
import YoobRealistic
import YoobAnime

/// How a renderer draws a frame before all the audio its lip window reads has arrived.
enum LipDrawing: Sendable, Equatable {
    /// Frames drawn once 240 ms of audio past them is in, three at a time, the rest of the window as silence: the voice
    /// waits for the first frame (the Luna app's voice-socket calls).
    case standard
    /// Each frame drawn on its own as soon as the face's lead plus one frame of audio past it is in, the rest of the window
    /// stood in by the received audio mirrored: the voice plays a fixed short delay after it arrives (the Luna app's direct
    /// WebRTC calls).
    case instant
}

/// A rendered frame and the host frame it was composed on (nil when the engine has no host clip).
struct EngineFrame: @unchecked Sendable {
    let image: CGImage
    let host: Int?
}

/// One character renderer: 16 kHz mono speech in, 25 fps frames out. Frame n shows the audio from n × 640 samples.
protocol FaceEngine: Sendable {
    func append(_ samples: [Float]) async throws
    /// The frame, once rendered; nil while it is still being prepared. Older frames are dropped.
    func frame(_ index: Int) async throws -> EngineFrame?
    /// Starts a new utterance. `hostFrame` keeps the head where the previous one left it.
    func restart(hostFrame: Int) async
    /// Silence to append after the last speech so the renderer's lookahead releases the final frames.
    var tailSamples: Int { get }
    /// How far the lip model moves the mouth ahead of the audio it was given: each frame is shown this much later.
    var lipLeadMilliseconds: Int { get }
    /// How long the voice waits after it arrives with `LipDrawing.instant`, so the frame for what is heard is drawn by then.
    var instantVoiceDelayMilliseconds: Int { get }
    /// Draws the next utterance's frames this way (after `restart`).
    func setDrawing(_ drawing: LipDrawing) async
}

enum FaceEngines {
    static func load(_ manifest: CharacterManifest, root: URL) async throws -> FaceEngine {
        switch manifest.engine {
        case .realistic: try await RealisticEngine.load(manifest, root: root)
        case .anime: try await AnimeEngine.load(manifest, root: root)
        }
    }
}

/// Per-model lip timing, measured in the Luna app on the same renderers (SyncNet on the app's pipeline, 2026-09-24/25).
/// A character manifest may override it (`lipLeadMilliseconds`, `articulationGain`).
enum FaceTuning {
    /// The realistic Luna model (pack identity `h08-development`): lips 83 ms ahead of the audio, articulation gain 1.2
    /// (against her real footage: aperture correlation .691 to .700, closure F1 .884 to .888, SyncNet confidence up; past
    /// about 1.25 the model leaves what it learned).
    static let lunaIdentity = "h08-development"
    /// The anime model on the realistic runtime (F4 e124 + SR-lite x2 with the steady paste): lips 46 ms ahead.
    static let animeIdentity = "anime-f4-e124-test"

    static func leadMilliseconds(identity: String) -> Int {
        switch identity {
        case lunaIdentity: 83
        case animeIdentity: 46
        default: 0
        }
    }
    static func articulationGain(identity: String) -> Double { identity == lunaIdentity ? 1.2 : 1 }

    /// Frames of audio past a frame that `LipDrawing.instant` draws it with: the lead rounded to frames, plus one (Luna 3,
    /// the anime 2, a lead-free face 1).
    static func instantLookahead(lead: Int) -> Int { max(1, min(12, Int((Double(max(0, lead)) / 40).rounded()) + 1)) }

    /// The voice's delay with instant lips: the last chunk a frame's drawing needs arrives (2 × lookahead + 1) × 20 ms after
    /// its first, then the picture is drawn and composed (the Luna app budgets 30 ms on the Neural Engine plus 20 ms spare;
    /// the SDK's renderer runs on the GPU, so it budgets 20 ms more), less the lead the face is shown later anyway. Luna 127 ms.
    static func instantVoiceDelay(lookahead: Int, lead: Int) -> Int {
        max(0, (2 * lookahead + 1) * 20 - lead + 30 + 20 + 20)
    }
}

final class RealisticEngine: FaceEngine {
    private let avatar: StreamingAvatar
    private let segment = SegmentCounter()
    private let pace = RenderPace(limit: 40)
    let tailSamples = 16 * 640
    let lipLeadMilliseconds: Int
    let instantVoiceDelayMilliseconds: Int
    private let instantLookahead: Int

    private init(avatar: StreamingAvatar, lead: Int) {
        self.avatar = avatar
        lipLeadMilliseconds = lead
        instantLookahead = FaceTuning.instantLookahead(lead: lead)
        instantVoiceDelayMilliseconds = FaceTuning.instantVoiceDelay(lookahead: instantLookahead, lead: lead)
    }

    static func load(_ manifest: CharacterManifest, root: URL) async throws -> RealisticEngine {
        let pack: AvatarPack = try await Task.detached(priority: .userInitiated) {
            var pack = try AvatarPack(root: root)
            if let file = manifest.calmWindow {
                // The head path's lanes (the new anime: one closed-lip lane walked forward and back). The character manifest
                // lists and verifies this file; the lip pack's own receipts do not cover it.
                let data = try Data(contentsOf: AvatarPack.path(file, root: pack.root))
                guard let window = AvatarPack.CalmHostWindow(json: data), window.hasPath,
                      window.fits(hostCount: pack.manifest.frames.count) else { throw YoobError.invalidAssets(file) }
                pack.calmHosts = window
            } else if let calm = manifest.calmHosts {
                pack.calmHosts = .init(first: calm.first, count: calm.count, framesPerHost: calm.framesPerHost, wideLast: calm.wideLast)
            }
            // The model's crop finished for the face it was measured on (Luna: sharpened, and only her mouth region pasted
            // over the host's own pixels); nil composes exactly as before.
            pack.lipPicture = LipPicture.face(identity: pack.manifest.identity)
            _ = try? pack.hostFrames.picture(pack.hostIndex(for: 0), prefetch: [pack.hostIndex(for: 1), pack.hostIndex(for: 2)])
            // The GPU compositor's self-check, the lip picture's mattes and its GPU pass, before the first frame needs them.
            AvatarCompositor.warmUp()
            pack.prepareLipPicture()
            return pack
        }.value
        // GPU: ready in well under a second once compiled. The Neural Engine's first specialization takes minutes.
        var models = try await AvatarModels.load(pack: pack, units: .cpuAndGPU)
        try await models.warmUp()
        // Some GPUs (the iOS Simulator's among them) return an empty picture from this renderer. Check one frame and
        // fall back to the CPU rather than show a black square.
        if try await rendersBlank(models, pack: pack) {
            models = try await AvatarModels.load(pack: pack, cpuOnly: true)
            if try await rendersBlank(models, pack: pack) { throw YoobError.renderer("the renderer produced an empty frame") }
        }
        let identity = pack.manifest.identity
        let lead = manifest.lipLeadMilliseconds ?? FaceTuning.leadMilliseconds(identity: identity)
        let gain = manifest.articulationGain ?? FaceTuning.articulationGain(identity: identity)
        let avatar = StreamingAvatar(models: models, pack: pack)
        // The seal is judged on the audio heard when the frame shows (the lead, in frames), so the mouth still opens and
        // closes on the voice at a phrase's edges.
        await avatar.setSilenceGateShift(Int((Double(lead) / 40).rounded()))
        await avatar.setLipShaping(LipShaping(articulationGain: Float(gain)))
        let engine = RealisticEngine(avatar: avatar, lead: lead)
        await engine.setDrawing(.standard)
        return engine
    }

    private static func rendersBlank(_ models: AvatarModels, pack: AvatarPack) async throws -> Bool {
        let crop = try await models.renderCrop(frame: 0, audio: pack.closedAudio)
        return !crop.contains { $0 > 8 }
    }

    func setDrawing(_ drawing: LipDrawing) async {
        switch drawing {
        case .standard: await avatar.setEarlyDrawing(.init(lookaheadFrames: 6, batchFrames: 3, standIn: .silence))
        case .instant: await avatar.setEarlyDrawing(.init(lookaheadFrames: instantLookahead, batchFrames: 1, standIn: .mirror))
        }
    }

    func append(_ samples: [Float]) async throws {
        var offset = 0
        while offset < samples.count {
            // Audio can arrive much faster than real time; the renderer keeps at most `limit` frames ahead of the
            // frames being shown, so feed it a fifth of a second at a time and wait when it is far enough ahead.
            try await pace.waitForRoom()
            let slice = Array(samples[offset..<min(samples.count, offset + 3_200)])
            let rendered = try await avatar.append(samples: slice)
            await pace.rendered(through: rendered)
            offset += slice.count
        }
    }
    func frame(_ index: Int) async throws -> EngineFrame? {
        let current = await segment.value
        await pace.requested(index)
        await avatar.discard(before: max(0, index - 2), segment: current)
        guard let image = try await avatar.image(for: index, segment: current) else { return nil }
        return EngineFrame(image: try image.cgImage(), host: image.host)
    }
    func restart(hostFrame: Int) async {
        let next = await segment.next()
        await pace.reset()
        await avatar.restart(segment: next, frameOffset: hostFrame)
    }
}

final class AnimeEngine: FaceEngine {
    private let avatar: AnimeStreamingAvatar
    private let segment = SegmentCounter()
    /// One payload plus the geometry context and the encoder's right context.
    let tailSamples = (5 + 25) * 640 + 8_000
    /// The Luna app's value for this runtime: its lead is about 62 ms, but its gate keeps the mouth shut until about a frame
    /// before the voice, so a full delay would open it late at every phrase.
    let lipLeadMilliseconds = 30
    /// Not used: this runtime draws in geometry windows that need about 1.5 s of audio after each frame.
    let instantVoiceDelayMilliseconds = 0

    private init(avatar: AnimeStreamingAvatar) { self.avatar = avatar }

    @MainActor static func load(_ manifest: CharacterManifest, root: URL) async throws -> AnimeEngine {
        YoobResources.root = root
        let avatar = try await AnimeStreamingAvatar.load(calmIdle: true)
        return AnimeEngine(avatar: avatar)
    }

    func setDrawing(_ drawing: LipDrawing) async {}

    func append(_ samples: [Float]) async throws {
        var offset = 0
        while offset < samples.count {
            let slice = Array(samples[offset..<min(samples.count, offset + 32_000)])
            try await avatar.append(samples: slice)
            offset += slice.count
        }
    }
    func frame(_ index: Int) async throws -> EngineFrame? {
        try await avatar.image(for: index, segment: await segment.value).map { EngineFrame(image: $0, host: nil) }
    }
    func restart(hostFrame: Int) async {
        let next = await segment.next()
        await avatar.restart(segment: next, frameOffset: hostFrame)
    }
}

/// Holds the producer back while too many rendered frames wait to be shown.
actor RenderPace {
    private let limit: Int
    private var renderedThrough = -1
    private var requestedThrough = -1
    init(limit: Int) { self.limit = limit }
    func rendered(through frame: Int) { renderedThrough = max(renderedThrough, frame) }
    func requested(_ frame: Int) { requestedThrough = max(requestedThrough, frame) }
    func reset() { renderedThrough = -1; requestedThrough = -1 }
    func waitForRoom() async throws {
        while renderedThrough - requestedThrough >= limit {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

actor SegmentCounter {
    private(set) var value = 0
    func next() -> Int { value += 1; return value }
}
