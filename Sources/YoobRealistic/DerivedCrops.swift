import Accelerate
import CoreGraphics
import CryptoKit
import Foundation

/// The renderer's per-host BGR crops (`inner144.bgr`, `outer304.bgr` at the 144 geometry), rebuilt on the device from the
/// pack's own host video instead of shipping 121 MB of raw pixels in the app. Same semantics as the pack tools: crop
/// the host frame to its face box, area-resize it to the outer size (304) and to the face size (152) whose centred inner
/// size (144) is the inner crop (`CropGeometry`). The decode is the VideoToolbox one that already paints the host frame
/// under the rendered mouth, so crop and host always agree. The result is written once to Caches, keyed by the manifest
/// hash, and memory-mapped on later launches.
enum DerivedCrops {
    struct Output { let inner: Data; let outer: Data }

    /// Cached crops for this pack when present and intact; otherwise derives, caches (best effort) and returns them.
    static func load(manifest: AvatarManifest, manifestHash: String, geometry: CropGeometry, cacheRoot: URL? = defaultCacheRoot,
                     image: (Int) throws -> CGImage) throws -> Output {
        let count = manifest.frames.count
        let innerBytes = count * geometry.innerBytes, outerBytes = count * geometry.outerBytes
        let directory = cacheRoot?.appendingPathComponent(manifestHash, isDirectory: true)
        if let directory, let cached = cached(in: directory, geometry: geometry, innerBytes: innerBytes, outerBytes: outerBytes) { return cached }
        let output = try derive(frames: manifest.frames, geometry: geometry, image: image)
        if let directory { store(output, geometry: geometry, in: directory) }
        return output
    }

    static var defaultCacheRoot: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("Yoob/Crops", isDirectory: true)
    }

    static func derive(frames: [AvatarManifest.HostFrame], geometry: CropGeometry, image: (Int) throws -> CGImage) throws -> Output {
        let inner = geometry.inner, face = geometry.face, outer = geometry.outer
        var innerData = Data(count: frames.count * inner * inner * 3)
        var outerData = Data(count: frames.count * outer * outer * 3)
        for (index, frame) in frames.enumerated() {
            let picture = try image(index)
            let (box, side) = try faceBox(of: picture, bbox: frame.bbox)
            let outerCrop = areaResize(box, side: side, to: outer)
            let faceCrop = areaResize(box, side: side, to: face)
            outerData.replaceSubrange((index * outer * outer * 3)..<((index + 1) * outer * outer * 3), with: outerCrop)
            let border = (face - inner) / 2
            var innerCrop = [UInt8](repeating: 0, count: inner * inner * 3)
            for row in 0..<inner {
                let from = ((row + border) * face + border) * 3
                innerCrop.replaceSubrange((row * inner * 3)..<((row + 1) * inner * 3), with: faceCrop[from..<(from + inner * 3)])
            }
            innerData.replaceSubrange((index * inner * inner * 3)..<((index + 1) * inner * inner * 3), with: innerCrop)
        }
        return Output(inner: innerData, outer: outerData)
    }

    /// The face box of a decoded host frame as packed BGR, read straight from the decoded bytes (no colour conversion).
    @_optimize(speed)
    static func faceBox(of image: CGImage, bbox: [Int]) throws -> ([UInt8], Int) {
        guard bbox.count == 4, bbox[2] - bbox[0] == bbox[3] - bbox[1], bbox[0] >= 0, bbox[1] >= 0,
              bbox[2] <= image.width, bbox[3] <= image.height, bbox[2] > bbox[0],
              image.bitsPerPixel == 32, image.bitsPerComponent == 8,
              let data = image.dataProvider?.data, let base = CFDataGetBytePtr(data) else { throw AvatarError.invalidPack("host crop") }
        // Channel offsets inside one 32-bit pixel for the layouts VideoToolbox and ImageIO hand back.
        let info = image.bitmapInfo, alpha = image.alphaInfo
        let little = info.contains(.byteOrder32Little)
        let alphaFirst = alpha == .premultipliedFirst || alpha == .first || alpha == .noneSkipFirst
        let (r, g, b): (Int, Int, Int)
        switch (little, alphaFirst) {
        case (true, true): (r, g, b) = (2, 1, 0)   // BGRA in memory
        case (true, false): (r, g, b) = (3, 2, 1)  // ABGR
        case (false, true): (r, g, b) = (1, 2, 3)  // ARGB
        case (false, false): (r, g, b) = (0, 1, 2) // RGBA
        }
        let side = bbox[2] - bbox[0], rowBytes = image.bytesPerRow
        guard CFDataGetLength(data) >= (bbox[3] - 1) * rowBytes + bbox[2] * 4 else { throw AvatarError.invalidPack("host crop") }
        var out = [UInt8](repeating: 0, count: side * side * 3)
        out.withUnsafeMutableBufferPointer { dst in
            for y in 0..<side {
                let row = base + (bbox[1] + y) * rowBytes + bbox[0] * 4
                for x in 0..<side {
                    let pixel = row + x * 4, o = (y * side + x) * 3
                    dst[o] = pixel[b]; dst[o + 1] = pixel[g]; dst[o + 2] = pixel[r]
                }
            }
        }
        return (out, side)
    }

    /// One axis of OpenCV's INTER_AREA table (`computeResizeAreaTab`): source index and weight per destination pixel.
    static func areaTable(source: Int, destination: Int) -> [[(Int, Float)]] {
        let scale = Double(source) / Double(destination)
        return (0..<destination).map { d in
            let from = Double(d) * scale, to = from + scale
            let first = Int(ceil(from)), last = Int(floor(to))
            let cell = min(scale, Double(source) - from)
            var taps: [(Int, Float)] = []
            if Double(first) - from > 1e-3, first - 1 >= 0 { taps.append((first - 1, Float((Double(first) - from) / cell))) }
            for s in first..<min(last, source) { taps.append((s, Float(1 / cell))) }
            if to - Double(last) > 1e-3, last < source { taps.append((last, Float(min(min(to - Double(last), 1), cell) / cell))) }
            return taps
        }
    }

    /// Area-averaged downscale of a packed square BGR image (cv2.resize INTER_AREA, rounded to nearest). The weighted sums
    /// run as vDSP vector multiply-adds (a column or a row at a time), so a developer build's first face load is fast too.
    /// A larger `size` is cv2's INTER_AREA upscale (`areaUpscale`): the 288 pup's 400 px face boxes to its 608 outer crop.
    static func areaResize(_ pixels: [UInt8], side: Int, to size: Int) -> [UInt8] {
        if size > side { return areaUpscale(pixels, side: side, to: size) }
        let table = areaTable(source: side, destination: size)
        var source = [Float](repeating: 0, count: pixels.count)
        vDSP_vfltu8(pixels, 1, &source, 1, vDSP_Length(pixels.count))
        // Horizontal pass: output column x of channel c is the weighted sum of source columns, over all rows at once.
        var horizontal = [Float](repeating: 0, count: side * size * 3)
        source.withUnsafeBufferPointer { src in
            horizontal.withUnsafeMutableBufferPointer { h in
                for (x, taps) in table.enumerated() {
                    for c in 0..<3 {
                        let out = h.baseAddress! + x * 3 + c
                        for (s, w) in taps {
                            var weight = w
                            vDSP_vsma(src.baseAddress! + s * 3 + c, vDSP_Stride(side * 3), &weight, out, vDSP_Stride(size * 3),
                                      out, vDSP_Stride(size * 3), vDSP_Length(side))
                        }
                    }
                }
            }
        }
        // Vertical pass: output row y is the weighted sum of whole (contiguous, interleaved) rows.
        var result = [Float](repeating: 0, count: size * size * 3)
        horizontal.withUnsafeBufferPointer { h in
            result.withUnsafeMutableBufferPointer { r in
                for (y, taps) in table.enumerated() {
                    let out = r.baseAddress! + y * size * 3
                    for (s, w) in taps {
                        var weight = w
                        vDSP_vsma(h.baseAddress! + s * size * 3, 1, &weight, out, 1, out, 1, vDSP_Length(size * 3))
                    }
                }
            }
        }
        // Round half away from zero (then clamp), as the scalar reference did.
        var half: Float = 0.5, low: Float = 0, high: Float = 255
        vDSP_vsadd(result, 1, &half, &result, 1, vDSP_Length(result.count))
        vDSP_vclip(result, 1, &low, &high, &result, 1, vDSP_Length(result.count))
        var out = [UInt8](repeating: 0, count: result.count)
        vDSP_vfixu8(result, 1, &out, 1, vDSP_Length(result.count)) // truncates toward zero
        return out
    }

    /// cv2.resize INTER_AREA to a larger size of a packed square BGR image. OpenCV runs it as a bilinear resize with its own
    /// "area" weights (`resize.cpp`, area_mode): output pixel d reads source cell floor(d * side / size) and the next, with
    /// fraction ((d + 1) - (cell + 1) * size / side) mod 1 in Float, as 11-bit weights (rounded half to even). The horizontal
    /// pass sums in integers; the vertical one is computed as OpenCV's vector kernel computes it (`VResizeLinearVec_32s8u`:
    /// each row sum shifted right 4, times its weight, the high 16 bits of each product summed, shifted right 2 rounding),
    /// which the packs' opencv-python ran for every byte (its scalar formula rounds differently in about one byte in ten).
    /// Both passes run as vDSP vector operations on values they hold exactly (horizontal sums under 2^24 in Float, the
    /// vertical products under 2^27 in Double, powers of two for the shifts), so a developer build derives the 288 pup's
    /// crops in seconds rather than minutes. Bit-exact with opencv-python 4.12 and the integer kernel (`DerivedCropsTests`).
    static func areaUpscale(_ pixels: [UInt8], side: Int, to size: Int) -> [UInt8] {
        let inverse = Double(size) / Double(side), scale = 1 / inverse
        // One table for both axes: first source pixel and the two weights per output pixel. The last cell's fraction is 0,
        // so reading the clamped next pixel there adds nothing, as OpenCV's edge case does.
        let taps: [(cell: Int, next: Int, w0: Float, w1: Float)] = (0..<size).map { d in
            let cell = min(side - 1, Int((Double(d) * scale).rounded(.down)))
            var fraction = Float(Double(d + 1) - Double(cell + 1) * inverse)
            fraction = fraction <= 0 ? 0 : fraction - fraction.rounded(.down)
            return (cell, min(cell + 1, side - 1), ((1 - fraction) * 2048).rounded(.toNearestOrEven),
                    (fraction * 2048).rounded(.toNearestOrEven))
        }
        let rowWidth = size * 3, count = side * rowWidth
        var source = [Float](repeating: 0, count: pixels.count)
        vDSP_vfltu8(pixels, 1, &source, 1, vDSP_Length(pixels.count))
        // Horizontal pass: output column x of channel c over all rows at once, byte x weight + byte x weight (under 2^24).
        var horizontal = [Float](repeating: 0, count: count)
        source.withUnsafeBufferPointer { src in
            horizontal.withUnsafeMutableBufferPointer { h in
                for (x, tap) in taps.enumerated() {
                    for c in 0..<3 {
                        let out = h.baseAddress! + x * 3 + c
                        var w0 = tap.w0, w1 = tap.w1
                        vDSP_vsmul(src.baseAddress! + tap.cell * 3 + c, vDSP_Stride(side * 3), &w0, out, vDSP_Stride(rowWidth), vDSP_Length(side))
                        vDSP_vsma(src.baseAddress! + tap.next * 3 + c, vDSP_Stride(side * 3), &w1, out, vDSP_Stride(rowWidth),
                                  out, vDSP_Stride(rowWidth), vDSP_Length(side))
                    }
                }
            }
        }
        // Each row sum shifted right 4, once: floor(sum / 16).
        var shifted = [Double](repeating: 0, count: count)
        var sixteenth = 1.0 / 16, total = Int32(count), width = Int32(rowWidth)
        shifted.withUnsafeMutableBufferPointer { q in
            vDSP_vspdp(horizontal, 1, q.baseAddress!, 1, vDSP_Length(count))
            vDSP_vsmulD(q.baseAddress!, 1, &sixteenth, q.baseAddress!, 1, vDSP_Length(count))
            vvfloor(q.baseAddress!, q.baseAddress!, &total)
        }
        // Vertical pass per output row: floor(q0 w0 / 2^16) + floor(q1 w1 / 2^16), then floor((t + 2) / 4), clamped.
        var out = [UInt8](repeating: 0, count: size * rowWidth)
        var first = [Double](repeating: 0, count: rowWidth), second = [Double](repeating: 0, count: rowWidth)
        var two = 2.0, quarter = 0.25, low = 0.0, high = 255.0
        shifted.withUnsafeBufferPointer { q in
            first.withUnsafeMutableBufferPointer { first in
                second.withUnsafeMutableBufferPointer { second in
                    out.withUnsafeMutableBufferPointer { out in
                        let n = vDSP_Length(rowWidth), sum = first.baseAddress!, other = second.baseAddress!
                        for (y, tap) in taps.enumerated() {
                            var s0 = Double(tap.w0) / 65536, s1 = Double(tap.w1) / 65536
                            vDSP_vsmulD(q.baseAddress! + tap.cell * rowWidth, 1, &s0, sum, 1, n); vvfloor(sum, sum, &width)
                            vDSP_vsmulD(q.baseAddress! + tap.next * rowWidth, 1, &s1, other, 1, n); vvfloor(other, other, &width)
                            vDSP_vaddD(sum, 1, other, 1, sum, 1, n)
                            vDSP_vsaddD(sum, 1, &two, sum, 1, n)
                            vDSP_vsmulD(sum, 1, &quarter, sum, 1, n); vvfloor(sum, sum, &width)
                            vDSP_vclipD(sum, 1, &low, &high, sum, 1, n)
                            vDSP_vfixu8D(sum, 1, out.baseAddress! + y * rowWidth, 1, n)
                        }
                    }
                }
            }
        }
        return out
    }

    private static func cached(in directory: URL, geometry: CropGeometry, innerBytes: Int, outerBytes: Int) -> Output? {
        let innerName = geometry.innerFile, outerName = geometry.outerFile
        guard let receipt = try? Data(contentsOf: directory.appendingPathComponent("receipt.json")),
              let sums = try? JSONDecoder().decode([String: String].self, from: receipt),
              let innerData = try? Data(contentsOf: directory.appendingPathComponent(innerName), options: .mappedIfSafe),
              let outerData = try? Data(contentsOf: directory.appendingPathComponent(outerName), options: .mappedIfSafe),
              innerData.count == innerBytes, outerData.count == outerBytes,
              sums[innerName] == digest(innerData), sums[outerName] == digest(outerData) else { return nil }
        return Output(inner: innerData, outer: outerData)
    }

    private static func store(_ output: Output, geometry: CropGeometry, in directory: URL) {
        let manager = FileManager.default, innerName = geometry.innerFile, outerName = geometry.outerFile
        try? manager.removeItem(at: directory)
        guard (try? manager.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return }
        do {
            try output.inner.write(to: directory.appendingPathComponent(innerName), options: .atomic)
            try output.outer.write(to: directory.appendingPathComponent(outerName), options: .atomic)
            // Written last: a crash mid-write leaves no receipt, so the next launch derives again.
            let receipt = try JSONEncoder().encode([innerName: digest(output.inner), outerName: digest(output.outer)])
            try receipt.write(to: directory.appendingPathComponent("receipt.json"), options: .atomic)
        } catch { try? manager.removeItem(at: directory) }
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
