import XCTest
@testable import YoobRealistic

/// The renderer's crop sizes come from the pack's manifest (`CropGeometry`): the 144 model's must be the constants they
/// replaced, and the 288 model's (the 288 pup) the same layout at twice the size.
final class CropGeometryTests: XCTestCase {
    private let pup288 = CropGeometry(inner: 288, output: 576, outer: 608, hole: .init(x: 8, y: 8, width: 270, height: 260))

    private func manifest(inner: Int, output: Int, outer: Int, hole: [String: Int]?, feather: Int? = 8) throws -> AvatarManifest {
        var json: [String: Any] = ["version": 1, "identity": "test", "fps": 25, "sampleRate": 16000, "samplesPerFrame": 640,
            "encoderTailSamples": 80, "channelOrder": "BGR", "innerSize": inner, "outerSize": outer, "outputSize": output,
            "lookahead": 9, "leftContext": 16, "rightContext": 4, "bootstrap": 8, "waveformMean": 0, "waveformStd": 0.1,
            "sourceHostFrames": 0, "runtimeEncoder": "encoder_runtime.mlpackage", "encoderWindowFrames": [8], "frames": [], "files": [:]]
        if let hole { json["hole"] = hole }
        if let feather { json["featherPixels"] = feather }
        return try JSONDecoder().decode(AvatarManifest.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testTheManifestsOfBothModels() throws {
        let h08 = try XCTUnwrap(CropGeometry(manifest: manifest(inner: 144, output: 288, outer: 304,
                                                                hole: ["x": 4, "y": 4, "width": 135, "height": 130])))
        XCTAssertEqual(h08, .h08)
        XCTAssertEqual([h08.scale, h08.face, h08.margin, h08.outputBytes], [2, 152, 8, 288 * 288 * 3])
        XCTAssertEqual(h08.paste, .init(x: 8, y: 8, width: 270, height: 260), "the loop's rows 8..<268 and 270 columns from 8")
        XCTAssertEqual([h08.innerFile, h08.outerFile], ["inner144.bgr", "outer304.bgr"])
        let pup = try XCTUnwrap(CropGeometry(manifest: manifest(inner: 288, output: 576, outer: 608,
                                                                hole: ["x": 8, "y": 8, "width": 270, "height": 260])))
        XCTAssertEqual(pup, pup288)
        XCTAssertEqual([pup.scale, pup.face, pup.margin, pup.outputBytes], [2, 304, 16, 576 * 576 * 3])
        XCTAssertEqual(pup.paste, .init(x: 16, y: 16, width: 540, height: 520))
        XCTAssertEqual([pup.innerFile, pup.outerFile], ["inner288.bgr", "outer608.bgr"])
    }

    func testAManifestWithoutAHoleMustBeThe144One() throws {
        XCTAssertEqual(CropGeometry(manifest: try manifest(inner: 144, output: 288, outer: 304, hole: nil, feather: nil)), .h08)
        XCTAssertNil(CropGeometry(manifest: try manifest(inner: 288, output: 576, outer: 608, hole: nil)))
        XCTAssertNil(CropGeometry(manifest: try manifest(inner: 144, output: 288, outer: 304, hole: nil, feather: 12)),
                     "the compositor blends over 8 pixels only")
    }

    func testSizesThatDoNotNestAreRefused() {
        let hole = AvatarManifest.Rect(x: 4, y: 4, width: 135, height: 130)
        XCTAssertNil(CropGeometry(inner: 144, output: 300, outer: 304, hole: hole), "not a whole scale")
        XCTAssertNil(CropGeometry(inner: 144, output: 288, outer: 305, hole: hole), "outer not a whole number of input pixels")
        XCTAssertNil(CropGeometry(inner: 144, output: 288, outer: 280, hole: hole), "face crop smaller than the input")
        XCTAssertNil(CropGeometry(inner: 144, output: 288, outer: 302, hole: hole), "odd border: the input off centre")
        XCTAssertNil(CropGeometry(inner: 144, output: 288, outer: 304, hole: .init(x: 10, y: 4, width: 135, height: 130)), "hole outside")
        XCTAssertNil(CropGeometry(inner: 144, output: 288, outer: 304, hole: .init(x: 4, y: 4, width: 0, height: 130)), "empty hole")
        XCTAssertNotNil(CropGeometry(inner: 144, output: 144, outer: 152, hole: hole), "a model without upscaling nests too")
    }

    func testThePasteIsTheFixedLoopAt144AndTheScaledHoleAt288() throws {
        var generator = SystemRandomNumberGenerator()
        func noise(_ count: Int) -> Data { Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }) }
        // 144: the loop the geometry replaced, on the second of two hosts.
        let outer144 = noise(2 * 304 * 304 * 3), crop288 = noise(288 * 288 * 3)
        var expected = [UInt8](outer144[(304 * 304 * 3)..<(2 * 304 * 304 * 3)])
        for y in 8..<268 {
            let destination = ((y + 8) * 304 + 16) * 3, source = (y * 288 + 8) * 3
            expected.replaceSubrange(destination..<(destination + 270 * 3), with: crop288[source..<(source + 270 * 3)])
        }
        XCTAssertEqual(AvatarCompositor.pastedOuter(outer144, geometry: .h08, index: 1, cropBGR: crop288), expected)
        // 288: outer rows and columns 32..<552 and 32..<572 are the output's 16..<536 and 16..<556, the rest the host's.
        let geometry = try XCTUnwrap(pup288)
        let outer608 = noise(608 * 608 * 3), crop576 = noise(576 * 576 * 3)
        let pasted = AvatarCompositor.pastedOuter(outer608, geometry: geometry, index: 0, cropBGR: crop576)
        var mismatches = 0
        for y in 0..<608 {
            for x in 0..<608 {
                let inside = (32..<552).contains(y) && (32..<572).contains(x)
                for c in 0..<3 {
                    let want = inside ? crop576[((y - 16) * 576 + (x - 16)) * 3 + c] : outer608[(y * 608 + x) * 3 + c]
                    if pasted[(y * 608 + x) * 3 + c] != want { mismatches += 1 }
                }
            }
        }
        XCTAssertEqual(mismatches, 0)
        XCTAssertEqual(AvatarCompositor.pastedOuter(outer608, geometry: geometry, index: 0, cropBGR: Data()), [UInt8](outer608),
                       "no crop (silence on the host's own lips): the host's outer crop")
    }

    func testTheCropBufferHoldsTheAdmissionWindowAtAnySize() {
        XCTAssertEqual(StreamingAvatar.bufferedCrops(cropBytes: CropGeometry.h08.outputBytes), 150, "the 144 model's cap, unchanged")
        XCTAssertEqual(StreamingAvatar.bufferedCrops(cropBytes: 576 * 576 * 3), 125, "5 s of the 288 model's crops, ~124 MB")
        XCTAssertEqual(StreamingAvatar.bufferedCrops(cropBytes: 300 * 300 * 3), 138, "in between: ~37 MB of crops")
    }
}
