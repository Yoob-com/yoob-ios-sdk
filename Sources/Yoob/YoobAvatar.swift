import Foundation
import CoreGraphics
import ImageIO
import Observation
import os
import YoobRealistic

/// A character that speaks the audio you give it. Create one per character, call `prepare()`, show it with
/// `YoobAvatarView`, then pass speech to `speak(pcm:sampleRate:)`.
///
/// The avatar plays the audio itself so the lips stay in sync. If your app already plays the audio, use
/// `appendAudio(pcm:sampleRate:)` and report playback with `audioPlayed(samples:)` instead.
@MainActor @Observable
public final class YoobAvatar {
    public enum Phase: Equatable, Sendable {
        /// `prepare()` has not been called.
        case notPrepared
        /// Character files are downloading. The poster and idle frames appear before the models finish.
        case downloading(YoobProgress)
        /// Files are ready; the renderer is warming up (well under a second once compiled).
        case warming
        /// Ready to speak. Idle frames play.
        case ready
        /// Speech is playing and the face follows it.
        case speaking
        /// Preparing failed. `prepare()` can be called again.
        case failed(YoobError)
        /// The session ended and the character stopped rendering: `.outOfCredit`, `.unauthorized`, or `.sessionEnded`
        /// (`.sessionEnded("unreachable")` when Yoob couldn't be reached for `heartbeatOutageGraceSeconds`).
        /// `prepare()` starts a new session.
        case stopped(YoobError)
    }

    public private(set) var phase: Phase = .notPrepared
    /// The character's still image, available early in the download.
    public private(set) var poster: CGImage?
    /// Closed-mouth frames played forward and back while the character is silent.
    public private(set) var idleFrames: [CGImage] = []
    public private(set) var idleFramesPerSecond: Double = 8
    /// The current speaking frame. Shown instead of the idle frames while `isShowingSpeech` is true.
    public private(set) var speechFrame: CGImage?
    public private(set) var isShowingSpeech = false
    /// Peak level (0...1) of the speech being heard now; 0 in silence. Drives `YoobAvatarView`'s speaking motion.
    public private(set) var voiceLevel: Double = 0
    /// Width over height of every frame this character draws.
    public private(set) var aspectRatio: CGFloat = 9.0 / 16.0
    public private(set) var manifest: CharacterManifest?
    /// The character id this avatar was created for (nil for a local pack until it is opened).
    public var character: String? {
        if case .cloud(let character, _) = source { return character }
        return manifest?.character
    }
    /// Called when the session ends and the character stops rendering, with the same error `phase` holds in
    /// `.stopped`: `.outOfCredit`, `.unauthorized`, or `.sessionEnded`.
    @ObservationIgnored public var onSessionEnded: (@MainActor (YoobError) -> Void)?
    /// How long the character keeps rendering while heartbeats get no answer (network errors, timeouts, 408, 429, 5xx),
    /// counted from the last successful heartbeat. 0 stops at the first failure; values are clamped to 0...1800.
    /// Default 600 (10 minutes). Refusals (401, 402, 403) stop the character at once regardless. Applies from the next
    /// `prepare()`.
    @ObservationIgnored public var heartbeatOutageGraceSeconds: Int {
        didSet { heartbeatOutageGraceSeconds = SessionHeartbeat.clampOutageGrace(heartbeatOutageGraceSeconds) }
    }
    /// True while heartbeats are failing without an answer and being retried. The character keeps rendering.
    public private(set) var isHeartbeatDegraded = false
    /// Heartbeats started failing without an answer, with a short description of the failure. Not fatal.
    @ObservationIgnored public var onHeartbeatDegraded: (@MainActor (String) -> Void)?
    /// A heartbeat succeeded again after `onHeartbeatDegraded`.
    @ObservationIgnored public var onHeartbeatRecovered: (@MainActor () -> Void)?
    /// Sync diagnostics: frames shown and frames skipped because rendering fell behind the audio.
    public private(set) var stats = Stats()
    /// Why the renderer stopped during the last utterance, if it did. The audio kept playing.
    public private(set) var lastRendererError: String?
    public struct Stats: Equatable, Sendable {
        public var framesShown = 0
        public var framesSkipped = 0
        public var utterances = 0
    }

    /// Longest the voice is held back at the start of an utterance while the first frame renders.
    public var maxSyncDelay: Duration = .milliseconds(1800)

    /// How the lips are drawn against the voice.
    public enum LipSync: Sendable, Equatable {
        /// `standard` for `speak(pcm:sampleRate:)`, `instant` for `appendAudio(pcm:sampleRate:)`, where your player starts
        /// the voice as soon as it arrives.
        case automatic
        /// Each frame is drawn with 240 ms of the audio after it, and the voice waits for the first frame (up to
        /// `maxSyncDelay`). The best lips for speech that arrives in bursts faster than real time.
        case standard
        /// Low latency, for speech that arrives in real time (WebRTC, LiveKit). Each frame is drawn on its own as soon as a
        /// little of the audio after it has arrived (120 ms for the realistic Luna). With `speak(pcm:sampleRate:)` the
        /// voice plays a fixed short delay after it arrives (`instantVoiceDelay`) and never waits for a frame.
        /// Realistic characters only; the classic anime character draws as `standard`.
        case instant
    }
    /// Applies from the next utterance.
    public var lipSync: LipSync = .automatic
    /// With `LipSync.instant` and `speak(pcm:sampleRate:)`: how long the voice waits after it arrives. Nil: the character's
    /// own delay (127 ms for the realistic Luna). Applies from the next utterance.
    public var instantVoiceDelay: Duration?

    /// How the 25 lip frames a second are presented on the display.
    public enum LipCadence: Sendable, Equatable {
        /// Each frame is shown whole when its audio is heard.
        case steps
        /// Each new frame fades in over the one before across one frame's time (40 ms), centred on the moment its audio is
        /// heard, so the mouth moves at every display refresh and meets the voice exactly as the steps do. A jump in the
        /// head's footage fades over 120 ms. Needs `CADisableMinimumFrameDurationOnPhone` in your Info.plist for 120 Hz
        /// on ProMotion iPhones (60 Hz otherwise).
        case blend
    }
    public var lipCadence: LipCadence = .blend

    private let source: YoobSource
    private let version: String?
    private var credentials: YoobCredentials?
    private var engine: FaceEngine?
    private var packDirectory: URL?
    private var preparing: Task<Void, Error>?
    private let player = SpeechPlayer()
    /// The user's microphone: input choice, mute and level, captured with echo cancellation.
    @ObservationIgnored public private(set) lazy var microphone = YoobMicrophone(player: player)
    private var utterance: Utterance?
    private var heartbeat: SessionHeartbeat?
    private var access: CDNAccess?
    /// Call frame the head reached; the next utterance continues from there.
    private var hostFrame = 0
    private var externalClock = false

    private final class Utterance {
        let id: Int
        let sampleRate: Double
        let resampler: AvatarResampler
        let feed: AsyncStream<[Float]>.Continuation
        let consumer: Task<Void, Never>
        var held: [Data] = []
        var heldSince: ContinuousClock.Instant?
        var started = false
        var ended = false
        var engineFailed = false
        var receivedSamples: Int64 = 0
        /// Peak of every 40 ms of received speech, by video frame.
        var levels: [Float] = []
        var levelPeak: Float = 0, levelFill = 0
        var externalPlayed: Int64 = 0
        var prepared: [Int: EngineFrame] = [:]
        var nextToPrepare = 0
        var preparing = false
        var shown = -1
        var shownHost: Int?
        /// Samples the face shows its frames later than the audio heard: the lip model's lead, plus the output path's
        /// latency when the avatar plays the voice itself.
        var displayDelaySamples: Int64 = 0
        /// The voice starts this long after the first audio arrives instead of waiting for the first frame.
        var instantDelay: Duration?
        init(id: Int, sampleRate: Double, resampler: AvatarResampler, feed: AsyncStream<[Float]>.Continuation, consumer: Task<Void, Never>) {
            self.id = id; self.sampleRate = sampleRate; self.resampler = resampler; self.feed = feed; self.consumer = consumer
        }
    }
    private var utteranceCount = 0
    private var ticker: Task<Void, Never>?

    public init(_ source: YoobSource, version: String? = nil,
                heartbeatOutageGraceSeconds: Int = 600) {
        self.source = source
        self.version = version
        self.heartbeatOutageGraceSeconds = SessionHeartbeat.clampOutageGrace(heartbeatOutageGraceSeconds)
        player.onDrained = { [weak self] in Task { @MainActor in self?.playbackDrained() } }
    }

    // MARK: - Preparing

    /// Downloads (or opens) the character and warms up the renderer. Safe to call again after a failure; a finished
    /// download is reused.
    public func prepare() async throws {
        if let preparing { return try await preparing.value }
        if case .ready = phase { return }
        if case .speaking = phase { return }
        let task = Task { try await self.load() }
        preparing = task
        defer { preparing = nil }
        do { try await task.value }
        catch {
            let failure: YoobError
            if let known = error as? YoobError { failure = known }
            else if error is CocoaError || error is URLError { failure = .network(error.localizedDescription) }
            else { failure = .renderer(error.localizedDescription) }
            if case .stopped(let reason) = phase { throw reason } // already reported
            // Don't leave a metered session running behind a failed start.
            await endSession()
            if !(error is CancellationError) { phase = .failed(failure) }
            throw failure
        }
    }

    private func load() async throws {
        await endSession()
        let manifest: CharacterManifest
        let root: URL
        let fetchCredentials: @Sendable () async throws -> YoobCredentials
        switch source {
        case .local(_, let credentials), .cloud(_, let credentials): fetchCredentials = credentials
        }
        // Every start opens a metered session first, and heartbeats run from here on, during the download too.
        phase = .downloading(YoobProgress(completedBytes: 0, totalBytes: 0))
        let credentials = try await fetchCredentials()
        self.credentials = credentials
        let access = CDNAccess(credentials)
        self.access = access
        startHeartbeat()
        switch source {
        case .local(let directory, _):
            manifest = try await LocalPack.open(directory)
            root = directory
            try checkRunning()
            show(manifest: manifest, root: root)
        case .cloud(let character, _):
            let store = AssetStore.shared
            do {
                manifest = try await store.manifest(character: character, version: version, credentials: credentials)
            } catch let error as YoobError {
                // Offline with a complete pack on disk: start from it. The session above is still required.
                guard case .network = error, version == nil, let cached = await store.cachedManifest(character: character) else { throw error }
                manifest = cached
            }
            try checkRunning()
            let progress: @Sendable (YoobProgress) -> Void = { [weak self] value in
                Task { @MainActor in
                    guard let self, case .downloading = self.phase else { return }
                    self.phase = .downloading(value)
                }
            }
            // The poster and idle frames first, so the character is on screen while the models download.
            let early = try await store.download(manifest, throughTier: 1, access: access, progress: { _ in })
            try checkRunning()
            show(manifest: manifest, root: early)
            root = try await store.download(manifest, throughTier: 3, access: access, progress: progress)
        }
        try checkRunning()
        packDirectory = root
        phase = .warming
        let engine = try await FaceEngines.load(manifest, root: root)
        try checkRunning()
        self.engine = engine
        phase = .ready
    }

    /// Throws when the session ended while starting.
    private func checkRunning() throws {
        if case .stopped(let reason) = phase { throw reason }
        guard heartbeat?.isRunning == true else { throw YoobError.sessionEnded("the session stopped while starting") }
    }

    private func show(manifest: CharacterManifest, root: URL) {
        self.manifest = manifest
        aspectRatio = CGFloat(manifest.width) / CGFloat(manifest.height)
        idleFramesPerSecond = manifest.idle.fps
        poster = Self.decode(root.appendingPathComponent(manifest.poster))
        let urls = manifest.idle.frames.map { root.appendingPathComponent($0) }
        Task {
            let frames = await Task.detached(priority: .userInitiated) { urls.compactMap(Self.decode) }.value
            self.idleFrames = frames
        }
    }

    nonisolated private static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    // MARK: - Speaking

    /// Plays mono 16-bit little-endian PCM and moves the face with it. Call repeatedly as audio streams in; call
    /// `endSpeech()` after the last chunk. Audio plays even if the character is not ready yet.
    public func speak(pcm: Data, sampleRate: Int = 24000) throws {
        externalClock = false
        try ingest(pcm, sampleRate: sampleRate)
    }

    /// For apps that play the audio themselves: renders frames for this audio without playing it. Report playback
    /// progress with `audioPlayed(samples:)`.
    public func appendAudio(pcm: Data, sampleRate: Int = 24000) throws {
        externalClock = true
        try ingest(pcm, sampleRate: sampleRate)
    }

    /// With `appendAudio`: how many samples of the current utterance the listener has heard.
    public func audioPlayed(samples: Int) {
        guard let utterance else { return }
        utterance.externalPlayed = max(utterance.externalPlayed, Int64(samples))
        if utterance.ended, utterance.externalPlayed >= utterance.receivedSamples { finishUtterance() }
    }

    /// Marks the end of the current utterance. The face returns to idle when the audio finishes.
    public func endSpeech() {
        guard let utterance, !utterance.ended else { return }
        utterance.ended = true
        if let engine { utterance.feed.yield([Float](repeating: 0, count: engine.tailSamples)) }
        utterance.feed.finish()
        releaseHeldAudio(force: true)
        if externalClock, utterance.externalPlayed >= utterance.receivedSamples { finishUtterance() }
    }

    /// Stops speaking at once (barge-in). Returns how many samples of the utterance were heard, which is what a
    /// realtime model needs to truncate its reply.
    @discardableResult
    public func interrupt() -> Int {
        guard let utterance else { return 0 }
        let heard = externalClock ? utterance.externalPlayed : player.playedSamples
        player.stop()
        finishUtterance()
        return Int(heard)
    }

    private func ingest(_ pcm: Data, sampleRate: Int) throws {
        guard pcm.count % 2 == 0 else { throw YoobError.invalidAudio("PCM16 data must have an even byte count") }
        if case .stopped(let reason) = phase { throw reason }
        guard !pcm.isEmpty else { return }
        let current = try utterance ?? beginUtterance(sampleRate: Double(sampleRate))
        guard current.sampleRate == Double(sampleRate) else {
            throw YoobError.invalidAudio("sample rate changed mid-utterance; call endSpeech() first")
        }
        if current.ended { finishUtterance(); return try ingest(pcm, sampleRate: sampleRate) }
        current.receivedSamples += Int64(pcm.count / 2)
        let perFrame = max(1, sampleRate / 25)
        pcm.withUnsafeBytes { raw in
            for i in 0..<(pcm.count / 2) {
                let value = abs(Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768)
                current.levelPeak = max(current.levelPeak, value); current.levelFill += 1
                if current.levelFill == perFrame { current.levels.append(current.levelPeak); current.levelPeak = 0; current.levelFill = 0 }
            }
        }
        if engine != nil, !current.engineFailed {
            let bytesPerSecond = sampleRate * 2
            var offset = 0
            while offset < pcm.count {
                let slice = pcm.subdata(in: offset..<min(pcm.count, offset + bytesPerSecond))
                if let samples = try? current.resampler.convert(slice) { current.feed.yield(samples) }
                offset += slice.count
            }
        }
        guard !externalClock else { return }
        if current.started {
            player.schedule(pcm)
        } else {
            current.held.append(pcm)
            if current.heldSince == nil { current.heldSince = .now }
            releaseHeldAudio(force: engine == nil || current.engineFailed)
        }
    }

    private func beginUtterance(sampleRate: Double) throws -> Utterance {
        let resampler: AvatarResampler
        do { resampler = try AvatarResampler(sourceRate: sampleRate) }
        catch { throw YoobError.invalidAudio("unsupported sample rate \(Int(sampleRate)) Hz") }
        if !externalClock { try player.begin(sampleRate: sampleRate) }
        utteranceCount += 1
        let id = utteranceCount
        let (stream, feed) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
        let engine = engine
        let startFrame = hostFrame
        let instant: Bool
        switch lipSync {
        case .automatic: instant = externalClock
        case .standard: instant = false
        case .instant: instant = true
        }
        let drawsInstantly = instant && (engine?.instantVoiceDelayMilliseconds ?? 0) > 0
        let consumer = Task.detached(priority: .userInitiated) { [weak self] in
            guard let engine else { return }
            await engine.restart(hostFrame: startFrame)
            await engine.setDrawing(drawsInstantly ? .instant : .standard)
            do {
                for await samples in stream {
                    try Task.checkCancellation()
                    try await engine.append(samples)
                    await self?.tick()
                }
            } catch is CancellationError {
            } catch {
                await self?.engineFailed(id: id, error)
            }
        }
        let utterance = Utterance(id: id, sampleRate: sampleRate, resampler: resampler, feed: feed, consumer: consumer)
        if let engine {
            var delay = Double(engine.lipLeadMilliseconds) / 1000
            if !externalClock { delay += SpeechPlayer.outputLatency }
            utterance.displayDelaySamples = Int64((delay * sampleRate).rounded())
            if drawsInstantly, !externalClock {
                utterance.instantDelay = instantVoiceDelay ?? .milliseconds(engine.instantVoiceDelayMilliseconds)
            }
        }
        self.utterance = utterance
        stats.utterances += 1
        if case .ready = phase { phase = .speaking }
        startTicker()
        return utterance
    }

    /// Starts the voice once the first frame is ready, or after `maxSyncDelay`, so the lips start with the voice.
    private func releaseHeldAudio(force: Bool) {
        guard let utterance, !utterance.started, !externalClock else { return }
        let waited = utterance.heldSince.map { $0.duration(to: .now) } ?? .zero
        if let delay = utterance.instantDelay {
            // Instant lips: the voice never waits for a frame, only for its fixed delay.
            guard force || waited >= delay else { return }
        } else {
            guard force || utterance.prepared[0] != nil || waited >= maxSyncDelay else { return }
        }
        utterance.started = true
        for chunk in utterance.held { player.schedule(chunk) }
        utterance.held = []
    }

    private func engineFailed(id: Int, _ error: Error) {
        guard let utterance, utterance.id == id else { return }
        lastRendererError = String(describing: error)
        utterance.engineFailed = true
        isShowingSpeech = false
        releaseHeldAudio(force: true)
    }

    private func playbackDrained() {
        guard let utterance, utterance.ended, utterance.held.isEmpty, player.isIdle else { return }
        finishUtterance()
    }

    private func finishUtterance() {
        guard let utterance else { return }
        utterance.consumer.cancel()
        utterance.feed.finish()
        if utterance.shown >= 0 { hostFrame += utterance.shown + 1 }
        self.utterance = nil
        isShowingSpeech = false
        endFade()
        ticker?.cancel(); ticker = nil
        if case .speaking = phase { phase = engine == nil ? .notPrepared : .ready }
        if engine != nil, case .notPrepared = phase { phase = .ready }
    }

    // MARK: - Frame clock

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }

    private func tick() {
        guard let utterance, let engine, !utterance.engineFailed else { return }
        if !utterance.started, !externalClock { releaseHeldAudio(force: false) }
        let played = externalClock ? utterance.externalPlayed : (utterance.started ? player.playedSamples : 0)
        let playing = externalClock ? played > 0 : utterance.started
        let perFrame = utterance.sampleRate / 25
        // Frame n covers audio from n/25 s; the level follows the voice as heard.
        let heardFrame = playing ? Int(Double(played) / perFrame) : -1
        let level = heardFrame >= 0 && heardFrame < utterance.levels.count ? Double(utterance.levels[heardFrame]) : 0
        if level != voiceLevel { voiceLevel = level }

        // The face's clock, in frames: what is heard, less the lip model's lead (and the output path's latency).
        let position = playing ? Double(played - utterance.displayDelaySamples) / perFrame : -1
        let playedFrame = position >= 0 ? Int(position) : -1
        let blending = lipCadence == .blend
        // With the blend a frame starts to fade in half a frame before it is due.
        let newest = position >= 0 ? Int((position + (blending ? 0.5 : 0)).rounded(.down)) : -1
        if newest >= 0, let frame = utterance.prepared.keys.filter({ $0 <= newest && $0 > utterance.shown }).max(),
           let picture = utterance.prepared[frame] {
            let jump = !Self.neighbourHosts(utterance.shownHost, picture.host)
            // A frame across a jump in the head's footage is never shown before it is due.
            if !(blending && jump && frame > playedFrame) {
                stats.framesSkipped += max(0, frame - utterance.shown - 1)
                stats.framesShown += 1
                if blending { startFade(to: picture, frame: frame, previous: utterance.shown, jump: jump, position: position) }
                else { endFade() }
                speechFrame = picture.image
                utterance.shown = frame
                utterance.shownHost = picture.host
                isShowingSpeech = true
                utterance.prepared = utterance.prepared.filter { $0.key > frame }
            }
        }
        // Frames the audio has already passed are not worth rendering.
        if utterance.nextToPrepare < playedFrame - 1 { utterance.nextToPrepare = playedFrame - 1 }
        guard !utterance.preparing, utterance.nextToPrepare <= max(playedFrame, 0) + 4 else { return }
        utterance.preparing = true
        let wanted = utterance.nextToPrepare, id = utterance.id
        Task { [weak self] in
            let picture: EngineFrame?
            do { picture = try await engine.frame(wanted) } catch { self?.engineFailed(id: id, error); return }
            guard let self, let current = self.utterance, current.id == id else { return }
            current.preparing = false
            if let picture {
                current.prepared[wanted] = picture
                current.nextToPrepare = wanted + 1
                self.tick()
            }
        }
    }

    // MARK: - Lip cadence

    /// The picture a fading frame fades in over, and the fade's progress (`lipBlendWeight(at:)`). Nil: no fade runs.
    private(set) var fadingFrom: CGImage?
    @ObservationIgnored private var fadeStart = Date.distantPast
    @ObservationIgnored private var fadeInitialWeight = 1.0
    @ObservationIgnored private var fadeSeconds = 0.04

    /// The weight of `speechFrame` over `fadingFrom` at `date` (1 when no fade runs). The view reads it at every refresh.
    func lipBlendWeight(at date: Date) -> Double {
        guard fadingFrom != nil else { return 1 }
        return min(1, max(fadeInitialWeight, fadeInitialWeight + date.timeIntervalSince(fadeStart) / fadeSeconds))
    }

    /// Hosts one or two apart in the footage (or no host at all on either side) show one head; anything else is a jump.
    private static func neighbourHosts(_ a: Int?, _ b: Int?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return abs(a - b) <= 2
    }

    /// Frame `frame` replaces frame `previous` on screen at face clock `position` (frames). A neighbour fades in over one
    /// frame's time centred on its due time (half weight when due); a jump in the footage over three frames, from its due
    /// time. The first frame of an utterance, a frame after more than one skipped, or one ready after its fade would have
    /// ended, steps in whole. Without a host (the classic anime) frames step, as in the Luna app.
    private func startFade(to picture: EngineFrame, frame: Int, previous: Int, jump: Bool, position: Double) {
        guard previous >= 0, frame - previous <= 2, picture.host != nil, let from = speechFrame else { return endFade() }
        let window = jump ? 3.0 : 1.0
        let weight = min(1, max(0, (position - Double(frame)) / window + 0.5))
        guard weight < 1 else { return endFade() }
        // A fade across a jump still running keeps the picture from before the jump under the new frame: fading from the
        // half-faded picture would show the jump again.
        if fadingFrom != nil, fadeSeconds > 0.05, lipBlendWeight(at: Date()) < 1 { return }
        fadingFrom = from
        fadeStart = Date(); fadeInitialWeight = weight; fadeSeconds = 0.04 * window
    }

    private func endFade() {
        if fadingFrom != nil { fadingFrom = nil }
        fadeInitialWeight = 1
    }

    // MARK: - Session

    /// Ends the metered session and releases the renderer. The downloaded files stay cached.
    public func close() async {
        interrupt()
        microphone.stop()
        player.shutdown()
        engine = nil
        if let packDirectory { await AssetStore.shared.release(packDirectory) }
        packDirectory = nil
        await endSession()
        phase = .notPrepared
    }

    /// Stops heartbeats and ends the current session on the API, best effort.
    private func endSession() async {
        heartbeat?.stop(); heartbeat = nil
        guard let credentials else { return }
        self.credentials = nil
        await SessionAPI.end(credentials)
    }

    private func startHeartbeat() {
        heartbeat?.stop()
        isHeartbeatDegraded = false
        let heartbeat = SessionHeartbeat(hooks: .init(
            credentials: { [weak self] in self?.credentials },
            renew: { [weak self] in try await self?.renewSession() },
            grant: { [weak self] token, _ in self?.useGrant(token) },
            ended: { [weak self] error in self?.sessionEnded(error) },
            degraded: { [weak self] detail in self?.heartbeatDegraded(detail) },
            recovered: { [weak self] in self?.heartbeatRecovered() }),
            outageGraceSeconds: heartbeatOutageGraceSeconds)
        self.heartbeat = heartbeat
        heartbeat.start()
    }

    /// Beats now, for example when the app returns to the foreground. The session may have been ended while the app
    /// was suspended; a new one is opened if so.
    public func refreshSession() async {
        await heartbeat?.beatNow()
    }

    private func renewSession() async throws {
        let fetchCredentials: @Sendable () async throws -> YoobCredentials
        switch source {
        case .local(_, let credentials), .cloud(_, let credentials): fetchCredentials = credentials
        }
        let next = try await fetchCredentials()
        guard heartbeat != nil else { return }
        credentials = next
        access?.downloadToken = next.downloadToken
    }

    private func useGrant(_ token: String) {
        credentials = credentials?.renewingGrant(token)
        access?.downloadToken = token
    }

    private static let log = Logger(subsystem: "com.yoob.sdk", category: "session")

    private func heartbeatDegraded(_ detail: String) {
        isHeartbeatDegraded = true
        if let onHeartbeatDegraded { onHeartbeatDegraded(detail) }
        else { Self.log.warning("Yoob heartbeat failed (\(detail, privacy: .public)); retrying while the character keeps rendering.") }
    }

    private func heartbeatRecovered() {
        isHeartbeatDegraded = false
        onHeartbeatRecovered?()
    }

    private func sessionEnded(_ reason: YoobError) {
        heartbeat = nil
        isHeartbeatDegraded = false
        interrupt()
        microphone.stop()
        player.shutdown()
        engine = nil
        isShowingSpeech = false
        speechFrame = nil
        endFade()
        voiceLevel = 0
        if let credentials {
            self.credentials = nil
            Task { await SessionAPI.end(credentials) }
        }
        phase = .stopped(reason)
        onSessionEnded?(reason)
    }
}
