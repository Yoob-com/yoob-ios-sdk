import XCTest
import Metal
@testable import YoobRealistic

/// The anime's steady paste as per-pack options (`AvatarManifest.Paste`): the paste matte in the compositor (CPU and Metal)
/// and the steady filter on the model's crops (`SteadyFilter`); and a test face's calm window read from JSON.
final class SteadyPasteTests: XCTestCase {
    private let geometry = CropGeometry(inner: 288, output: 576, outer: 608, hole: .init(x: 8, y: 8, width: 270, height: 260))!

    func testTheMatteKeepsTheHostAtZeroTakesTheSquareAt255AndBlendsBetween() {
        var generator = SystemRandomNumberGenerator()
        let side = 40, outerSide = 60, width = 100, height = 80, rowBytes = width * 4
        let outer = (0..<(outerSide * outerSide * 3)).map { _ in UInt8.random(in: 0...255, using: &generator) }
        let host = [UInt8]((0..<(rowBytes * height)).map { $0 % 4 == 3 ? 255 : UInt8.random(in: 0...255, using: &generator) })
        let up = AvatarCompositor.resizeLanczos4(outer, sourceSide: outerSide, targetSide: side)
        // Rows of the square: 0 (host), 255 (model), 128 (between).
        let matte = Data((0..<(side * side)).map { index -> UInt8 in [0, 255, 128][(index / side) % 3] })
        for mix in [Float(0), 0.5] {
            let face = AvatarCompositor.FaceSquare(outer: outer, outerSide: outerSide, x: 30, y: 20, side: side, mix: mix, matte: matte)
            var frame = host
            frame.withUnsafeMutableBufferPointer { AvatarCompositor.pasteFace(face, into: $0, rowBytes: rowBytes) }
            for y in 0..<side {
                for x in 0..<side {
                    for c in 0..<3 {
                        let pixel = (20 + y) * rowBytes + (30 + x) * 4 + c, source = (y * side + x) * 3 + c
                        let alpha = Float([0, 255, 128][y % 3]) / 255 * (1 - mix)
                        let expected = UInt8((alpha * Float(up[source]) + (1 - alpha) * Float(host[pixel])).rounded(.toNearestOrEven))
                        XCTAssertEqual(frame[pixel], expected, "row \(y) mix \(mix)")
                    }
                }
            }
            // Outside the square the frame is untouched.
            XCTAssertEqual(frame[0..<(20 * rowBytes)], host[0..<(20 * rowBytes)])
        }
    }

    func testTheMattedGPUComposeMatchesTheCPULoopsByteForByte() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let metal = try XCTUnwrap(FaceMetalCompositor(), "the kernels compile")
        for outer in [304, 608] {
            let parity = try metal.selfCheck(outerSide: outer, matte: true)
            XCTAssertGreaterThan(parity.comparedBytes, 0)
            XCTAssertEqual(parity.maxDifference, 0, "outer \(outer), differing bytes: \(parity.differingBytes)")
        }
    }

    private func crop(_ value: (Int, Int, Int) -> UInt8) -> Data {
        let side = geometry.output
        var data = Data(count: side * side * 3)
        data.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for y in 0..<side { for x in 0..<side { for c in 0..<3 { bytes[(y * side + x) * 3 + c] = value(x, y, c) } } }
        }
        return data
    }

    func testTheSteadyFilterHoldsRedrawsAndPassesMotion() {
        let settings = AvatarManifest.Paste.Temporal(low: 3, high: 12, floor: 0.15, blur: 3, silenceEMA: 0.5)
        let filter = SteadyFilter(settings: settings, geometry: geometry), box = [100, 200, 480, 580]
        let first = crop { x, y, c in UInt8((x + 2 * y + 40 * c) % 200) }
        XCTAssertEqual(filter.filter(first, box: box, silence: 0), first, "the first crop passes as it is")
        XCTAssertEqual(filter.filter(first, box: box, silence: 0), first, "an identical crop in the same box changes nothing")
        // A redraw of 2 grey levels everywhere: under the gate, so held at the floor weight.
        let redrawn = crop { x, y, c in UInt8((x + 2 * y + 40 * c) % 200 + 2) }
        let held = filter.filter(redrawn, box: box, silence: 0)
        XCTAssertEqual(filter.lastWeight, 0.15, accuracy: 1e-6)
        XCTAssertEqual(Int(held[1000]), Int(first[1000]), "2 x 0.15 rounds back to the previous value")
        // Real motion (40 grey levels): passes whole.
        let moved = crop { x, y, c in UInt8((x + 2 * y + 40 * c) % 200 + 40) }
        XCTAssertEqual(filter.filter(moved, box: box, silence: 0), moved)
        XCTAssertEqual(filter.lastWeight, 1)
        // A reset (a frame the model did not draw) starts afresh.
        filter.reset()
        XCTAssertEqual(filter.filter(redrawn, box: box, silence: 0), redrawn)
    }

    func testTheSteadyFilterFollowsTheBox() {
        let settings = AvatarManifest.Paste.Temporal(low: 3, high: 12, floor: 0.15, blur: 3, silenceEMA: nil)
        let filter = SteadyFilter(settings: settings, geometry: geometry)
        // A picture fixed in the frame, seen through two boxes 5 frame pixels apart (the crop's scale is 608 / 380): the
        // second crop is the first moved by 8 output pixels. Aligned, the previous crop matches it, so nothing is held back.
        let side = 380.0
        func seen(from x0: Int) -> Data {
            crop { x, y, _ in
                let frameX = Double(x0) + (Double(x) + 16.5) * side / 608 - 0.5
                return UInt8(max(0, min(255, 128 + 100 * sin(frameX / 23) * cos(Double(y) / 31))))
            }
        }
        _ = filter.filter(seen(from: 100), box: [100, 200, 480, 580], silence: 0)
        _ = filter.filter(seen(from: 105), box: [105, 200, 485, 580], silence: 0)
        XCTAssertEqual(filter.lastWeight, 0.15, accuracy: 0.05, "the aligned previous crop is the same picture: nothing moved")
    }

    func testACalmWindowReadFromJSONIsTheInitializersWindow() throws {
        let realistic = AvatarPack.CalmHostWindow.realistic
        func ranges(_ values: [ClosedRange<Int>]) -> [[Int]] { values.map { [$0.lowerBound, $0.upperBound] } }
        let json: [String: Any] = [
            "_doc": "ignored", "first": realistic.first, "count": realistic.count, "framesPerHost": realistic.framesPerHost,
            "twins": ranges(realistic.twins), "blinkHosts": ranges(realistic.blinkHosts),
            "closedEyes": [realistic.closedEyes!.lowerBound, realistic.closedEyes!.upperBound], "lanes": ranges(realistic.lanes),
            "closedLipLanes": ranges(realistic.closedLipLanes), "itinerary": realistic.itinerary.map { [$0.from, $0.to] },
            "stays": realistic.stays, "openLipStays": realistic.openLipStays, "speechLanes": ranges(realistic.speechLanes),
            "speechItinerary": realistic.speechItinerary.map { [$0.from, $0.to] }, "speechStays": realistic.speechStays,
            "entries": Dictionary(uniqueKeysWithValues: realistic.entries.map { (String($0.key), $0.value) }),
            "exits": Dictionary(uniqueKeysWithValues: realistic.exits.map { (String($0.key), $0.value) }),
            "pathStart": realistic.pathStart, "pathStartRising": realistic.pathStartRising]
        let decoded = try XCTUnwrap(AvatarPack.CalmHostWindow(json: JSONSerialization.data(withJSONObject: json)))
        XCTAssertEqual(decoded, realistic)
        // Malformed: a range upside down, a crossing of three hosts, a host key that is not a number.
        for broken: [String: Any] in [["lanes": [[5, 1]]], ["itinerary": [[1, 2, 3]]], ["exits": ["x": 3]]] {
            let bad = json.merging(broken) { $1 }
            XCTAssertNil(AvatarPack.CalmHostWindow(json: try JSONSerialization.data(withJSONObject: bad)))
        }
    }
}
