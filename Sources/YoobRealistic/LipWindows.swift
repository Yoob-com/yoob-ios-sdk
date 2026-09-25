import Foundation

/// The lip model's audio windows, read from the pack's manifest and checked at load, so a lip model trained with another
/// lookahead takes a new pack rather than new code (as `CropGeometry` does for its sizes).
///
/// The renderer reads the features of frames m - `past` ... m + `lookahead` (20 of them); the feature of frame f is encoded from
/// the 16 kHz audio of frames [f - `left`, f + 1 + `right`) plus 80 samples. Frame m can therefore be drawn from real audio once
/// the audio through (m + 1 + `fullLookaheadFrames`) x 640 + 80 samples is in: `fullLookaheadFrames` frames and 80 samples after
/// its own 40 ms.
///
/// - H08 and every pack before it (`h08`): lookahead 9, left 16, right 4, and the first 8 features from one encode of frames
///   [0, 8); a window that would reach before the segment's first sample starts at that sample instead (13 to 21 frames).
///   13 frames + 80 samples: 525 ms.
/// - A low-lookahead pack (`bootstrap` 0): every feature from its own 21-frame window (the steady encoder's shape), with zeros
///   before the segment's first sample, exactly as its training features were encoded (the pup lane's `stream_feats_lowla.py`).
///   Lookahead 2, left 20, right 0: 2 frames + 80 samples, 85 ms.
public struct LipWindows: Sendable, Equatable {
    public let lookahead: Int, left: Int, right: Int, bootstrap: Int
    public static let h08 = LipWindows(lookahead: 9, left: 16, right: 4, bootstrap: 8)!

    /// Nil unless the values are the H08 contract, or a low-lookahead one: lookahead 0-9, right context 0-4 and one 21-frame
    /// window per feature.
    public init?(lookahead: Int, left: Int, right: Int, bootstrap: Int) {
        guard (0...9).contains(lookahead), (0...4).contains(right) else { return nil }
        if bootstrap == 8 {
            guard lookahead == 9, left == 16, right == 4 else { return nil }
        } else {
            guard bootstrap == 0, left >= 16, left + 1 + right == 21 else { return nil }
        }
        self.lookahead = lookahead; self.left = left; self.right = right; self.bootstrap = bootstrap
    }
    public init?(manifest: AvatarManifest) {
        self.init(lookahead: manifest.lookahead, left: manifest.leftContext, right: manifest.rightContext, bootstrap: manifest.bootstrap)
    }
    /// Features before frame m in the renderer's window.
    public var past: Int { 19 - lookahead }
    /// Frames of audio after a frame's own 40 ms (and 80 samples more) that its full window reads.
    public var fullLookaheadFrames: Int { lookahead + right }
    /// Milliseconds of audio after a frame's own 40 ms that its full window reads.
    public var fullLookaheadMilliseconds: Int { fullLookaheadFrames * 40 + 5 }
    /// Windows reaching before the segment's first sample are zero-padded to their full length (not cut short).
    public var padsBeforeStart: Bool { bootstrap == 0 }
    /// The encode that yields the feature of frame `f`: audio frames [low, high) plus 80 samples, giving the features of frames
    /// first..<last. `low` is negative only when `padsBeforeStart`: those frames are zeros.
    public func encode(feature f: Int) -> (low: Int, high: Int, first: Int, last: Int) {
        if bootstrap > 0, f == 0 { return (0, bootstrap, 0, bootstrap) }
        return (padsBeforeStart ? f - left : max(0, f - left), f + 1 + right, f, f + 1)
    }
    /// The samples of audio frames [low, high) plus 80, from `samples`, whose first element is sample `base` of the segment and
    /// which reach the window's end (the caller adds any stand-in audio first). Before the segment's first sample: zeros.
    static func window(_ samples: [Float], base: Int, low: Int, high: Int) -> [Float] {
        let start = low * 640, end = high * 640 + 80
        guard start < 0 else { return Array(samples[(start - base)..<(end - base)]) }
        precondition(base == 0, "a window before the segment's start with its first samples dropped")
        return [Float](repeating: 0, count: -start) + samples[0..<end]
    }
}
