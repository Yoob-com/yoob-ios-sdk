import Foundation

/// When the still idle face blinks. Time is cut into 4.5 s cells; each cell holds one blink starting 0.75-2.25 s into it,
/// so consecutive blinks are 3-6 s apart, and about one in seven is a double blink. A pure function of time: the idle view
/// needs no state, and the same moment always shows the same picture.
public struct IdleBlinkSchedule: Equatable, Sendable {
    /// Blink picture for each 40 ms step of one blink (indices into the blink pictures).
    public let sequence: [Int]
    public var stepSeconds = 0.04
    public var cellSeconds = 4.5
    public var earliestStart = 0.75
    public var latestStart = 2.25
    public var doubleBlinkChance = 0.15
    /// Open-eye steps between the two blinks of a double blink.
    public var doubleBlinkGapSteps = 3
    public var seed: UInt64 = 0x5EED_B11E

    public init(sequence: [Int]) { self.sequence = sequence }

    public var blinkSeconds: Double { Double(sequence.count) * stepSeconds }

    /// Start times of the blinks in cell `index`.
    public func starts(inCell index: Int) -> [TimeInterval] {
        let cellStart = Double(index) * cellSeconds
        let first = cellStart + earliestStart + (latestStart - earliestStart) * unit(index, 0)
        guard unit(index, 1) < doubleBlinkChance else { return [first] }
        return [first, first + blinkSeconds + Double(doubleBlinkGapSteps) * stepSeconds]
    }

    /// The blink picture to show at `time` (seconds on any fixed clock), or nil for the open-eyed face.
    ///
    /// A blink that began before `resumeAfter` is skipped whole, eyes open. The call screen sets that moment to the end of
    /// an idle crossfade: a half-drawn blink blended with the open-eyed speaking frame reads as a translucent eyelid, and
    /// cutting a blink short mid-sequence would snap the eyes open. The schedule itself is not moved, so the next blink
    /// keeps its natural place.
    public func picture(at time: TimeInterval, resumeAfter: TimeInterval = -.infinity) -> Int? {
        guard !sequence.isEmpty, time.isFinite else { return nil }
        let cell = Int((time / cellSeconds).rounded(.down))
        for start in starts(inCell: cell) where time >= start && !(start < resumeAfter) {
            let step = Int(((time - start) / stepSeconds).rounded(.down))
            if step < sequence.count { return sequence[step] }
        }
        return nil
    }

    /// Whether a blink begins within `step` seconds from `time`: on a clock stepping by `step` (the call's 40 ms frames),
    /// exactly one step answers true for each scheduled blink.
    public func blinkStarts(at time: TimeInterval, step: TimeInterval) -> Bool {
        guard !sequence.isEmpty, time.isFinite, step > 0 else { return false }
        let cell = Int((time / cellSeconds).rounded(.down))
        return starts(inCell: cell).contains { time >= $0 && time - $0 < step }
    }

    /// The moments after `time` at which the picture changes, in order, covering at least `seconds`.
    public func changes(after time: TimeInterval, seconds: TimeInterval) -> [TimeInterval] {
        guard !sequence.isEmpty, time.isFinite else { return [] }
        var result: [TimeInterval] = []
        var cell = Int((time / cellSeconds).rounded(.down))
        while Double(cell) * cellSeconds <= time + seconds {
            for start in starts(inCell: cell) {
                for step in 0...sequence.count {
                    let moment = start + Double(step) * stepSeconds
                    if moment > time { result.append(moment) }
                }
            }
            cell += 1
        }
        return result
    }

    /// A uniform number in [0, 1) from the cell index (SplitMix64).
    private func unit(_ cell: Int, _ salt: UInt64) -> Double {
        var z = seed &+ UInt64(bitPattern: Int64(cell)) &* 0x9E37_79B9_7F4A_7C15 &+ salt &* 0xD1B5_4A32_D192_ED03
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}
