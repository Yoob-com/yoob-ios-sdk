import XCTest
@testable import YoobRealistic

/// The lip model's audio windows (`LipWindows`): H08's must be exactly the pipeline's former fixed windows, so every shipped
/// pack renders byte for byte as before; a low-lookahead pack's must be the windows its training features were encoded with.
final class LipWindowsTests: XCTestCase {
    func testH08IsTheFormerFixedWindows() {
        let h08 = LipWindows.h08
        XCTAssertEqual(h08.past, 10)
        XCTAssertEqual(h08.fullLookaheadFrames, 13)
        XCTAssertEqual(h08.fullLookaheadMilliseconds, 525)
        XCTAssertFalse(h08.padsBeforeStart)
        XCTAssertEqual(StreamingAvatar.fullLookaheadFrames, 13)
        // The pipeline encoded feature 0 as the bootstrap [0, 8) and every later one (8 on) from [max(0, f - 16), f + 5).
        let bootstrap = h08.encode(feature: 0)
        XCTAssertTrue(bootstrap == (0, 8, 0, 8))
        for f in 8..<400 {
            let window = h08.encode(feature: f)
            XCTAssertTrue(window == (max(0, f - 16), f + 5, f, f + 1), "feature \(f)")
            // Always a shape the pack's encoders take (`AvatarManifest.encoderWindowFrames`).
            XCTAssertTrue(([8] + Array(13...21)).contains(window.high - window.low), "feature \(f)")
        }
    }

    func testLowLookaheadIsOneTwentyOneFrameWindowPerFeature() throws {
        let low = try XCTUnwrap(LipWindows(lookahead: 2, left: 20, right: 0, bootstrap: 0))
        XCTAssertEqual(low.past, 17)
        XCTAssertEqual(low.fullLookaheadFrames, 2)
        XCTAssertEqual(low.fullLookaheadMilliseconds, 85)
        XCTAssertTrue(low.padsBeforeStart)
        for f in 0..<400 {
            let window = low.encode(feature: f)
            XCTAssertTrue(window == (f - 20, f + 1, f, f + 1), "feature \(f)")
            XCTAssertEqual(window.high - window.low, 21)
        }
        // The renderer's window is always 20 features, the current frame at index `past`.
        for lookahead in 0...9 {
            let windows = try XCTUnwrap(LipWindows(lookahead: lookahead, left: 20, right: 0, bootstrap: 0))
            XCTAssertEqual(windows.past + 1 + windows.lookahead, 20)
        }
    }

    func testOnlyTheH08OrOneWindowContractsLoad() {
        XCTAssertNotNil(LipWindows(lookahead: 9, left: 16, right: 4, bootstrap: 8))
        XCTAssertNotNil(LipWindows(lookahead: 1, left: 19, right: 1, bootstrap: 0))
        XCTAssertNil(LipWindows(lookahead: 2, left: 16, right: 4, bootstrap: 8), "the bootstrap belongs to H08's windows only")
        XCTAssertNil(LipWindows(lookahead: 10, left: 20, right: 0, bootstrap: 0), "more future than the window's 20 features allow")
        XCTAssertNil(LipWindows(lookahead: 2, left: 15, right: 5, bootstrap: 0), "right context over 4")
        XCTAssertNil(LipWindows(lookahead: 2, left: 16, right: 0, bootstrap: 0), "not the steady encoder's 21 frames")
        XCTAssertNil(LipWindows(lookahead: 2, left: 20, right: 0, bootstrap: 4))
    }

    func testAWindowBeforeTheSegmentStartIsZeroPadded() {
        let samples = (0..<(3 * 640 + 80)).map { Float($0 + 1) }
        let window = LipWindows.window(samples, base: 0, low: -18, high: 3)
        XCTAssertEqual(window.count, 21 * 640 + 80)
        XCTAssertTrue(window.prefix(18 * 640).allSatisfy { $0 == 0 })
        XCTAssertEqual(Array(window.suffix(3 * 640 + 80)), samples)
        // Inside the segment it is the plain slice, from wherever the kept samples begin.
        let kept = Array(samples[640...]), plain = LipWindows.window(kept, base: 640, low: 1, high: 3)
        XCTAssertEqual(plain, Array(samples[640..<(3 * 640 + 80)]))
    }
}
