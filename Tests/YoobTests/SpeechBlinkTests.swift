import XCTest
@testable import YoobRealistic

final class SpeechBlinkTests: XCTestCase {
    private let window = AvatarPack.CalmHostWindow.realistic

    private func blink(width: Int = 40, height: Int = 30, value: UInt8 = 200) -> SpeechBlink {
        let picture = Data(repeating: value, count: width * height * 4)
        return SpeechBlink(rect: [10, 20, width, height], sequence: [1, 2, 2, 1, 0, 3], pictures: [picture, picture, picture, picture])!
    }

    func testAPictureReplacesTheEyesAndBlendsInOverItsEdges() {
        let blink = blink()
        let frameWidth = 60, frameHeight = 70
        var frame = [UInt8](repeating: 100, count: frameWidth * frameHeight * 4)
        frame.withUnsafeMutableBufferPointer { blink.draw(picture: 2, into: $0, frameWidth: frameWidth, frameHeight: frameHeight) }
        func value(_ x: Int, _ y: Int) -> UInt8 { frame[(y * frameWidth + x) * 4] }
        // Untouched outside the rectangle, replaced deep inside it, and a straight ramp across the edge.
        XCTAssertEqual(value(9, 25), 100); XCTAssertEqual(value(50, 25), 100); XCTAssertEqual(value(20, 19), 100); XCTAssertEqual(value(20, 50), 100)
        XCTAssertEqual(value(10 + 20, 20 + 15), 200)
        XCTAssertEqual(value(10, 20 + 15), 108, "one pixel in: 1/12 of the way")
        XCTAssertEqual(value(10 + 5, 20 + 15), 150, "six pixels in: halfway")
        XCTAssertEqual(value(10 + 11, 20 + 15), 200, "twelve pixels in: the picture")
        XCTAssertEqual(value(10 + 20, 20 + 2), 125, "three rows in: a quarter")
        // Alpha is the compositor's: untouched.
        XCTAssertTrue(stride(from: 3, to: frame.count, by: 4).allSatisfy { frame[$0] == 100 })
    }

    func testAPictureOutsideTheFrameOrUnknownIsNotDrawn() {
        let blink = blink()
        var frame = [UInt8](repeating: 100, count: 20 * 20 * 4)
        frame.withUnsafeMutableBufferPointer { blink.draw(picture: 0, into: $0, frameWidth: 20, frameHeight: 20) }
        XCTAssertTrue(frame.allSatisfy { $0 == 100 || $0 == 255 })
        var big = [UInt8](repeating: 100, count: 60 * 70 * 4)
        big.withUnsafeMutableBufferPointer { blink.draw(picture: 9, into: $0, frameWidth: 60, frameHeight: 70) }
        XCTAssertTrue(big.allSatisfy { $0 == 100 || $0 == 255 })
    }

    func testBadPicturesAreRefused() {
        XCTAssertNil(SpeechBlink(rect: [0, 0, 4, 4], sequence: [0], pictures: [Data(repeating: 0, count: 4 * 4 * 3)]), "not RGBA")
        XCTAssertNil(SpeechBlink(rect: [0, 0, 4, 4], sequence: [1], pictures: [Data(repeating: 0, count: 64)]), "sequence past the pictures")
        XCTAssertNil(SpeechBlink(rect: [0, 0, 4], sequence: [0], pictures: [Data(repeating: 0, count: 64)]))
        XCTAssertNotNil(SpeechBlink(rect: [0, 0, 4, 4], sequence: [0], pictures: [Data(repeating: 0, count: 64)]))
    }

    func testTheScheduleStartsEachBlinkOnExactlyOneFrame() {
        let schedule = IdleBlinkSchedule(sequence: [1, 2, 2, 1, 0, 3])
        var starts = 0
        for frame in 0..<(25 * 60 * 5) where schedule.blinkStarts(at: Double(frame) * 0.04, step: 0.04) { starts += 1 }
        let scheduled = (0...Int(300 / schedule.cellSeconds)).flatMap { schedule.starts(inCell: $0) }.filter { $0 < 300 }.count
        XCTAssertEqual(starts, scheduled, "one start frame per scheduled blink over five minutes")
        XCTAssertGreaterThan(starts, 60)
        // The frame that starts a blink is the first one showing its first picture.
        for frame in 0..<(25 * 60) where schedule.blinkStarts(at: Double(frame) * 0.04, step: 0.04) {
            XCTAssertEqual(schedule.picture(at: Double(frame) * 0.04), 1)
            XCTAssertNil(schedule.picture(at: Double(frame - 1) * 0.04) == 1 && frame > 0 ? 1 : nil, "not already blinking")
        }
        XCTAssertFalse(IdleBlinkSchedule(sequence: []).blinkStarts(at: 3, step: 0.04))
    }

    func testTheGateWaitsForTheCrossfadeAndNeedsARestPoseThroughTheBlink() {
        let rest = [Int](repeating: 114, count: 6)
        XCTAssertTrue(SpeechBlinkGate.allows(heldFrames: 8, hostsThroughBlink: rest, window: window, blinkFrames: 6))
        XCTAssertFalse(SpeechBlinkGate.allows(heldFrames: 30, hostsThroughBlink: [Int](repeating: 206, count: 6), window: window, blinkFrames: 6),
                       "no scheduled blink on the chin lift")
        XCTAssertFalse(SpeechBlinkGate.allows(heldFrames: 7, hostsThroughBlink: rest, window: window, blinkFrames: 6),
                       "the 0.22 s crossfade to speech may still be running")
        XCTAssertFalse(SpeechBlinkGate.allows(heldFrames: 30, hostsThroughBlink: Array(rest.prefix(5)), window: window, blinkFrames: 6),
                       "the frames ahead must be known")
        var lifting = rest; lifting[5] = 211
        XCTAssertFalse(SpeechBlinkGate.allows(heldFrames: 30, hostsThroughBlink: lifting, window: window, blinkFrames: 6),
                       "the head leaves the rest pose under the blink")
        var stillStretch = rest; stillStretch[2] = 5; stillStretch[3] = 340
        XCTAssertTrue(SpeechBlinkGate.allows(heldFrames: 30, hostsThroughBlink: stillStretch, window: window, blinkFrames: 6),
                      "the still stretches blink too")
    }
}
