import XCTest
@testable import YoobRealistic

final class IdleBlinkTests: XCTestCase {
    private let schedule = IdleBlinkSchedule(sequence: [1, 2, 2, 1, 0, 3])

    private func blinks(over seconds: Double, from start: Double = 1_000_000) -> [(start: Double, pictures: [Int])] {
        var result: [(Double, [Int])] = []
        var current: [Int] = [], began = 0.0
        var t = start
        while t < start + seconds {
            if let picture = schedule.picture(at: t) {
                if current.isEmpty { began = t }
                current.append(picture)
            } else if !current.isEmpty { result.append((began, current)); current = [] }
            t += 0.04
        }
        return result
    }

    func testBlinksPlayTheWholeSequenceAndLastAQuarterSecond() {
        XCTAssertEqual(schedule.blinkSeconds, 0.24, accuracy: 1e-9)
        let seen = blinks(over: 600)
        XCTAssertGreaterThan(seen.count, 100)
        for blink in seen { XCTAssertEqual(blink.pictures, schedule.sequence) }
    }

    func testBlinksAreThreeToSixSecondsApartWithSomeDoubles() {
        let starts = (0..<400).flatMap { schedule.starts(inCell: $0) }
        var gaps = zip(starts, starts.dropFirst()).map { $1 - $0 }
        let doubles = gaps.filter { $0 < 1 }
        XCTAssertFalse(doubles.isEmpty, "some double blinks")
        XCTAssertLessThan(Double(doubles.count) / 400, 0.3)
        for gap in doubles { XCTAssertEqual(gap, 0.24 + 0.12, accuracy: 1e-9) }
        gaps = zip(schedule.starts(inCell: 0...399), schedule.starts(inCell: 0...399).dropFirst()).map { $1 - $0 }
        XCTAssertTrue(gaps.allSatisfy { (3.0...6.0).contains($0) }, "first blinks of consecutive cells")
        XCTAssertGreaterThan(gaps.max()! - gaps.min()!, 2, "the interval varies")
    }

    func testThePictureIsAPureFunctionOfTime() {
        for t in stride(from: 0.0, to: 60, by: 0.013) { XCTAssertEqual(schedule.picture(at: t), schedule.picture(at: t)) }
        XCTAssertNil(IdleBlinkSchedule(sequence: []).picture(at: 3))
        XCTAssertNil(schedule.picture(at: .nan))
    }

    func testABlinkHeldBackIsSkippedWholeAndTheNextOneKeepsItsPlace() {
        let seen = blinks(over: 60, from: 1_000_000)
        let held = seen[2]
        // The call screen sets the moment a crossfade ends; every blink that began before it is skipped, eyes open.
        for offset in [0.0, 0.08, 0.2, 0.239] {
            let resume = held.start + offset + 0.001
            for step in 0..<schedule.sequence.count {
                XCTAssertNil(schedule.picture(at: held.start + Double(step) * 0.04, resumeAfter: resume),
                             "no half-drawn blink at step \(step) with resume +\(offset)")
            }
            // Later blinks are untouched: the schedule is not moved.
            for later in seen.dropFirst(3) {
                let pictures = stride(from: later.start, to: later.start + 0.24, by: 0.04)
                    .compactMap { schedule.picture(at: $0, resumeAfter: resume) }
                XCTAssertEqual(pictures, schedule.sequence)
            }
        }
    }

    func testHoldingBlinksBackChangesNothingOutsideTheHold() {
        for t in stride(from: 1_000_000.0, to: 1_000_060, by: 0.02) {
            XCTAssertEqual(schedule.picture(at: t, resumeAfter: -.infinity), schedule.picture(at: t))
            XCTAssertEqual(schedule.picture(at: t, resumeAfter: 999_999), schedule.picture(at: t))
        }
    }

    func testChangesListEveryPictureSwitch() {
        let start = 12_345.6
        let changes = schedule.changes(after: start, seconds: 30)
        XCTAssertTrue(changes.allSatisfy { $0 > start })
        XCTAssertEqual(changes, changes.sorted())
        XCTAssertGreaterThanOrEqual(changes.last!, start + 30 - schedule.cellSeconds)
        // Between two listed moments the picture never changes.
        for (a, b) in zip(changes, changes.dropFirst()) {
            let mid = (a + b) / 2
            XCTAssertEqual(schedule.picture(at: a + 0.001), schedule.picture(at: mid))
        }
        // Every blink in the span starts at a listed moment.
        for blink in blinks(over: 25, from: start + 0.5) {
            XCTAssertTrue(changes.contains { abs($0 - blink.start) < 0.041 })
        }
    }
}

private extension IdleBlinkSchedule {
    /// First blink start of each cell.
    func starts(inCell cells: ClosedRange<Int>) -> [Double] { cells.map { starts(inCell: $0)[0] } }
}
