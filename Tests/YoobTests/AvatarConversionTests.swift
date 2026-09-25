import XCTest
@testable import YoobRealistic

/// The vectorized renderer input and output conversions give the same values as the per-element loops they replaced.
final class AvatarConversionTests: XCTestCase {
    func testRendererImageMatchesThePerPixelLoop() {
        // The 144 model's hole as the loop hard-coded it (x 4..<139, y 4..<134), and the 288 model's, twice as large.
        for (geometry, xs, ys) in [(CropGeometry.h08, 4..<139, 4..<134),
                                   (CropGeometry(inner: 288, output: 576, outer: 608, hole: .init(x: 8, y: 8, width: 270, height: 260))!, 8..<278, 8..<268)] {
            var generator = SystemRandomNumberGenerator()
            let side = geometry.inner, plane = side * side
            let reference = (0..<(plane * 3)).map { _ in UInt8.random(in: 0...255, using: &generator) }
            let masked = (0..<(plane * 3)).map { _ in UInt8.random(in: 0...255, using: &generator) }
            var expected = [Float](repeating: -1, count: plane * 6)
            for y in 0..<side {
                for x in 0..<side {
                    let pixel = y * side + x, hole = xs.contains(x) && ys.contains(y)
                    for channel in 0..<3 {
                        expected[channel * plane + pixel] = Float(reference[pixel * 3 + channel]) / 255
                        expected[(channel + 3) * plane + pixel] = hole ? 0 : Float(masked[pixel * 3 + channel]) / 255
                    }
                }
            }
            var actual = [Float](repeating: -1, count: plane * 6)
            actual.withUnsafeMutableBufferPointer { out in
                AvatarModels.fillRendererImage(out.baseAddress!, reference: reference, masked: masked, geometry: geometry)
            }
            XCTAssertEqual(actual.map(\.bitPattern), expected.map(\.bitPattern), "inner \(side)")
        }
    }

    func testCropBytesMatchThePerElementLoop() {
        for side in [288, 576] { checkCropBytes(side: side) }
    }

    private func checkCropBytes(side: Int) {
        let count = side * side
        // Model outputs in and out of range, and values on and next to byte boundaries.
        var values = (0..<(count * 3)).map { index -> Float in
            switch index % 7 {
            case 0: return Float(index % 256) / 255
            case 1: return Float(index % 256) / 255 + 1e-7
            case 2: return -Float(index % 5) * 0.01
            case 3: return 1 + Float(index % 5) * 0.01
            default: return Float.random(in: -0.1...1.1)
            }
        }
        values[0] = 0; values[1] = 1; values[2] = -0; values[3] = 0.99999994
        var expected = [UInt8](repeating: 0, count: count * 3)
        for pixel in 0..<count {
            for channel in 0..<3 { expected[pixel * 3 + channel] = UInt8(max(0, min(255, values[channel * count + pixel] * 255))) }
        }
        let actual = values.withUnsafeBufferPointer { AvatarModels.bgrBytes(planar: $0.baseAddress!, side: side) }
        XCTAssertEqual([UInt8](actual), expected, "output \(side)")
    }
}
