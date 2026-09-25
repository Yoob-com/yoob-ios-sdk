import XCTest
@testable import YoobRealistic

final class HostPathTests: XCTestCase {
    private let window = AvatarPack.CalmHostWindow.realistic

    /// The clip's head travel per step (px, `host_pose.json`) at the lane ends: the step inside the lane a turn reverses.
    private static let calmEndSteps: [Int: Double] = [103: 0.53, 125: 0.82, 319: 0.36, 373: 0.41, 1: 0.58, 9: 0.60, 202: 1.61, 259: 0.54]
    private static let speechEndSteps: [Int: Double] = [202: 1.61, 259: 0.54, 93: 0.31, 102: 0.69]

    /// The hosts of a walk from the call's start, or resumed from `start` (already on screen, as after a restart).
    private func walk(_ flags: [Bool], from start: Int? = nil) -> [Int] {
        var path = HostPath(window: window, startHost: start ?? window.pathStart, resuming: start != nil)
        return flags.map { path.next(speaking: $0) }
    }

    private var listed: Set<HostPath.Crossing> {
        Set(window.itinerary + window.speechItinerary + window.entries.map { HostPath.Crossing($0.key, $0.value) } + window.exits.map { HostPath.Crossing($0.key, $0.value) })
    }

    private func assertContinuous(_ hosts: [Int], file: StaticString = #filePath, line: UInt = #line) {
        for (a, b) in zip(hosts, hosts.dropFirst()) {
            XCTAssertNotEqual(a, b, "a held frame at \(a)", file: file, line: line)
            if abs(a - b) != 1 { XCTAssertTrue(listed.contains(HostPath.Crossing(a, b)), "a jump \(a) -> \(b) that is not a crossing", file: file, line: line) }
        }
    }

    private func turns(_ hosts: [Int]) -> [Int] {
        let moves = zip(hosts, hosts.dropFirst()).map { $1 - $0 }
        return zip(moves, moves.dropFirst()).enumerated().filter { abs($0.element.0) == 1 && abs($0.element.1) == 1 && $0.element.0 != $0.element.1 }.map { hosts[$0.offset + 1] }
    }

    func testSilenceWalksTheSilenceLanesWithoutAHeldFrame() {
        let hosts = walk(Array(repeating: false, count: 12_000))
        assertContinuous(hosts)
        XCTAssertTrue(hosts.allSatisfy(window.isCalm), "off the silence lanes in silence")
        for turn in turns(hosts) { XCTAssertNotNil(Self.calmEndSteps[turn], "a turn at \(turn), not a lane end") }
        XCTAssertTrue(window.closedLipLanes.flatMap { [$0.lowerBound, $0.upperBound] }.allSatisfy { Self.calmEndSteps[$0]! <= 0.85 }, "every closed-lip lane end is a slow step")
        for lane in window.closedLipLanes {
            let share = Double(hosts.filter(lane.contains).count) / Double(hosts.count)
            XCTAssertGreaterThan(share, 0.1, "lane \(lane) share \(share)"); XCTAssertLessThan(share, 0.6, "lane \(lane) share \(share)")
        }
        // Silence stays on her own closed-lip footage: the chin lift is speaking footage, and under the model's sealed mouth
        // her jaw and chin moved as in speech.
        XCTAssertTrue(hosts.allSatisfy(window.isClosedLips), "silence walks into the chin lift")
        XCTAssertGreaterThan(Set(zip(hosts, hosts.dropFirst()).filter { abs($0 - $1) > 1 }.map { HostPath.Crossing($0, $1) }).count, 3,
                             "silence still crosses between the closed-lip lanes")
        XCTAssertEqual(Array(hosts.prefix(8)), Array(331...338), "the call's first fade lands on twins of the idle face")
        XCTAssertTrue(hosts.prefix(8).allSatisfy(window.isHome))
        // The opening 300 frames do not come round inside the first minute.
        let opening = Array(hosts.prefix(300))
        XCTAssertNil((1..<1500).first { Array(hosts[$0..<($0 + 300)]) == opening })
    }

    func testTheOldSwitchStillWalksTheLiftInSilence() {
        HostPath.silenceEntersOpenLipLanes = true
        defer { HostPath.silenceEntersOpenLipLanes = false }
        let hosts = walk(Array(repeating: false, count: 12_000))
        assertContinuous(hosts)
        let lift = Double(hosts.filter { (202...259).contains($0) }.count) / Double(hosts.count)
        XCTAssertGreaterThan(lift, 0.15, "before 2026-09-25 the lift moved her head in silence: share \(lift)")
    }

    func testSilenceNeverEntersAnOpenLipLaneOfAnyFace() {
        // A test face whose only silence crossing leads into an open-lip lane (the pup's 345-354): silence turns at the
        // closed-lip lane's ends instead, and a silence that begins on the open-lip lane leaves it at its first exit.
        let pup = AvatarPack.CalmHostWindow(first: 80, count: 1, framesPerHost: 3, twins: [38...114], lanes: [38...114, 345...354],
                                            closedLipLanes: [38...114], itinerary: [.init(51, 349), .init(349, 65)], stays: [45, 70],
                                            openLipStays: [20], speechLanes: [38...122, 345...373], speechItinerary: [.init(114, 350), .init(349, 51)],
                                            speechStays: [60, 25], exits: [115: 114, 354: 51], pathStart: 60)
        var path = HostPath(window: pup, startHost: 60)
        let hosts = (0..<3000).map { _ in path.next(speaking: false) }
        XCTAssertTrue(hosts.allSatisfy { (38...114).contains($0) }, "silence left the closed-lip lane")
        XCTAssertTrue(zip(hosts, hosts.dropFirst()).allSatisfy { $0 != $1 && abs($0 - $1) == 1 }, "a held or jumping frame")
        XCTAssertTrue(hosts.contains(38) && hosts.contains(114), "the whole lane, turning at its ends")
        var onLift = HostPath(window: window, startHost: 240, resuming: true)
        let out = (0..<40).map { _ in onLift.next(speaking: false) }
        XCTAssertEqual(out.firstIndex(where: window.isClosedLips), 30, "a restart in silence on the lift leaves it at its first exit, down to 210 then out to 9: \(out)")
    }

    func testTheVoiceWalksTheSpeechLanesWhereSheTalksInTheFootage() {
        let hosts = walk(Array(repeating: true, count: 6000))
        assertContinuous(hosts)
        XCTAssertEqual(hosts.first, 259, "the start host 331 has an entry: the head joins the voice on its first frame")
        XCTAssertTrue(hosts.allSatisfy(window.isSpeech), "off the speech lanes while the voice plays")
        XCTAssertTrue(hosts.contains(228), "through the top of the chin lift")
        XCTAssertTrue(hosts.contains(93) && hosts.contains(202), "both speech lanes end to end")
        XCTAssertFalse(hosts.contains { window.isClosedLips($0) }, "never a closed-lip host while the voice plays")
        for turn in turns(hosts) { XCTAssertNotNil(Self.speechEndSteps[turn], "a turn at \(turn), not a lane end") }
        XCTAssertTrue(Self.speechEndSteps.values.allSatisfy { $0 <= 1.7 }, "every speech lane end is a gentle step (under the walk's median)")
        let lift = Double(hosts.filter { (202...259).contains($0) }.count) / Double(hosts.count)
        XCTAssertGreaterThan(lift, 0.6, "most of speech is on the chin lift: \(lift)")
        XCTAssertGreaterThan(zip(hosts, hosts.dropFirst()).filter { abs($0 - $1) > 1 }.count, 20, "crosses between the two speech lanes")
    }

    func testTheHeadJoinsTheVoiceAtTheFirstHostWithAnEntry() {
        // From a calm host with an entry the head crosses on the voice's first frame; from one without (319-322) it walks
        // on, at most four frames, to the first that has one (323).
        for (start, latest) in [(331, 0), (114, 0), (5, 0), (319, 2), (365, 1), (125, 1)] {
            let hosts = walk(Array(repeating: true, count: 20), from: start)
            let joined = hosts.firstIndex(where: window.isSpeech)
            XCTAssertNotNil(joined, "from \(start): \(hosts)"); XCTAssertLessThanOrEqual(joined ?? 99, latest, "from \(start) the head joins the voice at frame \(joined ?? 99): \(hosts)")
            assertContinuous([start] + hosts)
        }
    }

    func testTheHeadLeavesSpeechWithoutReversingAndLeavesTheLiftAtItsFirstExit() {
        // The voice stops half-way up the chin lift: the head walks on in silence, never turning back mid-gesture, and
        // once its stay is over leaves the lift at the first exit host for a closed-lip lane; in the talking-at-rest lane
        // it leaves at once.
        var path = HostPath(window: window, startHost: 331)
        var hosts: [Int] = []
        while path.host != 228 { hosts.append(path.next(speaking: true)); XCTAssertLessThan(hosts.count, 200) }
        let after = (0..<200).map { _ in path.next(speaking: false) }
        let left = after.firstIndex(where: window.isClosedLips)!
        XCTAssertTrue(after.prefix(left).allSatisfy { (202...259).contains($0) }, "on the lift until an exit: \(after)")
        XCTAssertNotNil(window.exits[after[left - 1]], "left through an exit host")
        XCTAssertTrue(after.dropFirst(left).allSatisfy(window.isCalm), "and stays in silence lanes: \(after)")
        assertContinuous(hosts + after)
        XCTAssertEqual(turns(hosts + after).filter { (203...258).contains($0) }, [], "no turn inside the lift")
        var talking = HostPath(window: window, startHost: 100, resuming: true)
        XCTAssertTrue(talking.speaking)
        XCTAssertTrue(window.isClosedLips(talking.next(speaking: false)), "the talking-at-rest lane exits on the first sealed frame")
        // A stall walk (settling) leaves the lift at once, at its first exit host.
        var stalled = HostPath(window: window, startHost: 240, resuming: true)
        let walk = (0..<60).map { _ in stalled.next(speaking: false, settling: true) }
        XCTAssertEqual(walk.firstIndex(where: window.isClosedLips), 30, "down to 210 then out to 9: \(walk)")
        var near = HostPath(window: window, startHost: 250, resuming: true)
        let short = (0..<60).map { _ in near.next(speaking: false, settling: true) }
        XCTAssertEqual(short.firstIndex(where: window.isClosedLips), 2, "down to 248 then out to 107: \(short)")
    }

    func testThePathIsAFunctionOfTheFramesAndTheLipsAlone() {
        let flags = (0..<3000).map { ($0 / 60) % 3 != 0 }
        XCTAssertEqual(walk(flags), walk(flags))
        var path = HostPath(window: window, startHost: 114)
        let before = path
        let ahead = path.ahead(6, speaking: [true, true, true, true, true, true])
        XCTAssertEqual(path, before, "looking ahead moves nothing")
        XCTAssertEqual(ahead, (0..<6).map { _ in path.next(speaking: true) })
        var restarted = HostPath(window: window, startHost: 230, resuming: true)
        XCTAssertFalse(restarted.speaking, "a restart on the chin lift carries on in silence until the lips unseal")
        XCTAssertEqual(restarted.next(speaking: true), 231, "the host on screen is not shown again")
        var fresh = HostPath(window: window, startHost: 340)
        XCTAssertEqual(fresh.next(speaking: false), 340, "a call's first frame is its start host")
        XCTAssertFalse(HostPath(window: window, startHost: 340).speaking)
        XCTAssertEqual(HostPath(window: window, startHost: 999).host, window.pathStart, "a host off every lane starts the path over")
    }

    func testAStallWalkReachesATwinOfTheIdleFaceFromAnywhere() {
        XCTAssertEqual(HostPath.stallLipsClosed(step: 0, frozen: 0), 0.25)
        XCTAssertEqual(HostPath.stallLipsClosed(step: 3, frozen: 0), 1)
        XCTAssertTrue(HostPath.holdsStalledSpeech(host: 206, lipsClosed: 0.5, window: window), "lips still open")
        XCTAssertTrue(HostPath.holdsStalledSpeech(host: 100, lipsClosed: 1, window: window), "not a home pose")
        XCTAssertFalse(HostPath.holdsStalledSpeech(host: 114, lipsClosed: 1, window: window))
        var worst = (0, 0)
        for lane in window.lanes + window.speechLanes {
            for start in lane {
                var path = HostPath(window: window, startHost: start, resuming: true)
                let steps = (1...HostPath.stallFramesLimit).first { _ in window.isHome(path.next(speaking: false, settling: true)) }
                XCTAssertNotNil(steps, "no twin within \(HostPath.stallFramesLimit) frames of host \(start)")
                if (steps ?? 0) > worst.1 { worst = (start, steps ?? 0) }
            }
        }
        XCTAssertLessThanOrEqual(worst.1, 50, "worst walk to a twin \(worst.1) frames from host \(worst.0), of \(HostPath.stallFramesLimit) allowed")
    }
}
