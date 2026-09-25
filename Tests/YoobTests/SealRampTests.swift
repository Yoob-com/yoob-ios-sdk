import XCTest
@testable import YoobRealistic

/// The silence seal closes over `sealFrames` from the frame before (`StreamingAvatar.rampedSeal`); opening is never held back.
final class SealRampTests: XCTestCase {
    func testSealClosesOverFourFramesAndOpensAtOnce() {
        // Instant lips decide a silence on the ramp's last frame: 0 then 1. Drawn, it closes a quarter a frame.
        var previous: Float? = nil, drawn: [Float] = []
        for target: Float in [0, 0, 1, 1, 1, 1, 1, 0.5, 0] {
            let seal = StreamingAvatar.rampedSeal(target, after: previous)
            drawn.append(seal); previous = seal
        }
        XCTAssertEqual(drawn, [0, 0, 0.25, 0.5, 0.75, 1, 1, 0.5, 0])
        // A ramp already gentler than a quarter a frame is kept; a segment's first frame takes its seal as decided.
        XCTAssertEqual(StreamingAvatar.rampedSeal(0.5, after: 0.25), 0.5)
        XCTAssertEqual(StreamingAvatar.rampedSeal(1, after: nil), 1)
        // Mid-close, her voice back: open at once.
        XCTAssertEqual(StreamingAvatar.rampedSeal(0, after: 0.75), 0)
    }
}
