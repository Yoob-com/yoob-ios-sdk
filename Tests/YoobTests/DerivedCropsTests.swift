import CoreGraphics
import XCTest
@testable import YoobRealistic

/// The on-device crops must be the ones the pack tools make (cv2.resize INTER_AREA). References below are cv2's
/// output for the same formula images (python3.11, opencv 4).
final class DerivedCropsTests: XCTestCase {
    private func image(_ side: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: side * side * 3)
        for y in 0..<side { for x in 0..<side { for c in 0..<3 { out[(y * side + x) * 3 + c] = UInt8((x * x * 7 + y * 13 + c * 101 + x * y * 3) % 256) } } }
        return out
    }

    func testAreaResizeMatchesOpenCVExactly() {
        XCTAssertEqual(DerivedCrops.areaResize(image(11), side: 11, to: 4),
                       [24, 125, 207, 120, 149, 83, 136, 114, 122, 133, 115, 123, 67, 168, 98, 143, 129, 122, 114, 134, 121, 124, 141, 110,
                        110, 180, 56, 127, 108, 141, 121, 127, 118, 149, 109, 138, 153, 150, 99, 108, 127, 122, 124, 125, 154, 107, 121, 129])
        // The realistic pack's commonest face box (342) at both crop sizes, bit for bit. Other box sizes (333...347) differ
        // from cv2 in about 2 of 277k values by 1 (float rounding at .5), measured with a numpy port of this code.
        let references = [(342, 304, "43ff9fbe5016d1255029904fcdcc7fb911053e4f14216f70a1a057cc15d634d5"),
                          (342, 152, "e8c45c80fce4fdfdb827eff0a976a11abe7b0d3f51451ca8d637d534f0b48431")]
        for (side, size, sha) in references {
            XCTAssertEqual(DerivedCrops.digest(Data(DerivedCrops.areaResize(image(side), side: side, to: size))), sha, "\(side) -> \(size)")
        }
    }

    /// The 288 pup's outer crop is its 400 px face box upscaled to 608, which cv2's INTER_AREA runs as its own bilinear
    /// resize (`DerivedCrops.areaUpscale`). References: cv2 4.12 (python3.11) on the same formula images; the pup pack's
    /// `outer608.bgr` is cv2's output on its ffmpeg decode byte for byte.
    func testAreaUpscaleMatchesOpenCVExactly() {
        XCTAssertEqual(DerivedCrops.areaResize(image(3), side: 3, to: 5),
                       [0, 101, 202, 2, 103, 204, 7, 108, 209, 21, 122, 223, 28, 129, 230, 4, 105, 206, 7, 108, 209, 12, 113, 214, 27, 128,
                        229, 34, 135, 236, 13, 114, 215, 16, 117, 218, 23, 124, 225, 39, 140, 241, 47, 148, 249, 22, 123, 223, 25, 127, 228,
                        33, 135, 236, 51, 152, 139, 59, 161, 91, 26, 127, 228, 30, 131, 232, 39, 140, 241, 57, 158, 88, 66, 167, 12])
        let references = [(400, 608, "381c5e230b5b228185299d116ea81d49bd23fd91ddbcd4b33cc9f134bb80e61e"),
                          (333, 608, "ccba78dbb285fd063e6d9c138261ba003ac907d29e33d7150bfe3cad95784857"),
                          (7, 16, "f21054bc8d772607541d5eeac34cc3064d8d86ffd144336349659434bd4f5b97")]
        for (side, size, sha) in references {
            XCTAssertEqual(DerivedCrops.digest(Data(DerivedCrops.areaResize(image(side), side: side, to: size))), sha, "\(side) -> \(size)")
        }
    }

    /// OpenCV's area-mode bilinear kernel in integers, as `resize.cpp` runs it for 8-bit pictures (the vertical pass as
    /// `VResizeLinearVec_32s8u`), matched by the vector version on random pictures of the pup's and other sizes.
    func testAreaUpscaleMatchesTheIntegerKernel() {
        var generator = SystemRandomNumberGenerator()
        for (side, size) in [(400, 608), (333, 608), (401, 608), (152, 304), (5, 16), (1, 3)] {
            let pixels = (0..<(side * side * 3)).map { _ in UInt8.random(in: 0...255, using: &generator) }
            XCTAssertEqual(DerivedCrops.areaUpscale(pixels, side: side, to: size), Self.referenceUpscale(pixels, side: side, to: size),
                           "\(side) -> \(size)")
        }
    }

    static func referenceUpscale(_ pixels: [UInt8], side: Int, to size: Int) -> [UInt8] {
        let inverse = Double(size) / Double(side), scale = 1 / inverse
        var cells = [Int](), weights = [(Int32, Int32)]()
        for d in 0..<size {
            var cell = Int(floor(Double(d) * scale))
            var fraction = Float(Double(d + 1) - Double(cell + 1) * inverse)
            fraction = fraction <= 0 ? 0 : fraction - floor(fraction)
            if cell >= side - 1 { fraction = 0; cell = side - 1 }
            cells.append(cell)
            weights.append((Int32(((1 - fraction) * 2048).rounded(.toNearestOrEven)), Int32((fraction * 2048).rounded(.toNearestOrEven))))
        }
        let width = size * 3
        var horizontal = [Int32](repeating: 0, count: side * width)
        for y in 0..<side {
            for x in 0..<size {
                let cell = cells[x], next = min(cell + 1, side - 1)
                for c in 0..<3 {
                    horizontal[y * width + x * 3 + c] = Int32(pixels[(y * side + cell) * 3 + c]) * weights[x].0
                        + Int32(pixels[(y * side + next) * 3 + c]) * weights[x].1
                }
            }
        }
        var out = [UInt8](repeating: 0, count: size * width)
        for y in 0..<size {
            let first = cells[y] * width, second = min(cells[y] + 1, side - 1) * width
            for i in 0..<width {
                let sum = (((horizontal[first + i] >> 4) * weights[y].0) >> 16) + (((horizontal[second + i] >> 4) * weights[y].1) >> 16)
                out[y * width + i] = UInt8(clamping: (sum + 2) >> 2)
            }
        }
        return out
    }

    func testFaceBoxReadsBGRFromADecodedFrame() throws {
        // A 4x4 BGRA little-endian frame, as VideoToolbox hands it back, with a known pixel inside the box.
        var bytes = [UInt8](repeating: 0, count: 4 * 4 * 4)
        let at = (2 * 4 + 1) * 4
        bytes[at] = 10; bytes[at + 1] = 20; bytes[at + 2] = 30; bytes[at + 3] = 255 // B G R A
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let picture = CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let (box, side) = try DerivedCrops.faceBox(of: picture, bbox: [1, 1, 3, 3])
        XCTAssertEqual(side, 2)
        XCTAssertEqual(Array(box[3..<6]), [0, 0, 0])
        XCTAssertEqual(Array(box[6..<9]), [10, 20, 30], "row 1 col 0 of the box is frame pixel (1, 2), in BGR order")
        XCTAssertThrowsError(try DerivedCrops.faceBox(of: picture, bbox: [1, 1, 5, 5]), "a box outside the frame is refused")
    }

    /// With a finalized pack (YOOB_REALISTIC_PACK), crops rebuilt from its host video must stay close to the crops the
    /// tooling made (ffmpeg + cv2). They are not identical: the HEVC decode is bit-exact, but ffmpeg's YUV to BGR conversion
    /// is not VideoToolbox's (h08-v4, 2026-09-22: 44.9 dB inner / 44.5 dB outer). Against the lossless h08-v1 crops the
    /// VideoToolbox ones are the closer pair (44.1 vs 41.7 dB inner, 42.8 vs 40.8 dB outer; ffmpeg's are ~1.5 levels
    /// darker), and they match the host frame the compositor paints them over. The cartoon pup's saturated colours convert
    /// further apart (2026-09-24: A144 42.6 / 41.9 dB, B288 42.0 / 40.9 dB); from the same decoded boxes, the resizes here
    /// give B288's crops byte for byte.
    func testDerivedCropsMatchTheFinalizedPack() throws {
        guard let path = ProcessInfo.processInfo.environment["YOOB_REALISTIC_PACK"] else { throw XCTSkip("no pack") }
        let root = URL(fileURLWithPath: path)
        let manifest = try JSONDecoder().decode(AvatarManifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        guard manifest.videoContainer == true, let file = manifest.frames.first?.file else { throw XCTSkip("not a video pack") }
        let geometry = try XCTUnwrap(CropGeometry(manifest: manifest))
        let video = HostVideoDecoder(url: root.appendingPathComponent(file), keyframeInterval: manifest.videoKeyframeInterval ?? 15,
                                     frameCount: manifest.frames.count, frameRate: manifest.fps)
        let started = Date()
        let crops = try DerivedCrops.derive(frames: manifest.frames, geometry: geometry) { try video.image(forVideoFrame: $0) }
        let seconds = Date().timeIntervalSince(started)
        if let out = ProcessInfo.processInfo.environment["DERIVED_CROPS_OUT"] {
            try crops.inner.write(to: URL(fileURLWithPath: out).appendingPathComponent(geometry.innerFile))
            try crops.outer.write(to: URL(fileURLWithPath: out).appendingPathComponent(geometry.outerFile))
        }
        for (name, derived) in [(geometry.innerFile, crops.inner), (geometry.outerFile, crops.outer)] {
            let shipped = try Data(contentsOf: root.appendingPathComponent(name))
            XCTAssertEqual(derived.count, shipped.count)
            var maxDiff = 0, squared = 0.0, exact = 0
            derived.withUnsafeBytes { a in shipped.withUnsafeBytes { b in
                for i in 0..<min(a.count, b.count) {
                    let d = abs(Int(a[i]) - Int(b[i])); maxDiff = max(maxDiff, d); squared += Double(d * d); if d == 0 { exact += 1 }
                }
            } }
            let mse = squared / Double(max(1, derived.count)), psnr = mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
            print("\(name): exact \(Double(exact) / Double(derived.count)), max diff \(maxDiff), PSNR \(psnr) dB, derive \(seconds) s")
            XCTAssertGreaterThan(psnr, 40, name)
        }
    }
}
