import Foundation

/// The realistic head's path through the host clip, played at the clip's own speed (one host frame per call frame)
/// whether she speaks or not, as the anime host video plays under its lips. It walks two sets of lane
/// (`CalmHostWindow`): in silence the silence lanes (the closed-lip stretches, where her real lips are closed and the
/// frame is the clip's own picture, and the chin lift, where the model seals the mouth over her moving head); while the
/// voice plays the speech lanes, where she talks in the footage and her head, brows and eyes move as they do when she
/// speaks, the model drawing only the lips. It changes lanes at measured crossings (host pairs whose raw upper faces
/// match): into speech at the first frame that has one once the voice starts (`entries`), back to a closed-lip lane at
/// the first that has one once the lips have sealed (`exits`), and between lanes of one set on an itinerary after a
/// stay; a lane in both sets is walked on in place when the voice starts or stops.
///
/// Inside a lane the head goes forward and back between the lane's ends, which sit on slow steps, so a turn never
/// reverses a fast motion. No host is ever repeated in a row, no frame is held, nothing depends on the audio but whether
/// the lips are sealed (`speaking`), which the renderer decides from audio it is guaranteed to have, so 10x and 1x
/// delivery give the same head.
///
/// Silence enters only lanes with her real lips closed (`silenceEntersOpenLipLanes`): an itinerary crossing into a silence
/// lane without them (the realistic chin lift, the pup's 345-354) is skipped, and a silence that begins on such a lane
/// leaves it at its first exit. Those lanes are speaking footage: under the model's sealed mouth her jaw and chin still
/// moved as much as in speech, which looked unnatural while she listens.
public struct HostPath: Sendable, Equatable {
    /// A crossing between lanes: from `from`, the next host is `to`.
    public struct Crossing: Sendable, Equatable, Hashable {
        public let from: Int, to: Int
        public init(_ from: Int, _ to: Int) { self.from = from; self.to = to }
    }
    public let window: AvatarPack.CalmHostWindow
    /// Whether silence may walk into a silence lane without her real lips closed (the model's sealed mouth over speaking
    /// footage), as before 2026-09-25. Off: silence stays on the closed-lip lanes. A comparison switch (the probe's
    /// `--open-lip-silence`); the app never sets it.
    nonisolated(unsafe) public static var silenceEntersOpenLipLanes = false
    /// The host of the last frame.
    public private(set) var host: Int
    /// Whether the head is in a speech lane.
    public private(set) var speaking: Bool
    private var lane: ClosedRange<Int>
    private var direction: Int
    /// Frames in the current lane since landing, and whether the stay is over and the head is heading for the exit.
    private var stayed = 0, leaving = false
    /// Visits and the next crossing of each itinerary, kept across a change of kind so the cycle carries on.
    private var calmVisit = 0, calmLeg = 0, speechVisit = 0, speechLeg = 0
    /// Whether the start host has been shown: the first frame of a call is the start host itself; a restart resumes from
    /// the host on screen, so its first frame is the one after.
    private var started: Bool

    /// A path starting on `startHost` (kept where it lies: a restart hands over the host on screen, in whichever lane),
    /// heading the window's way from its start and toward the lane's far end from anywhere else. `resuming`: the start
    /// host is on screen already, so the first frame moves on from it.
    public init(window: AvatarPack.CalmHostWindow, startHost: Int, resuming: Bool = false) {
        self.window = window
        started = resuming
        let all = window.lanes + window.speechLanes
        let host = all.contains { $0.contains(startHost) } ? startHost : window.pathStart
        self.host = host
        // A lane of both sets starts in silence: the lips decide on the first frame.
        speaking = window.isSpeech(host) && !window.isCalm(host)
        lane = (speaking ? window.speechLanes : window.lanes).first { $0.contains(host) } ?? host...host
        direction = host == window.pathStart ? (window.pathStartRising ? 1 : -1) : ((lane.upperBound - host) >= (host - lane.lowerBound) ? 1 : -1)
        calmLeg = Self.leg(from: 0, leaving: window.isCalm(host) ? lane : nil, in: window.itinerary, lanes: window.lanes, accepts: Self.silenceAccepts(window))
        // A silence that begins on a lane without her real lips closed heads for its first exit at once.
        if !speaking, !Self.silenceEntersOpenLipLanes, !window.isClosedLips(host) { leaving = true }
        speechLeg = Self.leg(from: 0, leaving: speaking ? lane : nil, in: window.speechItinerary, lanes: window.speechLanes)
    }

    /// The host for the next call frame. `speaking`: the lips are not sealed on it (the voice plays, or is about to).
    /// `settling`: a stall walk, which leaves a lane without her real lips closed at its first exit, whatever the stay.
    public mutating func next(speaking voice: Bool, settling: Bool = false) -> Int {
        if voice != speaking {
            if voice ? window.isSpeech(host) : window.isCalm(host) {
                // A lane of both sets (the chin lift): walk on in place, on the other set's itinerary. Sealed lips leave
                // it at its first exit (silence comes back to it on the itinerary, with the model's sealed mouth).
                speaking = voice
                lane = (voice ? window.speechLanes : window.lanes).first { $0.contains(host) } ?? lane
                stayed = 0; leaving = !voice && !window.isClosedLips(host)
                if voice { speechLeg = Self.leg(from: speechLeg, leaving: lane, in: window.speechItinerary, lanes: window.speechLanes) }
                else { calmLeg = Self.leg(from: calmLeg, leaving: lane, in: window.itinerary, lanes: window.lanes, accepts: Self.silenceAccepts(window)) }
            } else if let to = (voice ? window.entries : window.exits)[host] {
                land(on: to, speaking: voice); started = true
                return host
            }
        }
        if !started { started = true; return host }
        // In silence a lane without her real lips closed is left at its first exit once the stay is over.
        if !speaking, !window.isClosedLips(host), leaving || settling, let to = window.exits[host] {
            calmVisit += 1
            land(on: to, speaking: false)
            return host
        }
        let itinerary = speaking ? window.speechItinerary : window.itinerary
        let stays = speaking ? window.speechStays : (window.isClosedLips(host) ? window.stays : window.openLipStays)
        let leg = speaking ? speechLeg : calmLeg
        if leaving, leg < itinerary.count, host == itinerary[leg].from, speaking || Self.silenceAccepts(window)(itinerary[leg]) {
            if speaking { speechVisit += 1; speechLeg = (leg + 1) % itinerary.count } else { calmVisit += 1; calmLeg = (leg + 1) % itinerary.count }
            land(on: itinerary[leg].to, speaking: speaking, keepLeg: true)
            return host
        }
        if !lane.contains(host + direction) { direction = -direction }
        host = min(max(host + direction, lane.lowerBound), lane.upperBound)
        stayed += 1
        let visit = speaking ? speechVisit : calmVisit
        if !stays.isEmpty, stayed >= stays[visit % stays.count] { leaving = true }
        return host
    }

    /// Lands on `to` in a lane of the given kind, heading for its far end, and picks up that kind's itinerary at the next
    /// crossing that leaves this lane.
    private mutating func land(on to: Int, speaking voice: Bool, keepLeg: Bool = false) {
        host = to; speaking = voice
        let lanes = voice ? window.speechLanes : window.lanes
        lane = lanes.first { $0.contains(to) } ?? to...to
        direction = (lane.upperBound - to) >= (to - lane.lowerBound) ? 1 : -1
        stayed = 0; leaving = false
        if !keepLeg {
            if voice { speechLeg = Self.leg(from: speechLeg, leaving: lane, in: window.speechItinerary, lanes: lanes) }
            else { calmLeg = Self.leg(from: calmLeg, leaving: lane, in: window.itinerary, lanes: lanes, accepts: Self.silenceAccepts(window)) }
        } else {
            let leg = voice ? speechLeg : calmLeg
            let fixed = Self.leg(from: leg, leaving: lane, in: voice ? window.speechItinerary : window.itinerary, lanes: lanes,
                                 accepts: voice ? { _ in true } : Self.silenceAccepts(window))
            if voice { speechLeg = fixed } else { calmLeg = fixed }
        }
    }

    /// The first crossing at or after `index` (cyclically) that leaves `lane` and `accepts` takes; `index` when there is
    /// none or no lane (then the path turns at the lane's ends: `next` takes only a crossing `accepts` takes).
    private static func leg(from index: Int, leaving lane: ClosedRange<Int>?, in itinerary: [Crossing], lanes: [ClosedRange<Int>],
                            accepts: (Crossing) -> Bool = { _ in true }) -> Int {
        guard let lane, !itinerary.isEmpty else { return index }
        for offset in 0..<itinerary.count {
            let candidate = (index + offset) % itinerary.count
            if lane.contains(itinerary[candidate].from), accepts(itinerary[candidate]) { return candidate }
        }
        return index
    }

    /// The silence crossings the path takes: into a closed-lip lane only, unless `silenceEntersOpenLipLanes`.
    static func silenceAccepts(_ window: AvatarPack.CalmHostWindow) -> (Crossing) -> Bool {
        let open = silenceEntersOpenLipLanes
        return { open || window.isClosedLips($0.to) }
    }

    /// The hosts of the next `count` frames if the lips were `speaking` on each of them, without moving this path.
    public func ahead(_ count: Int, speaking flags: [Bool]) -> [Int] {
        var copy = self
        return (0..<count).map { copy.next(speaking: $0 < flags.count ? flags[$0] : false) }
    }

    /// Call frames a frame frozen with closed eyes (a speech blink picture) stays as it is before the blink is finished on
    /// it (`StreamingAvatar.openEyesImage`): a gap between frames only a stall leaves.
    public static let openEyesDelayFrames = 3
    /// The longest stall walk: on along the path, out of the chin lift at its next exit, to the next twin of the idle face
    /// (at most ~2.4 s: half the lift, the exit and a few calm hosts).
    public static let stallFramesLimit = 60
    /// Call frames over which a stall walk closes the lips from the frozen frame's mouth.
    public static let stallCloseFrames = 4

    /// The closed-lips weight of the stall picture `step` frames into the walk, from the frozen frame's own weight.
    public static func stallLipsClosed(step: Int, frozen: Float) -> Float {
        let closing = min(1, Float(max(0, step) + 1) / Float(stallCloseFrames))
        return closing + (1 - closing) * min(max(frozen, 0), 1)
    }

    /// Whether a stall picture keeps speech on screen: until the head is on a home pose and the lips are closed, when the
    /// still idle face takes over on a pose it matches.
    public static func holdsStalledSpeech(host: Int, lipsClosed: Float, window: AvatarPack.CalmHostWindow) -> Bool {
        lipsClosed < 1 || !window.isHome(host)
    }
}
