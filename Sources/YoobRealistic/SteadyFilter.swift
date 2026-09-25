import Accelerate
import Foundation

/// The anime's steady paste in time (`AvatarManifest.Paste.temporal`, the Luna app's study): the lane renderer's
/// `--silence_ema 0.5 --tfilter 3,12 --tfilter_mode global` (anime-h08-20260917 eval/code/render.py) on the model's crops, in
/// the order they are rendered. The model redraws a mouth that barely moves a little differently each frame (anime line art
/// shows it as a shimmer on the lips): each new crop is blended with the previous one, the previous first moved into the new
/// frame's face box (the box follows the head, so an unaligned blend would smear every edge by the head's motion).
/// - Motion gate: the per-pixel difference to the previous crop (largest channel), averaged down to the model's input size and
///   blurred (Gaussian, `blur` input pixels), then its 95th percentile over the mouth hole sets one weight for the whole crop:
///   `floor` + (1 - `floor`) x smoothstep(`low`, `high`, p95) of the new crop. Redraws under `low` grey levels are held,
///   real mouth motion over `high` passes whole, and nothing lags in one region only.
/// - Silence: while the lips seal or release (the silence weight between 0 and 1), the crop is first averaged with the
///   previous one, new-frame weight 1 - weight x (1 - `silenceEMA`), so a closing mouth is drawn once, not redrawn.
/// The lane filtered the model's 288 output before its sharpener; the app's renderer is the two fused, so this filters the
/// sharpened crop, with the gate measured at the input size as the lane measured it. A crop after a frame the model did not
/// draw (the host's own face in silence), or after a jump of the box by a tenth of its side, starts afresh. The buffers are
/// kept between frames: one crop's work is a few vector passes over it.
final class SteadyFilter {
    typealias Settings = AvatarManifest.Paste.Temporal
    private let settings: Settings
    private let geometry: CropGeometry
    private let plane: Int
    /// The previous filtered crop, planar B, G, R floats (grey levels), and its face box (x, y, side).
    private var previous: [Float]
    private var previousBox: (x: Double, y: Double, side: Double)?
    private var hasPrevious = false
    /// The silence average's previous crop, when the last frame was inside a seal or release.
    private var silencePrevious: [Float]
    private var hasSilencePrevious = false
    /// Work buffers: the new crop, an aligned copy of an old one, one plane of scratch, the gate's maps at the input size.
    private var current: [Float], aligned: [Float], scratch: [Float], small: [Float], blurred: [Float], smallScratch: [Float]
    private var positions: [Float]
    private let kernel: [Float]
    /// Diagnostics: the gate's weight for the last filtered crop.
    private(set) var lastWeight: Float = 1

    init(settings: Settings, geometry: CropGeometry) {
        self.settings = settings; self.geometry = geometry
        plane = geometry.output * geometry.output
        previous = [Float](repeating: 0, count: plane * 3); silencePrevious = previous; current = previous; aligned = previous
        scratch = [Float](repeating: 0, count: plane)
        let inner = geometry.inner * geometry.inner
        small = [Float](repeating: 0, count: inner); blurred = small; smallScratch = small
        positions = [Float](repeating: 0, count: geometry.output)
        // cv2.GaussianBlur's kernel for a float image: size round(sigma * 8 + 1) | 1, normalised.
        let sigma = Double(max(settings.blur, 0.1)), size = Int((sigma * 8 + 1).rounded()) | 1, half = size / 2
        let raw = (0..<size).map { exp(-Double(($0 - half) * ($0 - half)) / (2 * sigma * sigma)) }
        let total = raw.reduce(0, +)
        kernel = raw.map { Float($0 / total) }
    }

    /// Forget the previous crops (a frame without a model crop, a restart, a picture outside the rendered sequence).
    func reset() { hasPrevious = false; previousBox = nil; hasSilencePrevious = false }

    /// The filtered crop of a frame on the host whose face box is `box` (manifest `bbox`), rendered with silence weight
    /// `silence` (0 speech, 1 sealed): BGR bytes, the output size square, as the model's crop.
    func filter(_ crop: Data, box: [Int], silence: Float) -> Data {
        guard crop.count == plane * 3, box.count == 4 else { reset(); return crop }
        crop.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self).baseAddress!
            current.withUnsafeMutableBufferPointer { out in
                for channel in 0..<3 { vDSP_vfltu8(bytes + channel, 3, out.baseAddress! + channel * plane, 1, vDSP_Length(plane)) }
            }
        }
        let now = (x: Double(box[0]), y: Double(box[1]), side: Double(box[2] - box[0]))
        let jumped = previousBox.map { abs(now.x - $0.x) > 0.1 * now.side || abs(now.y - $0.y) > 0.1 * now.side } ?? true
        if jumped { hasPrevious = false; hasSilencePrevious = false }
        let from = previousBox, moved = from.map { $0.x != now.x || $0.y != now.y || $0.side != now.side } ?? false
        // Silence average (render.py --silence_ema): only inside a seal or release.
        if let ema = settings.silenceEMA, ema < 1, silence > 0 {
            if hasSilencePrevious {
                let keep = 1 - silence * (1 - ema)
                if moved, let from { align(&silencePrevious, from: from, to: now) }
                vDSP.linearInterpolate(silencePrevious, current, using: keep, result: &aligned)
                swap(&current, &aligned)
            }
            silencePrevious.withUnsafeMutableBufferPointer { held in current.withUnsafeBufferPointer { held.baseAddress!.update(from: $0.baseAddress!, count: $0.count) } }
            hasSilencePrevious = true
        } else { hasSilencePrevious = false }
        // Motion gate (render.py --tfilter lo,hi --tfilter_mode global).
        if hasPrevious {
            if moved, let from { align(&previous, from: from, to: now) }
            let weight = gateWeight()
            vDSP.linearInterpolate(previous, current, using: weight, result: &aligned)
            swap(&current, &aligned)
            lastWeight = weight
        } else { lastWeight = 1 }
        swap(&previous, &current); hasPrevious = true; previousBox = now
        // Out: rounded to the nearest grey level, clamped, interleaved BGR.
        var out = Data(count: plane * 3)
        var low: Float = 0, high: Float = 255
        previous.withUnsafeBufferPointer { values in
            scratch.withUnsafeMutableBufferPointer { s in
                out.withUnsafeMutableBytes { raw in
                    let bytes = raw.bindMemory(to: UInt8.self).baseAddress!
                    for channel in 0..<3 {
                        vDSP_vclip(values.baseAddress! + channel * plane, 1, &low, &high, s.baseAddress!, 1, vDSP_Length(plane))
                        vDSP_vfixru8(s.baseAddress!, 1, bytes + channel, 3, vDSP_Length(plane))
                    }
                }
            }
        }
        return out
    }

    /// The gate's weight for `current` against `previous` (both planar): the largest-channel difference, averaged over
    /// scale x scale blocks to the input size, blurred, and its 95th percentile over the mouth hole through the smoothstep.
    private func gateWeight() -> Float {
        let side = geometry.output, scale = geometry.scale, inner = geometry.inner, count = vDSP_Length(plane)
        current.withUnsafeBufferPointer { c in
            previous.withUnsafeBufferPointer { p in
                scratch.withUnsafeMutableBufferPointer { d in
                    aligned.withUnsafeMutableBufferPointer { channel in
                        // |c - p| per channel; the largest of the three in `d`.
                        vDSP_vsub(p.baseAddress!, 1, c.baseAddress!, 1, d.baseAddress!, 1, count)
                        vDSP_vabs(d.baseAddress!, 1, d.baseAddress!, 1, count)
                        for k in 1..<3 {
                            vDSP_vsub(p.baseAddress! + k * plane, 1, c.baseAddress! + k * plane, 1, channel.baseAddress!, 1, count)
                            vDSP_vabs(channel.baseAddress!, 1, channel.baseAddress!, 1, count)
                            vDSP_vmax(d.baseAddress!, 1, channel.baseAddress!, 1, d.baseAddress!, 1, count)
                        }
                    }
                    // Block average to the input size.
                    small.withUnsafeMutableBufferPointer { s in
                        s.update(repeating: 0)
                        let norm = 1 / Float(scale * scale)
                        for y in 0..<inner {
                            let out = s.baseAddress! + y * inner
                            for dy in 0..<scale {
                                let row = d.baseAddress! + (y * scale + dy) * side
                                for dx in 0..<scale {
                                    vDSP_vadd(row + dx, vDSP_Stride(scale), out, 1, out, 1, vDSP_Length(inner))
                                }
                            }
                            var n = norm
                            vDSP_vsmul(out, 1, &n, out, 1, vDSP_Length(inner))
                        }
                    }
                }
            }
        }
        blur()
        // The 95th percentile (numpy's linear) over the hole, from a histogram in 1/64 grey levels up to 16 levels: above
        // that the smoothstep has long saturated (`high` is 12), so the weight is exactly 1 either way.
        let hole = geometry.hole, bins = 16 * 64
        var histogram = [Int](repeating: 0, count: bins + 1), total = 0
        blurred.withUnsafeBufferPointer { b in
            for y in hole.y..<(hole.y + hole.height) {
                let row = b.baseAddress! + y * inner + hole.x
                for x in 0..<hole.width { histogram[min(bins, max(0, Int(row[x] * 64)))] += 1 }
            }
        }
        total = hole.width * hole.height
        let rank = 0.95 * Double(total - 1)
        var below = 0, p95: Float = 16
        for bin in 0..<bins where histogram[bin] > 0 {
            if Double(below + histogram[bin]) > rank {
                p95 = (Float(bin) + Float((rank - Double(below)) / Double(histogram[bin]))) / 64; break
            }
            below += histogram[bin]
        }
        let t = min(max((p95 - settings.low) / max(settings.high - settings.low, 1e-6), 0), 1)
        return settings.floor + (1 - settings.floor) * t * t * (3 - 2 * t)
    }

    /// Separable Gaussian blur of `small` into `blurred` (vImage, edges extended; the lane's cv2 reflects them, which only
    /// moves the hole's outermost pixels a little).
    private func blur() {
        let side = geometry.inner, rowBytes = side * MemoryLayout<Float>.size, taps = UInt32(kernel.count)
        small.withUnsafeMutableBytes { s in
            smallScratch.withUnsafeMutableBytes { h in
                blurred.withUnsafeMutableBytes { o in
                    var src = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(side), width: vImagePixelCount(side), rowBytes: rowBytes)
                    var mid = vImage_Buffer(data: h.baseAddress, height: vImagePixelCount(side), width: vImagePixelCount(side), rowBytes: rowBytes)
                    var dst = vImage_Buffer(data: o.baseAddress, height: vImagePixelCount(side), width: vImagePixelCount(side), rowBytes: rowBytes)
                    kernel.withUnsafeBufferPointer { k in
                        _ = vImageConvolve_PlanarF(&src, &mid, nil, 0, 0, k.baseAddress!, 1, taps, 0, vImage_Flags(kvImageEdgeExtend))
                        _ = vImageConvolve_PlanarF(&mid, &dst, nil, 0, 0, k.baseAddress!, taps, 1, 0, vImage_Flags(kvImageEdgeExtend))
                    }
                }
            }
        }
    }

    /// Moves a previous crop (planar) into the new face box, in place: output pixel u of the new crop sees frame point
    /// x0 + (u + margin + 0.5) x side / outer - 0.5 (the crop is the centre of the outer crop over the box), read from the
    /// old crop bilinearly (rows, then columns), edges replicated.
    private func align(_ image: inout [Float], from: (x: Double, y: Double, side: Double), to: (x: Double, y: Double, side: Double)) {
        let side = geometry.output, outer = Double(geometry.outer), margin = Double(geometry.margin)
        // u_old = r * u_new + t, per axis: r = to.side / from.side.
        let r = to.side / from.side, limit = Double(side - 1) - 1e-3
        let tx = (margin + 0.5) * r - margin - 0.5 + (to.x - from.x) * outer / from.side
        let ty = (margin + 0.5) * r - margin - 0.5 + (to.y - from.y) * outer / from.side
        for u in 0..<side { positions[u] = Float(min(max(r * Double(u) + tx, 0), limit)) }
        let n = vDSP_Length(side)
        image.withUnsafeMutableBufferPointer { img in
            aligned.withUnsafeMutableBufferPointer { out in
                positions.withUnsafeBufferPointer { xs in
                    for k in 0..<3 {
                        let source = img.baseAddress! + k * plane, target = out.baseAddress! + k * plane
                        // Columns: each row read at the new positions (vDSP_vlint: A[i] + frac * (A[i + 1] - A[i])).
                        for v in 0..<side { vDSP_vlint(source + v * side, xs.baseAddress!, 1, target + v * side, 1, n, n) }
                        // Rows: each new row between two of those rows, back into the image.
                        for v in 0..<side {
                            let y = min(max(r * Double(v) + ty, 0), Double(side - 1)), y0 = Int(y.rounded(.down)), y1 = min(y0 + 1, side - 1)
                            var weight = Float(y - Double(y0))
                            vDSP_vintb(target + y0 * side, 1, target + y1 * side, 1, &weight, source + v * side, 1, n)
                        }
                    }
                }
            }
        }
    }
}
