import Foundation

/// One ordered producer awaits each append. Model calls are off the UI/audio threads.
public actor StreamingAvatar {
    /// Where the lip pipeline's time goes on this device (diagnostics only).
    public struct Stats: Sendable {
        public var encodeMS = 0.0, encodes = 0, renderMS = 0.0, renders = 0, samplesIn = 0
        /// Encodes of stand-in features (the missing right audio as silence) for frames drawn early or at a tail flush.
        public var standInEncodes = 0
        /// Time in the pack's steady filter (`SteadyFilter`), over the `renders` it filtered.
        public var filterMS = 0.0
        public init() {}
    }
    public private(set) var stats = Stats()
    public static func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
    private var models: AvatarModels
    private let pack: AvatarPack
    private var epoch = UUID()
    private var processing = false
    private var samples: [Float] = []
    private var sampleBase = 0
    private var rmsCursor = 0
    private var silenceStarts: [Int] = []
    /// Like `silenceStarts`, but below -30 dB: the Yoob SDK's speech walk (`HostWalker`) treats it as the end of speech.
    private var quietStarts: [Int] = []
    /// Yoob SDK: the speech walk of a pack without a head path but with a wide reach (`CalmHostWindow.wideLast`).
    private var wideWalker: HostWalker?
    private var nextFeature = 0
    private var nextFrame = 0
    private var features: [Int: [Float]] = [:]
    private var crops: [Int: Data] = [:]
    private var presentedFrame = -1
    /// Voice-first restarts: requests from an older segment get nothing, and `frameOffset` keeps the host
    /// video on the call's absolute frame so the head does not jump back to the start of its loop.
    private var segment = 0
    private var frameOffset = 0
    /// The realistic head path (`HostPath`), when the pack's calm window has lanes: the head plays it at the clip's own
    /// speed through speech and silence alike, in the calm lanes while the lips are sealed and the speech lanes while
    /// they are not. Built on the first frame of a segment, from the host the call screen shows after a restart.
    private var walker: HostPath?
    private var restartHost: Int?
    /// Host chosen for each rendered local frame, when the pack has a head path.
    private var hosts: [Int: Int] = [:]
    /// The silence weight each local frame was rendered with, on a closed-lip lane: how much of the face square is the
    /// host frame's own picture (`AvatarCompositor.compose(rawMix:)`). At 1 the model is not run at all: the frame is the
    /// real footage. Elsewhere it is 0: her lips are open there in the footage, so the mouth is always the model's.
    private var weights: [Int: Float] = [:]
    /// The silence seal each local frame was rendered with (0 open, 1 sealed), for diagnostics (`AvatarImage.sealWeight`).
    private var seals: [Int: Float] = [:]
    /// The seal the previous frame of this segment was rendered with, nil before its first: the seal closes at most
    /// `1 / sealFrames` a frame from there (`rampedSeal`).
    private var previousSeal: Float?
    /// The blink picture drawn on each rendered local frame that is mid-blink (`SpeechBlink`).
    private var blinks: [Int: Int] = [:]
    /// Local frame the blink under way began on.
    private var blinkStart: Int?
    /// Pictures of that blink drawn on a frozen frame during a stall (`frozenBlinkPicture`), which the real frames after
    /// the stall count on.
    private var blinkExtra = 0
    /// A scheduled blink that could not start on its frame, waiting for the first frame that allows it.
    private var blinkPending = false
    /// Local frame the last blink started on: no two blinks within `blinkSpacingFrames`.
    private var lastBlink: Int?
    /// Frames (2 s) between one blink's start and the next: the schedule's own double blinks are dropped.
    public static let blinkSpacingFrames = 50
    /// Rendered frames since the segment began or the last stall handed over to the idle face, so a blink never starts
    /// inside the crossfade to speech (`SpeechBlinkGate.holdFrames`).
    private var heldRun = 0
    /// The audio window the last frame was rendered with, and its closed-lips weight: a stall walk closes the lips from there.
    private var lastWindow: [Float] = []
    private var lastWeight: Float = 0
    /// Stall pictures rendered since frames stopped (`stallImage`); back to 0 once audio renders frames again.
    private var stallSteps = 0
    /// A stall walk handed over to the idle face on this host: the first `resumeHoldFrames` frames after the audio returns
    /// show it again, under the call screen's crossfade back to speech, so the fade blends two pictures of one pose (the
    /// stall is the one place the head holds; its frozen frame already did for 2 s).
    private var handoverHost: Int?
    private var resumeHold = 0
    public static let resumeHoldFrames = SpeechBlinkGate.holdFrames
    /// Local frame the head last passed through the clip's own blink (`closedEyes`): a scheduled speech blink within
    /// `sourceBlinkSpacingFrames` (2 s) after one is dropped, so a reply on the chin lift does not blink twice as often.
    private var lastSourceBlink: Int?
    public static let sourceBlinkSpacingFrames = 50
    /// Rendered crops kept before the oldest are dropped, for this pack's crop size (`bufferedCrops(cropBytes:)`).
    private let cropLimit: Int
    /// Diagnostics only (`AvatarModelProbe --dump-crops`): each frame's model crop as it is rendered (BGR, the output
    /// size square; not called for a frame whose face square is the host's own). Never set in the app.
    private var cropObserver: (@Sendable (Int, Data) -> Void)?
    public func observeCrops(_ observer: (@Sendable (Int, Data) -> Void)?) { cropObserver = observer }
    /// The pack's steady paste in time (`AvatarManifest.Paste.temporal`): each crop blended with the one before it, in render
    /// order. Nil for the realistic packs.
    private let steady: SteadyFilter?
    /// The lip model's audio windows (`LipWindows`, from the pack's manifest): H08's lookahead 9 or a low-lookahead model's.
    public nonisolated let windows: LipWindows
    /// How this call draws frames before their full window has arrived: the shipped values (`earlyLookaheadFrames`,
    /// `earlyBatchFrames`, `standIn`) unless the call sets its own (`setEarlyDrawing`: a direct WebRTC call's instant lips).
    public private(set) var early: EarlyDrawing
    public init(models: AvatarModels, pack: AvatarPack) {
        self.models = models; self.pack = pack; cropLimit = Self.bufferedCrops(cropBytes: pack.geometry.outputBytes)
        steady = pack.manifest.paste?.temporal.map { SteadyFilter(settings: $0, geometry: pack.geometry) }
        windows = pack.windows
        early = .shipped
    }
    /// Draws from the next append on with `early`; kept through `reset` and `restart` (it is the call's, not a segment's).
    public func setEarlyDrawing(_ early: EarlyDrawing) { self.early = early }
    /// The call's lip shaping (`LipShaping`, applied to each frame's window after the silence seal), or nil: the model's own
    /// window, byte for byte as before. Kept through `reset` and `restart` like the early drawing.
    public private(set) var shaping: LipShaping?
    public func setLipShaping(_ shaping: LipShaping?) { self.shaping = shaping.flatMap { $0.isIdentity ? nil : $0 } }
    /// Continues on other models of the same pack (GPU to Neural Engine). Every encode and render is a pure function of its
    /// audio window and host frame, so the switch lands between two model calls with no state to carry: a prediction
    /// already running finishes on the old models, the next one uses the new ones.
    public func upgrade(to newer: AvatarModels) { models = newer }

    public func reset() {
        epoch = UUID(); processing = false; samples = []; sampleBase = 0; rmsCursor = 0
        silenceStarts = []; quietStarts = []; nextFeature = 0; nextFrame = 0; features = [:]; crops = [:]; presentedFrame = -1
        wideWalker = nil; hosts = [:]; weights = [:]; seals = [:]; previousSeal = nil; walker = nil; restartHost = nil
        blinks = [:]; blinkStart = nil; blinkExtra = 0; blinkPending = false; lastBlink = nil; lastSourceBlink = nil; heldRun = 0
        lastWindow = []; lastWeight = 0; stallSteps = 0; handoverHost = nil; resumeHold = 0
        steady?.reset()
    }
    /// Starts a new segment whose frame 0 is absolute call frame `frameOffset`, as if the call began there.
    /// `startHost` is the host the call screen is showing: the head path carries on from there, in whichever lane it is,
    /// instead of snapping to the start.
    public func restart(segment: Int, frameOffset: Int, startHost: Int? = nil) {
        reset(); self.segment = segment; self.frameOffset = max(0, frameOffset); restartHost = startHost
    }
    /// The composed picture for `frame`. Only taking the frame's crop and state happens on this actor; the full-frame
    /// compose (~10-18 ms on the phone) runs off it (`Compose.run`), so it never holds up the encoder and renderer.
    public func image(for frame: Int, segment expected: Int) async throws -> AvatarImage? {
        guard expected == segment, let job = take(frame) else { return nil }
        return try await job.run()
    }
    /// Oldest frame still holding a rendered crop, or nil when the queue is empty (not yet produced, or dropped).
    /// A prepare pinned to a dropped index must jump here or lip-sync freezes while audio continues.
    public func oldestAvailableFrame(segment expected: Int) -> Int? {
        guard expected == segment else { return nil }
        return crops.keys.min()
    }
    /// One past the last frame the renderer has written. `wanted` at or above this is simply not produced yet —
    /// prepare must wait, not skip or fail (that killed lip-sync before the first mouth frame).
    public func producedThrough(segment expected: Int) -> Int {
        guard expected == segment else { return 0 }
        return nextFrame
    }
    public func discard(before frame: Int, segment expected: Int) {
        guard expected == segment else { return }
        discard(before: frame)
    }
    /// Rendered crops kept ahead of the compositor before the oldest are dropped (see `renderNext`): 150 of the 144 model's
    /// 288-square crops, ~37 MB.
    public static let maxBufferedCrops = 150
    /// The fewest kept for crops of any size: 5 s, the playout gate's 4 s admission window (100 frames) and 1 s of jitter.
    public static let minBufferedCrops = 125
    /// The cap for crops of `cropBytes` each: as many as fit in the 144 model's ~37 MB, at most `maxBufferedCrops` and at
    /// least `minBufferedCrops`. A byte cap alone would leave the 288 model's 576-square crops (~1 MB each) 37 frames, under
    /// the gate's admission window, and drop frames not yet shown; so they keep 125, ~124 MB at most, reached only when the
    /// compositor falls 5 s behind (in a call the gate admits audio at most 100 frames ahead of the voice).
    public static func bufferedCrops(cropBytes: Int) -> Int {
        max(minBufferedCrops, min(maxBufferedCrops, maxBufferedCrops * CropGeometry.h08.outputBytes / max(1, cropBytes)))
    }
    public func append(samples incoming: [Float]) async throws -> Int {
        stats.samplesIn += incoming.count
        guard !processing, incoming.count <= 32000, incoming.allSatisfy(\.isFinite),
              sampleBase + samples.count + incoming.count <= 1200 * 16000 + 16000,
              samples.count + incoming.count <= 64000 else { throw AvatarError.invalidAudio }
        processing = true; let ticket = epoch
        defer { if epoch == ticket { processing = false } }
        samples.append(contentsOf: incoming)
        let available = sampleBase + samples.count
        while (rmsCursor + 1) * 640 <= available {
            let start = rmsCursor * 640 - sampleBase
            var power = 0.0
            for value in samples[start..<(start + 640)] { power += Double(value) * Double(value) }
            let db = 20 * log10(sqrt(power / 640 + 1e-12) + 1e-9)
            let previous = silenceStarts.last ?? -1
            silenceStarts.append(db < -40 ? (previous >= 0 ? previous : rmsCursor) : -1)
            let quiet = quietStarts.last ?? -1
            quietStarts.append(db < -30 ? (quiet >= 0 ? quiet : rmsCursor) : -1)
            rmsCursor += 1
        }
        while true {
            // H08: features 0-7 from one encode of frames [0, 8), then each from [f - 16, f + 5) (`LipWindows`).
            let (low, high, first, last) = windows.encode(feature: nextFeature)
            guard available >= high * 640 + 80 else { break }
            let segment = LipWindows.window(samples, base: sampleBase, low: low, high: high)
            // The encoder (CPU) works on this audio while the renderer (Neural Engine) draws the next frame whose features
            // are already in: the two run at the same time instead of taking turns.
            let models = models, frames = high - low
            async let encoding = Self.timed { try await models.encode(segment, frameCount: frames) }
            if nextFrame + windows.lookahead < nextFeature { try await renderNext(ticket: ticket) }
            let (encoded, encodeMS) = try await encoding
            stats.encodeMS += encodeMS; stats.encodes += 1
            guard epoch == ticket, !Task.isCancelled else { throw CancellationError() }
            for frame in first..<last {
                let start = (frame - low) * 2048
                features[frame] = Array(encoded[start..<(start + 2048)])
            }
            nextFeature = last
            try await renderReady(ticket: ticket)
        }
        // Frames whose next `early.lookaheadFrames` of audio are in are drawn now, the rest of their window stood in.
        let drawable = available / 640 - 1 - early.lookaheadFrames
        if early.lookaheadFrames < windows.fullLookaheadFrames, drawable - nextFrame + 1 >= early.batchFrames, drawable < silenceStarts.count {
            try await renderWithStandIns(through: drawable, ticket: ticket)
        }
        let retainFrom = max(0, nextFeature - windows.left) * 640
        if retainFrom > sampleBase { samples.removeFirst(retainFrom - sampleBase); sampleBase = retainFrom }
        return nextFrame - 1
    }
    /// Renders every frame whose own audio has arrived, when no more audio is coming for now: the end of a reply (the
    /// Realtime model streams no silence after one) or a pause in delivery. A frame's window reads audio through ten
    /// frames after it, so without this the last 400 ms of every reply were never rendered: her voice waited for them,
    /// the player ran dry and the gate went voice-first, and the lips stayed still into the next reply. The
    /// missing audio to the right is silence for the encoder. The input cursor (`nextFeature`) does not move: real audio
    /// arriving later is encoded as usual and replaces every stand-in feature before a later frame reads it (frame m
    /// renders only once the features through m + 9 are encoded from real audio). Returns the last rendered frame.
    public func flushTail(segment expected: Int) async throws -> Int {
        guard expected == segment, !processing else { return nextFrame - 1 }
        let available = sampleBase + samples.count, lastFrame = available / 640 - 1
        guard lastFrame >= nextFrame, lastFrame < silenceStarts.count else { return nextFrame - 1 }
        processing = true; let ticket = epoch
        defer { if epoch == ticket { processing = false } }
        try await renderWithStandIns(through: lastFrame, ticket: ticket)
        return nextFrame - 1
    }
    /// Audio a frame is drawn with after its own 40 ms, in frames: 6 (240 ms) of the full window's 13 (525 ms, frame m reads
    /// features through m + 9, each from audio through its own + 5, plus 80 samples). A realtime voice model sends a reply at real time
    /// with no lead, so every reply's voice waited for 525 ms of audio past its first frame before the lips let it start.
    /// Drawn with 240 ms and the rest of the window as silence, a speech frame's mouth differs from the full-window one by
    /// 1.66 grey levels on average (p95 3.24) against the lips' own 4.52 median change from one frame to the next; 0.3%
    /// of speech frames exceed that change (lookahead study, 375 speech frames of five voices, 2026-09-23; 160 ms: 13%,
    /// visible on the teeth; 320 ms: none). So her voice starts ~285 ms sooner for each reply. Frames are drawn once: at
    /// 1x delivery the full window arrives 285 ms after the frame is shown, so a second, full-window pass would be late.
    /// Never under 4: the silence seal reads four frames of audio ahead.
    nonisolated(unsafe) public static var earlyLookaheadFrames = 6
    /// H08's full window (`LipWindows.fullLookaheadFrames` is each pack's): at or above a pack's own, frames are never drawn early.
    public static let fullLookaheadFrames = LipWindows.h08.fullLookaheadFrames
    /// Frames drawn early together at least: each early pass encodes the window's missing features once for all of them, so
    /// three at a time cost 74 ms of encoder per second of her voice against 115 ms one at a time and 33 ms with the full
    /// window (Mac stream benchmark, 20 s, 100 ms packets as a realtime voice sends them), and most frames see 280-320 ms.
    nonisolated(unsafe) public static var earlyBatchFrames = 3
    /// What stands in for the audio not received yet when a frame is drawn early or at a tail flush.
    public enum StandIn: Sendable {
        /// Silence, as the pipeline has always drawn.
        case silence
        /// The received audio mirrored about its last sample (silence past the retained audio): the sound carries on
        /// instead of stopping. A direct WebRTC call's instant lips (`setEarlyDrawing`); the socket keeps `silence`.
        case mirror
    }
    nonisolated(unsafe) public static var standIn = StandIn.silence
    /// A call's early drawing: frames drawn once `lookaheadFrames` of audio past their own 40 ms are in, at least
    /// `batchFrames` together, the rest of their window stood in by `standIn`.
    public struct EarlyDrawing: Sendable, Equatable {
        public var lookaheadFrames: Int
        public var batchFrames: Int
        public var standIn: StandIn
        public init(lookaheadFrames: Int, batchFrames: Int, standIn: StandIn) {
            self.lookaheadFrames = max(0, lookaheadFrames); self.batchFrames = max(1, batchFrames); self.standIn = standIn
        }
        /// The shipped values (the voice socket's), as the static settings hold them now.
        public static var shipped: EarlyDrawing {
            EarlyDrawing(lookaheadFrames: StreamingAvatar.earlyLookaheadFrames, batchFrames: StreamingAvatar.earlyBatchFrames,
                         standIn: StreamingAvatar.standIn)
        }
    }
    /// `samples` followed by `count` stand-in samples (`standIn`).
    static func padded(_ samples: [Float], count: Int, standIn: StandIn) -> [Float] {
        guard count > 0 else { return samples }
        switch standIn {
        case .silence: return samples + [Float](repeating: 0, count: count)
        case .mirror: return samples + (0..<count).map { samples.count - 1 - $0 >= 0 ? samples[samples.count - 1 - $0] : 0 }
        }
    }
    /// Renders frames through `lastFrame` with every feature not yet encoded from real audio (`nextFeature` onwards) stood
    /// in by one encoded with the missing audio to the right stood in (`early.standIn`). The input cursor (`nextFeature`) does not move:
    /// real audio arriving later is encoded as usual and replaces each stand-in before a later frame reads it.
    private func renderWithStandIns(through lastFrame: Int, ticket: UUID) async throws {
        let available = sampleBase + samples.count
        let through = lastFrame + windows.lookahead
        let padded = Self.padded(samples, count: max(0, (through + 1 + windows.right) * 640 + 80 - available), standIn: early.standIn)
        var feature = nextFeature
        while feature <= through {
            let (low, high, first, last) = windows.encode(feature: feature)
            let segment = LipWindows.window(padded, base: sampleBase, low: low, high: high)
            let (encoded, encodeMS) = try await Self.timed { [models] in try await models.encode(segment, frameCount: high - low) }
            stats.encodeMS += encodeMS; stats.encodes += 1; stats.standInEncodes += 1
            guard epoch == ticket, !Task.isCancelled else { throw CancellationError() }
            for frame in first..<last {
                let start = (frame - low) * 2048
                features[frame] = Array(encoded[start..<(start + 2048)])
            }
            feature = last
        }
        while nextFrame <= lastFrame { try await renderNext(ticket: ticket) }
    }
    private static func timed<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> (T, Double) {
        let start = ContinuousClock.now
        let value = try await work()
        return (value, ms(start.duration(to: .now)))
    }
    private func renderReady(ticket: UUID) async throws {
        while nextFrame + windows.lookahead < nextFeature { try await renderNext(ticket: ticket) }
    }
    /// Renders frame `nextFrame` (its feature window is complete).
    private func renderNext(ticket: UUID) async throws {
        // Live lip-sync stays up when the compositor falls behind: drop the oldest unshown frames instead of
        // ending the renderer (that showed as sealed lips for the rest of the call after ~30 s of talk).
        // The cap sits above the playout gate's admission limit (4 s of audio, 100 frames, of which the relay lead is
        // 1 s): at 60, a lag rejoin replaying up to 3 s of audio, or a normal reply with its 1 s lead plus network
        // jitter, dropped frames not yet shown and the mouth jumped ahead of the voice. The cap depends on the crop size
        // (`bufferedCrops(cropBytes:)`): 150 crops of 288 x 288 RGB are ~37 MB.
        if crops.count >= cropLimit {
            let keepFrom = nextFrame - cropLimit * 4 / 5
            crops = crops.filter { $0.key >= keepFrom }
            weights = weights.filter { $0.key >= keepFrom }
            seals = seals.filter { $0.key >= keepFrom }
            hosts = hosts.filter { $0.key >= keepFrom }
            blinks = blinks.filter { $0.key >= keepFrom }
        }
        // Features m - past ... m + lookahead (H08: m - 10 ... m + 9); none before the segment's first frame.
        var window = [Float](repeating: 0, count: 40 * 1024)
        let past = windows.past
        for relative in -past...windows.lookahead {
            if let feature = features[nextFrame + relative] {
                let begin = (relative + past) * 2048
                window.replaceSubrange(begin..<(begin + 2048), with: feature)
            }
        }
        let weight = Self.rampedSeal(gatedSilenceWeight(nextFrame), after: previousSeal)
        previousSeal = weight
        if weight > 0 { for i in window.indices { window[i] = (1 - weight) * window[i] + weight * pack.closedAudio[i] } }
        shaping?.apply(to: &window, closed: pack.closedAudio)
        let frame = nextFrame
        // The renderer's reference host must be the same absolute call frame the crop is composited into.
        var host: Int?, raw: Float = 0
        if let calm = pack.calmHosts, calm.hasPath {
            var walk = walker ?? HostPath(window: calm, startHost: restartHost ?? calm.pathStart, resuming: restartHost != nil)
            stallSteps = 0
            let next: Int
            if resumeHold > 0, let handover = handoverHost {
                // Back from the idle face: the handover pose again for the crossfade, then on along the path.
                next = handover; resumeHold -= 1
                if resumeHold == 0 { handoverHost = nil }
            } else {
                next = walk.next(speaking: weight < 1)
            }
            walker = walk; host = next; hosts[frame] = next
            raw = calm.isClosedLips(next) ? weight : 0
            heldRun += 1
            if let picture = blinkPicture(frame: frame, host: next, walker: walk) { blinks[frame] = picture }
        } else if let calm = pack.calmHosts, calm.wideLast != nil {
            var walk = wideWalker ?? HostWalker(window: calm, startHost: pack.hostIndex(for: frame + frameOffset))
            let next = walk.next(speechAhead: speechAhead(from: frame))
            wideWalker = walk; host = next; hosts[frame] = next
        }
        // In silence on a closed-lip lane the frame is the host clip's own picture, sealed lips and all: nothing to render.
        let renderStart = ContinuousClock.now
        var crop = raw >= 1 ? Data() : try await models.renderCrop(frame: frame + frameOffset, audio: window, host: host)
        if raw < 1 { stats.renderMS += Self.ms(renderStart.duration(to: .now)); stats.renders += 1 }
        guard epoch == ticket, !Task.isCancelled else { throw CancellationError() }
        if let steady {
            // The steady paste in time: after a frame the model did not draw, the next crop starts afresh.
            if crop.isEmpty { steady.reset() } else {
                let filterStart = ContinuousClock.now
                let index = host.map { min(max(0, $0), pack.manifest.frames.count - 1) } ?? pack.hostIndex(for: frame + frameOffset)
                crop = steady.filter(crop, box: pack.manifest.frames[index].bbox, silence: weight)
                stats.filterMS += Self.ms(filterStart.duration(to: .now))
            }
        }
        if !crop.isEmpty { cropObserver?(frame, crop) }
        crops[frame] = crop; weights[frame] = raw; seals[frame] = weight; nextFrame += 1
        lastWindow = window; lastWeight = weight
        features = features.filter { $0.key >= nextFrame - past }
    }
    public func image(for frame: Int) async throws -> AvatarImage? {
        guard let job = take(frame) else { return nil }
        return try await job.run()
    }
    /// Takes `frame` for presenting: everything the compose needs, and the older frames dropped.
    private func take(_ frame: Int) -> Compose? {
        guard frame >= 0, frame >= presentedFrame, let crop = crops[frame] else { return nil }
        let host = hosts[frame]
        let ahead = host == nil ? nil : (1...AvatarCompositor.prefetchFrames).compactMap { hosts[frame + $0] }
        // A rendered frame is shown whenever there is one: the still idle face is only for before the first and after a
        // stall walk handed over.
        let job = Compose(pack: pack, frame: frame + frameOffset, crop: crop, host: host, prefetch: ahead.flatMap { $0.isEmpty ? nil : $0 },
                          blink: blinks[frame], raw: weights[frame] ?? 0, holdsSpeech: host != nil, seal: seals[frame] ?? 0)
        presentedFrame = frame
        crops = crops.filter { $0.key >= frame }
        hosts = hosts.filter { $0.key >= frame }
        weights = weights.filter { $0.key >= frame }
        seals = seals.filter { $0.key >= frame }
        blinks = blinks.filter { $0.key >= frame }
        return job
    }
    /// One full-frame compose, run off the actor.
    struct Compose: Sendable {
        let pack: AvatarPack, frame: Int, crop: Data, host: Int?, prefetch: [Int]?, blink: Int?, raw: Float, holdsSpeech: Bool
        var seal: Float = 0
        func run() async throws -> AvatarImage {
            var result = try AvatarCompositor.compose(pack: pack, frame: frame, cropBGR: crop, host: host, prefetchHosts: prefetch,
                                                      blink: blink, rawMix: raw)
            result.host = host; result.holdsSpeech = holdsSpeech; result.blink = blink; result.rawMix = raw; result.sealWeight = seal
            return result
        }
    }
    public func discard(before frame: Int) { crops = crops.filter { $0.key >= frame } }
    /// The blink picture for `frame`: the next step of a blink under way, or the first when the idle face's schedule (on
    /// the call's frame clock) has started one and `SpeechBlinkGate` allows it: frames shown long enough for the crossfade
    /// to speech to have ended, the head on a blinkable pose for every frame of the blink (the path is known ahead), and
    /// `blinkSpacingFrames` since the last blink. A blink that may not start on its frame waits for the first frame that
    /// allows it; the next scheduled blink replaces one still waiting. It starts whole or not at all.
    private func blinkPicture(frame: Int, host: Int, walker: HostPath) -> Int? {
        guard let blink = pack.blink, let calm = pack.calmHosts else { return nil }
        if let start = blinkStart {
            // A blink under way, counting the pictures already drawn on a frozen frame (`frozenBlinkPicture`).
            let step = frame - start + blinkExtra
            if step < blink.sequence.count { return blink.sequence[step] }
            blinkStart = nil; blinkExtra = 0
        }
        let step = blink.schedule.stepSeconds
        if blink.schedule.blinkStarts(at: Double(frame + frameOffset) * step, step: step),
           lastSourceBlink.map({ frame - $0 >= Self.sourceBlinkSpacingFrames }) ?? true { blinkPending = true }
        if calm.closedEyes?.contains(host) == true { blinkPending = false; lastSourceBlink = frame }
        guard blinkPending else { return nil }
        if let last = lastBlink, frame - last < Self.blinkSpacingFrames { blinkPending = false; return nil }
        // The head over the blink, walked ahead on the audio already received (the lips' seal is known that far).
        let flags = (1..<blink.sequence.count).map { gatedSilenceWeight(frame + $0) < 1 }
        let through = [host] + walker.ahead(blink.sequence.count - 1, speaking: flags)
        guard SpeechBlinkGate.allows(heldFrames: heldRun, hostsThroughBlink: through, window: calm, blinkFrames: blink.sequence.count) else { return nil }
        blinkPending = false; blinkStart = frame; lastBlink = frame
        return blink.sequence[0]
    }
    /// The next picture of a blink under way for a picture drawn on the frozen frame `frame` (a stall): the blink goes on
    /// where it stopped instead of snapping the eyes open, and the real frames after the stall carry on from there
    /// (`blinkExtra`). Nil once the blink is over, or off a blinkable pose.
    private func frozenBlinkPicture(frame: Int, host: Int) -> Int? {
        guard let blink = pack.blink, let calm = pack.calmHosts, let start = blinkStart else { return nil }
        let step = frame - start + blinkExtra + 1
        guard step < blink.sequence.count, calm.isBlinkable(host) else { blinkStart = nil; blinkExtra = 0; return nil }
        blinkExtra += 1
        return blink.sequence[step]
    }
    /// A picture that opens eyes frozen closed: frames stopped on `frame` with its eyes shut, and the call screen waited
    /// `HostPath.openEyesDelayFrames` for the next one. A speech blink frozen mid-way is finished on the same frame (its
    /// crop, host and lips) with the blink's next eyes, and the real frames after the stall carry on from the eyes that
    /// were shown. A frame stopped inside the clip's own blink (`closedEyes`, on the chin lift) has the head walk on out
    /// of it one host per picture, with the frozen frame's own lips, and the stall walk later carries on from there. Either
    /// way the picture then holds as any other freeze until the speech hold runs out. Nil when the eyes are open, or a
    /// newer frame is rendered already (the audio is back).
    public func openEyesImage(after frame: Int, segment expected: Int) async throws -> AvatarImage? {
        guard expected == segment, !processing, frame == presentedFrame, nextFrame == frame + 1, let calm = pack.calmHosts else { return nil }
        if blinkStart != nil, let crop = crops[frame], let host = hosts[frame], let picture = frozenBlinkPicture(frame: frame, host: host) {
            return try await Compose(pack: pack, frame: frame + frameOffset, crop: crop, host: host, prefetch: [host],
                                     blink: picture, raw: weights[frame] ?? 0, holdsSpeech: true).run()
        }
        guard var walk = walker, let blink = calm.closedEyes, blink.contains(walk.host), !lastWindow.isEmpty else { return nil }
        let ticket = epoch
        // A picture outside the rendered sequence: the steady filter's next crop starts afresh.
        steady?.reset()
        // On along the lane the way the head was going: out of the blink within three hosts.
        let host = walk.next(speaking: walk.speaking)
        walker = walk
        let prefetch = walk.ahead(2, speaking: [walk.speaking, walk.speaking])
        let crop = try await models.renderCrop(frame: frame + frameOffset, audio: lastWindow, host: host)
        guard epoch == ticket, !Task.isCancelled else { throw CancellationError() }
        return try await Compose(pack: pack, frame: frame + frameOffset, crop: crop, host: host, prefetch: prefetch,
                                 blink: nil, raw: 0, holdsSpeech: true).run()
    }
    /// The next picture of a stall walk: no audio has arrived for longer than the call screen's speech hold, and `frame`
    /// (the last one rendered and presented) is still on screen. The head goes on along its path as in silence, one host
    /// per picture (out of a speech lane at its next exit), while the lips close from the frozen frame's mouth, and the
    /// picture keeps speech showing until the head is on a twin of the idle face with the lips closed; the still idle face
    /// then takes over on a pose it matches. When the audio returns, frame + 1 carries on from where the path got to,
    /// with the lips of the real audio. Nil when the stall cannot go on (the audio came back, another segment, no head path).
    public func stallImage(after frame: Int, segment expected: Int) async throws -> AvatarImage? {
        guard expected == segment, !processing, frame == presentedFrame, nextFrame == frame + 1, var walk = walker,
              let calm = pack.calmHosts, !lastWindow.isEmpty, stallSteps < HostPath.stallFramesLimit else { return nil }
        let ticket = epoch
        // The stall walk's pictures are outside the rendered sequence: the steady filter's next crop starts afresh.
        steady?.reset()
        let host = walk.next(speaking: false, settling: true), closed = HostPath.stallLipsClosed(step: stallSteps, frozen: lastWeight)
        let holding = HostPath.holdsStalledSpeech(host: host, lipsClosed: closed, window: calm)
        // The renderer's own blend: (1 - w) * audio + w * closed lips, continued from the frozen frame's w.
        let toward = lastWeight < 1 ? (closed - lastWeight) / (1 - lastWeight) : 1
        var window = lastWindow
        if toward > 0 { for i in window.indices { window[i] = (1 - toward) * window[i] + toward * pack.closedAudio[i] } }
        walker = walk; stallSteps += 1
        // Handed over to the idle face: the frames after the stall show this pose again under the fade back to speech and
        // start a new held run, so a blink waits for that fade to end (`SpeechBlinkGate.holdFrames`) even when the audio
        // comes back mid-word.
        if !holding { heldRun = 0; handoverHost = host; resumeHold = Self.resumeHoldFrames }
        var ahead = walk; let prefetch = [ahead.next(speaking: false, settling: true), ahead.next(speaking: false, settling: true)]
        // On a closed-lip lane with the lips closed the picture is the host clip's own: nothing to render.
        let raw: Float = calm.isClosedLips(host) ? closed : 0
        let renderStart = ContinuousClock.now
        let crop = raw >= 1 ? Data() : try await models.renderCrop(frame: frame + frameOffset, audio: window, host: host)
        if raw < 1 { stats.renderMS += Self.ms(renderStart.duration(to: .now)); stats.renders += 1 }
        guard epoch == ticket, !Task.isCancelled else { throw CancellationError() }
        // A blink frozen mid-way goes on with the walk, never snapping open.
        let blink = frozenBlinkPicture(frame: frame, host: host)
        return try await Compose(pack: pack, frame: frame + frameOffset, crop: crop, host: host, prefetch: prefetch,
                                 blink: blink, raw: raw, holdsSpeech: holding).run()
    }
    /// Frames over which the lips close into silence, and frames before the voice returns over which they are released:
    /// the release was 4 frames, and with rendered frames on screen through the silence the mouth was seen opening 3
    /// frames (0.12 s) before the sound (onset lag -3.2 frames against the real footage); 2 frames keeps it within a
    /// frame of the sound and still leaves no pop. (That early opening was the lip model's learned lead, now shown later
    /// as a whole: `LipTiming`, `silenceGateShiftFrames`.)
    public static let sealFrames = 4, releaseFrames = 2
    /// Whether the seal closes over `sealFrames` from the frame before (`rampedSeal`). Off: the seal as decided, as before
    /// 2026-09-25 (the probe's `PROBE_SEAL_SNAP=1`, for comparisons); the app never sets it.
    nonisolated(unsafe) public static var rampsSeal = true
    /// The seal a frame is drawn with: `target` (`gatedSilenceWeight`), but closing at most `1 / sealFrames` past the frame
    /// before (`previous`, nil for a segment's first frame). With instant lips the seal is decided only once five silent frames
    /// are in, and with the lip lead's shift (`silenceGateShiftFrames`) that is already the ramp's last frame: Luna (3 frames
    /// ahead, shift 2) and the lead-free faces (1 ahead, shift 0) went from 0 to 1 in one frame, the open speaking mouth
    /// snapping shut at each phrase end. Opening is never held
    /// back: the release keeps the lips on her voice.
    public static func rampedSeal(_ target: Float, after previous: Float?) -> Float {
        guard rampsSeal, let previous, target > previous else { return target }
        return min(target, previous + 1 / Float(sealFrames))
    }
    /// How many frames after a frame's own audio its silence seal is judged. The face shows every frame the lip model's
    /// lead later (`LipTiming`: 2 frames for Luna and the pup, whose training footage moves the mouth ~90 ms ahead of its
    /// audio), and the seal must stay on the voice the listener hears: judged on the frame's own audio, phrase starts would
    /// open and ends close 40-80 ms late (sync audit, 2026-09-24). Past the audio received so far the last known frame
    /// stands in. 0 renders exactly as before (the Mac probes and tests).
    nonisolated(unsafe) public static var silenceGateShiftFrames = 0
    /// Yoob SDK: this avatar's own shift (`setSilenceGateShift`), so two faces with different lip leads can run at once.
    private var gateShift: Int?
    /// Judges this avatar's silence seal `frames` after each frame's own audio (nil: `silenceGateShiftFrames`).
    public func setSilenceGateShift(_ frames: Int?) { gateShift = frames.map { max(0, min(4, $0)) } }
    /// Frames of speech known to follow `frame` before a quiet stretch of at least five frames (0 inside one).
    private func speechAhead(from frame: Int) -> Int {
        guard frame < quietStarts.count else { return 0 }
        var x = frame
        while x < quietStarts.count, x < frame + 120 {
            let start = quietStarts[x]
            if start >= 0, x - start >= 4 { return max(0, start - frame) }
            x += 1
        }
        return x - frame
    }
    private func gatedSilenceWeight(_ frame: Int) -> Float {
        let shift = gateShift ?? Self.silenceGateShiftFrames
        guard shift > 0, !silenceStarts.isEmpty else { return silenceWeight(frame) }
        return silenceWeight(min(frame + shift, silenceStarts.count - 1))
    }
    private func silenceWeight(_ frame: Int) -> Float {
        guard frame >= 0, frame < silenceStarts.count, silenceStarts[frame] >= 0 else { return 0 }
        let start = silenceStarts[frame]
        // With H08's full window at least nine future frames are known when a frame renders, so the five-frame minimum, the
        // four-frame seal and the two-frame release are decided without unseen audio. With fewer known (a frame drawn early,
        // or a low-lookahead pack's two), a silence is sealed only once five of its frames are in: its first frames keep the
        // model's own mouth, which that model draws closing on silence; the release still sees its two frames ahead.
        guard start + 4 < silenceStarts.count, silenceStarts[start + 4] == start else { return 0 }
        var weight: Float = start == 0 ? 1 : min(1, Float(frame - start + 1) / Float(Self.sealFrames))
        for distance in 1...Self.releaseFrames where frame + distance < silenceStarts.count {
            if silenceStarts[frame + distance] < 0 { weight = min(weight, Float(distance) / Float(Self.releaseFrames)); break }
        }
        return weight
    }
}
