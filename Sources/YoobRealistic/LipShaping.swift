import Foundation

/// Runtime shaping of the lip model's audio window, applied to each frame's renderer input after the silence seal
/// (`StreamingAvatar.renderNext`). No retraining: the renderer and encoder are untouched, only the [40, 1024] window they
/// exchange. Off (`nil` on the pipeline) leaves every crop byte for byte as before.
///
/// Articulation gain (lip-articulation study, 2026-09-24, the Luna app's study): the window pushed away from the pack's
/// closed-mouth window, `closed + gain x (window - closed)`. Luna's model opens her mouth less than her footage does
/// (aperture scale .76 of the footage's); a gain above 1 draws her articulation closer to it, and a sealed frame (the window
/// equal to the closed one) stays exactly closed.
public struct LipShaping: Sendable, Equatable {
    /// 1 leaves the window as it is.
    public var articulationGain: Float
    public init(articulationGain: Float) {
        self.articulationGain = max(0.5, min(2, articulationGain))
    }
    /// Whether this shaping changes nothing (the pipeline then skips it entirely).
    public var isIdentity: Bool { articulationGain == 1 }
    /// `window` shaped in place; `closed` is the pack's closed-mouth window (`AvatarPack.closedAudio`), the same length.
    public func apply(to window: inout [Float], closed: [Float]) {
        guard !isIdentity, window.count == closed.count else { return }
        let gain = articulationGain
        for index in window.indices { window[index] = closed[index] + gain * (window[index] - closed[index]) }
    }
}
