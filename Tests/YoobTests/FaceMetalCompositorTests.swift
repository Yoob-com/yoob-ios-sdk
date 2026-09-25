import XCTest
import Metal
@testable import YoobRealistic

/// The GPU compose must be the CPU loops' bytes exactly (`FaceMetalCompositor`).
final class FaceMetalCompositorTests: XCTestCase {
    func testTheGPUComposeMatchesTheCPULoopsByteForByte() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let metal = try XCTUnwrap(FaceMetalCompositor(), "the kernels compile")
        // The 144 model's 304 outer crop and the 288 model's 608 one.
        for outer in [304, 608] {
            let parity = try metal.selfCheck(outerSide: outer)
            XCTAssertGreaterThan(parity.comparedBytes, 0)
            XCTAssertEqual(parity.maxDifference, 0, "outer \(outer), differing bytes: \(parity.differingBytes)")
        }
        XCTAssertNotNil(FaceMetalCompositor.shared, "the process uses the GPU once the check passed")
    }

    func testTheGPUSharpeningMatchesTheCPUsByteForByte() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let metal = try XCTUnwrap(FaceMetalCompositor(), "the kernels compile")
        // The 144 model's geometry and the 288 one's (its 576 crop in a 608 outer crop), with the feather and with a matte.
        let b288 = try XCTUnwrap(CropGeometry(inner: 288, output: 576, outer: 608, hole: .init(x: 8, y: 8, width: 270, height: 260)))
        for geometry in [CropGeometry.h08, b288] {
            for matte in [false, true] {
                let parity = try metal.selfCheck(outerSide: geometry.outer, matte: matte, sharpen: geometry)
                XCTAssertGreaterThan(parity.comparedBytes, 0)
                XCTAssertEqual(parity.maxDifference, 0, "outer \(geometry.outer), matte \(matte), differing bytes: \(parity.differingBytes)")
            }
        }
    }

    func testEveryPackFaceSideFitsThe32BitSplitSums() {
        // The CPU's vertical sums need 64 bits (255 * (Σ|w|)^2 passes Int32.max); the kernel splits them into two 32-bit
        // sums, which must fit for every side near the realistic pack's (333...347) and the 288 pup's (400), from either
        // outer crop.
        for outer in [304, 608] {
            for side in 300...440 {
                let taps = LanczosTaps.shared.taps(sourceSide: outer, targetSide: side)
                let worst = (0..<side).map { row in taps.weights[(row * 8)..<(row * 8 + 8)].reduce(0) { $0 + abs($1) } }.max()!
                XCTAssertLessThanOrEqual((255 * worst / 2048 + 1) * worst, Int(Int32.max), "outer \(outer), side \(side)")
                XCTAssertLessThanOrEqual(2047 * worst + (1 << 21), Int(Int32.max), "outer \(outer), side \(side)")
            }
        }
    }
}
