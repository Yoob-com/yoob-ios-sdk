import Foundation

/// Whole-picture head life for realistic characters, ported from the Luna app (language-companions
/// `Core/SpeakingMotion.swift`, 2026-09-22). The host clip offers only a few stretches the head can walk while speaking,
/// so a long reply repeats the same head move, unrelated to what is said. This adds what a speaker does on top:
/// a small nod on each stressed syllable (driven by the played voice level, so it lands with the sound) and a slow sway
/// that grows while she talks and settles to breathing in silence. One transform moves the rendered face and the idle
/// face together, so the hand-over between them never jumps, and it keeps moving through a stalled frame.
///
/// Pure and deterministic: `update` is a function of the level/speaking history and the clock only.
struct SpeakingMotion: Equatable, Sendable {
    struct Pose: Equatable, Sendable {
        /// Points; positive is right / down.
        var dx: Double, dy: Double
        /// Tilt in degrees about a point below the chin (the neck).
        var degrees: Double
        /// Extra scale (0 = none); breathing.
        var scale: Double
        static let zero = Pose(dx: 0, dy: 0, degrees: 0, scale: 0)
    }

    /// Upper bounds of the motion, in points and degrees (screen points, ~2.6 source pixels each on a 6.5" phone).
    static let maxSwayPoints = 2.4, maxNodPoints = 3.2, maxTiltDegrees = 1.1
    /// A played peak at or above this counts as full voice (the realistic voice peaks 0.2-0.6).
    static let fullLevel = 0.35
    /// How much of the sway plays in silence (breathing, a slow drift) relative to speech.
    static let silenceWeight = 0.35

    private var fast = 0.0, slow = 0.0
    private var nod = 0.0, nodVelocity = 0.0
    private var weight = silenceWeight
    private var last: Double?
    private var origin: Double?
    init() {}

    /// Advances to `time` (seconds, any monotonic clock) with the level currently playing (peak, 0...1).
    mutating func update(level: Double, speaking: Bool, at time: Double) -> Pose {
        let dt = min(0.1, max(0, time - (last ?? time)))
        last = time
        if origin == nil { origin = time }
        let t = time - (origin ?? time)
        let voice = speaking ? min(1, max(0, level) / Self.fullLevel) : 0
        // Envelopes: a fast one that follows syllables and a slow one that follows the phrase.
        fast += (voice - fast) * Self.blend(dt, tau: voice > fast ? 0.04 : 0.12)
        slow += (voice - slow) * Self.blend(dt, tau: 0.6)
        // A stressed syllable is where the fast envelope rises above the phrase level: nod into it (a damped spring).
        let emphasis = max(0, fast - slow * 1.05)
        let stiffness = 70.0, damping = 2 * stiffness.squareRoot() * 0.75
        nodVelocity += (emphasis * 1.6 - nod) * stiffness * dt - nodVelocity * damping * dt
        nod += nodVelocity * dt
        nod = min(1, max(-0.4, nod))
        weight += ((speaking ? 1 : Self.silenceWeight) - weight) * Self.blend(dt, tau: speaking ? 0.5 : 1.2)
        // Slow sway: incommensurate low frequencies, so it never visibly loops.
        let tau = 2 * Double.pi
        let sway = sin(tau * 0.13 * t) * 0.6 + sin(tau * 0.071 * t + 1.3) * 0.4
        let tilt = sin(tau * 0.09 * t + 0.4) * 0.65 + sin(tau * 0.167 * t + 2.1) * 0.35
        let breath = sin(tau * 0.23 * t)
        // Eases in over the first 1.5 s, so the call's first picture is exactly the unmoved frame.
        let intro = min(1, t / 1.5)
        return Pose(dx: sway * weight * Self.maxSwayPoints * intro,
                    dy: nod * Self.maxNodPoints + breath * 0.5 * (1 - weight * 0.5) * intro,
                    degrees: (tilt * weight * Self.maxTiltDegrees * 0.8) * intro + nod * 0.2 * Self.maxTiltDegrees,
                    scale: breath * 0.0035 * intro)
    }

    /// Exponential smoothing factor for a step of `dt` with time constant `tau`.
    static func blend(_ dt: Double, tau: Double) -> Double { tau <= 0 ? 1 : 1 - exp(-dt / tau) }
}
