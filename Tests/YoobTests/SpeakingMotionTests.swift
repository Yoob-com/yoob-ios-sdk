import XCTest
@testable import Yoob

final class SpeakingMotionTests: XCTestCase {
    /// 25 Hz ticks for `seconds`, with a level function of time.
    private func run(_ motion: inout SpeakingMotion, from start: Double = 0, seconds: Double, speaking: Bool = true,
                     level: (Double) -> Double) -> [SpeakingMotion.Pose] {
        stride(from: start, to: start + seconds, by: 0.04).map { motion.update(level: level($0), speaking: speaking, at: $0) }
    }

    func testStartsOnTheUnmovedFrame() {
        var motion = SpeakingMotion()
        XCTAssertEqual(motion.update(level: 0, speaking: false, at: 100), .zero)
    }

    func testStaysWithinItsBoundsForAnyVoice() {
        var motion = SpeakingMotion()
        // Syllable-rate bursts at full level, then silence, then noise.
        let poses = run(&motion, seconds: 30) { t in t < 20 ? (Int(t * 5) % 2 == 0 ? 1 : 0.05) : 0 }
            + run(&motion, from: 30, seconds: 10) { t in abs(sin(t * 37)) }
        for pose in poses {
            XCTAssertLessThanOrEqual(abs(pose.dx), SpeakingMotion.maxSwayPoints + 1e-9)
            XCTAssertLessThanOrEqual(abs(pose.dy), SpeakingMotion.maxNodPoints + 0.5 + 1e-9)
            XCTAssertLessThanOrEqual(abs(pose.degrees), SpeakingMotion.maxTiltDegrees + 1e-9)
            XCTAssertLessThan(abs(pose.scale), 0.01)
        }
    }

    func testNodsIntoAStressedSyllable() {
        var motion = SpeakingMotion()
        _ = run(&motion, seconds: 3) { _ in 0.1 }        // a steady quiet phrase
        let before = motion.update(level: 0.1, speaking: true, at: 3)
        let after = run(&motion, from: 3.04, seconds: 0.2) { _ in 0.6 }.map(\.dy).max()!
        XCTAssertGreaterThan(after - before.dy, 1, "the head dips (moves down) with the stressed syllable")
    }

    func testSilenceIsCalmerThanSpeech() {
        var speaking = SpeakingMotion(), silent = SpeakingMotion()
        let talk = run(&speaking, seconds: 40) { t in 0.25 + 0.2 * sin(t * 18) }.map { abs($0.dx) }
        let rest = run(&silent, seconds: 40, speaking: false) { _ in 0 }.map { abs($0.dx) }
        XCTAssertGreaterThan(talk.max()!, rest.max()! * 2)
        XCTAssertGreaterThan(rest.max()!, 0.2, "she still breathes and drifts in silence")
    }

    func testMovesSmoothlyFrameToFrame() {
        var motion = SpeakingMotion()
        let poses = run(&motion, seconds: 20) { t in Int(t * 4) % 2 == 0 ? 0.5 : 0 }
        for (a, b) in zip(poses, poses.dropFirst()) {
            XCTAssertLessThan(abs(b.dy - a.dy), 0.8, "no pop between 40 ms frames")
            XCTAssertLessThan(abs(b.dx - a.dx), 0.2)
        }
    }
}
