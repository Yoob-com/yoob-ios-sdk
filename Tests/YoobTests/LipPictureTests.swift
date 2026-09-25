import XCTest
@testable import YoobRealistic

/// A face's finished lip picture (`LipPicture`): the crop's unsharp mask and the mouth region's paste matte.
final class LipPictureTests: XCTestCase {
    private func crop(side: Int, _ value: (Int, Int, Int) -> Int) -> Data {
        var data = Data(count: side * side * 3)
        for y in 0..<side { for x in 0..<side { for c in 0..<3 { data[(y * side + x) * 3 + c] = UInt8(value(x, y, c)) } } }
        return data
    }

    func testEachFaceGetsItsOwnLipPicture() {
        XCTAssertEqual(LipPicture.face(identity: "h08-development"), .luna)
        XCTAssertEqual(LipPicture.face(identity: "cartoon-pup-a144-leadfree"), .dog)
        XCTAssertNil(LipPicture.face(identity: "anime-f4-e124-test"), "the anime pack's own matte already does it")
        XCTAssertEqual(LipPicture.dog.sharpen, 0)
        XCTAssertNil(LipPicture.face(identity: "some-unmeasured-face"))
    }

    func testSharpeningLeavesFlatAndLinearPicturesAndAZeroAmountAlone() {
        let flat = crop(side: 16) { _, _, c in 40 + c * 50 }
        XCTAssertEqual(LipPicture.sharpened(flat, side: 16, amount: 0.9), flat)
        // A ramp along rows: the binomial blur of a linear run is the run itself away from the clamped edges.
        let ramp = crop(side: 16) { x, _, _ in 10 * x }
        let sharp = LipPicture.sharpened(ramp, side: 16, amount: 0.9)
        for y in 0..<16 { for x in 2..<14 { XCTAssertEqual(sharp[(y * 16 + x) * 3], ramp[(y * 16 + x) * 3]) } }
        let noise = crop(side: 12) { x, y, c in (x * 37 + y * 11 + c * 5) % 256 }
        XCTAssertEqual(LipPicture.sharpened(noise, side: 12, amount: 0), noise)
        XCTAssertEqual(LipPicture.sharpened(Data(count: 5), side: 12, amount: 0.9), Data(count: 5), "a crop of the wrong size is left alone")
    }

    func testSharpeningMatchesTheUnsharpMaskPixelByPixel() {
        let side = 9, source = crop(side: side) { x, y, c in (x * 53 + y * 29 + c * 71 + x * y * 7) % 256 }
        let amount: Float = 0.9, sharp = LipPicture.sharpened(source, side: side, amount: amount)
        let taps = [1, 4, 6, 4, 1]
        func at(_ x: Int, _ y: Int, _ c: Int) -> Int { Int(source[(min(max(y, 0), side - 1) * side + min(max(x, 0), side - 1)) * 3 + c]) }
        for y in 0..<side { for x in 0..<side { for c in 0..<3 {
            var sum = 0
            for (j, wy) in taps.enumerated() { for (i, wx) in taps.enumerated() { sum += wy * wx * at(x + i - 2, y + j - 2, c) } }
            let value = Float(at(x, y, c)), expected = UInt8(max(0, min(255, (value + amount * (value - Float(sum) / 256)).rounded(.toNearestOrEven))))
            XCTAssertEqual(sharp[(y * side + x) * 3 + c], expected, "(\(x), \(y), \(c))")
        } } }
        // An edge gains contrast: the dark side darker, the bright side brighter, clamped to bytes.
        let edge = crop(side: 16) { x, _, _ in x < 8 ? 60 : 200 }, sharpEdge = LipPicture.sharpened(edge, side: 16, amount: 0.9)
        XCTAssertLessThan(sharpEdge[(8 * 16 + 7) * 3], 60); XCTAssertGreaterThan(sharpEdge[(8 * 16 + 8) * 3], 200)
    }

    func testLunasMatteKeepsTheMouthTheModelsAndTheRestTheHosts() throws {
        let geometry = CropGeometry.h08, region = try XCTUnwrap(LipPicture.luna.mouth)
        for side in [333, 342, 347] {
            let matte = LipPicture.matte(region, geometry: geometry, side: side)
            XCTAssertEqual(matte.count, side * side)
            func at(cropX: Double, cropY: Double) -> UInt8 {
                // crop pixel -> outer pixel (+ margin) -> face square pixel
                let scale = Double(side) / Double(geometry.outer)
                let x = Int(((cropX + Double(geometry.margin)) + 0.5) * scale), y = Int(((cropY + Double(geometry.margin)) + 0.5) * scale)
                return matte[y * side + x]
            }
            XCTAssertEqual(at(cropX: 110, cropY: 95), 255, "the lips are the model's")
            XCTAssertEqual(at(cropX: 110, cropY: 175), 255, "the chin is the model's")
            XCTAssertEqual(at(cropX: 40, cropY: 110), 255, "the jaw line on the left is the model's")
            XCTAssertEqual(at(cropX: 200, cropY: 20), 0, "the cheek beside the nose is the host's")
            XCTAssertEqual(at(cropX: 270, cropY: 30), 0, "the right cheek's top is the host's")
            XCTAssertEqual(at(cropX: 260, cropY: 262), 0, "the neck's corner is the host's")
            for i in 0..<side {
                XCTAssertEqual(matte[i], 0); XCTAssertEqual(matte[(side - 1) * side + i], 0)
                XCTAssertEqual(matte[i * side], 0); XCTAssertEqual(matte[i * side + side - 1], 0)
            }
            let full = matte.filter { $0 == 255 }.count, none = matte.filter { $0 == 0 }.count
            XCTAssertGreaterThan(full, side * side / 4); XCTAssertGreaterThan(none, side * side / 5)
        }
        // The cache hands back the same bytes, and a different region rebuilds.
        let cache = LipMatteCache()
        XCTAssertEqual(cache.matte(region, geometry: geometry, side: 342), LipPicture.matte(region, geometry: geometry, side: 342))
        var wider = region; wider.radiusX *= 1.2
        XCTAssertEqual(cache.matte(wider, geometry: geometry, side: 342), LipPicture.matte(wider, geometry: geometry, side: 342))
        XCTAssertNotEqual(cache.matte(wider, geometry: geometry, side: 342), LipPicture.matte(region, geometry: geometry, side: 342))
    }

    /// The compose with a lip picture: host pixels where the matte is 0, the sharpened crop's square where it is 255, and
    /// without one the bytes of the plain compose (the matte and sharpening only apply when a face asks for them).
    func testTheComposeUsesTheMatteAndTheSharpenedCrop() throws {
        let geometry = CropGeometry.h08, region = try XCTUnwrap(LipPicture.luna.mouth), side = 342
        let outer = [UInt8]((0..<geometry.outerBytes).map { UInt8(truncatingIfNeeded: ($0 * 13) % 251) })
        let cropBGR = Data((0..<geometry.outputBytes).map { UInt8(truncatingIfNeeded: ($0 * 31) % 251) })
        let sharpened = LipPicture.sharpened(cropBGR, side: geometry.output, amount: 0.9)
        let matte = LipPicture.matte(region, geometry: geometry, side: side)
        let hostValue: UInt8 = 77, width = side + 20, rowBytes = width * 4
        func paste(_ crop: Data, matte: Data?) -> [UInt8] {
            var frame = [UInt8](repeating: hostValue, count: rowBytes * (side + 20))
            let face = AvatarCompositor.FaceSquare(outer: AvatarCompositor.pastedOuter(Data(outer), geometry: geometry, index: 0, cropBGR: crop),
                                                   outerSide: geometry.outer, x: 10, y: 10, side: side, mix: 0, matte: matte)
            frame.withUnsafeMutableBufferPointer { AvatarCompositor.pasteFace(face, into: $0, rowBytes: rowBytes) }
            return frame
        }
        let finished = paste(sharpened, matte: matte), plain = paste(sharpened, matte: nil)
        var host = 0, model = 0
        for y in 0..<side { for x in 0..<side {
            let pixel = (y + 10) * rowBytes + (x + 10) * 4
            switch matte[y * side + x] {
            case 0: XCTAssertEqual(finished[pixel], hostValue); host += 1
            case 255: XCTAssertEqual(finished[pixel], plain[pixel]); model += 1
            default: break
            }
        } }
        XCTAssertGreaterThan(host, 0); XCTAssertGreaterThan(model, 0)
        XCTAssertNotEqual(paste(cropBGR, matte: nil), plain, "sharpening changes the picture")
    }
}
