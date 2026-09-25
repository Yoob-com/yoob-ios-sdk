import Foundation

/// How a face's lip picture is finished before it is shown: the model's crop sharpened, and only her mouth, jaw and chin
/// taken from it, the rest of the face square left as the host frame's own pixels (`AvatarPack.lipPicture`; nil for a pack
/// that has not been measured, which composes exactly as before).
///
/// Why (Luna h08-v4, test30 against her real footage, the Luna app's study). The face square is the host crop area-resized
/// 342 -> 304 and Lanczos-resized back, with the model's 288 picture (144 x2 SR-lite) inside: outside the mouth it is 0.72 of
/// the host's own sharpness there and shimmers 2.5 levels a frame against it, and the mouth itself has 0.71 of the footage's
/// high-frequency detail (0.41 of its Laplacian variance), so each phrase edge, where the call switches between the real
/// footage (silence) and the model, toggles sharp and soft. With the mouth region and the unsharp amount below: square 0.98
/// of the host with 0.33 of shimmer, the mouth's detail 1.93 against the footage's 1.93, the inner mouth's 47.9 against 47.8,
/// the lips' aperture track unchanged (corr against the footage .765 vs .766).
public struct LipPicture: Sendable, Equatable {
    /// The unsharp amount on the model's crop: crop + amount x (crop - blur), the blur a 5-tap binomial each way (about a
    /// 1-pixel Gaussian), rounded and clamped. 0 leaves the crop as it is.
    public var sharpen: Float
    /// The part of the face square the model's picture is used in; outside it the host frame's own pixels. Nil: the whole
    /// square, over the 8-pixel feather.
    public var mouth: MouthRegion?

    /// A soft ellipse in the model's crop, in fractions of its side (the output, 288 for the 144 model), so a larger model
    /// takes the same values: 1 inside, falling to 0 over `softness` outside, and 0 outside the paste hole.
    public struct MouthRegion: Sendable, Equatable {
        public var centerX: Double, centerY: Double, radiusX: Double, radiusY: Double
        /// Clockwise in the picture (y down), degrees.
        public var rotationDegrees: Double
        /// The ramp's width outside the ellipse, a fraction of the side.
        public var softness: Double
        public init(centerX: Double, centerY: Double, radiusX: Double, radiusY: Double, rotationDegrees: Double, softness: Double) {
            self.centerX = centerX; self.centerY = centerY; self.radiusX = radiusX; self.radiusY = radiusY
            self.rotationDegrees = rotationDegrees; self.softness = softness
        }
        /// The weight at crop pixel (`x`, `y`) of a crop `side` pixels wide.
        func weight(x: Double, y: Double, side: Double) -> Double {
            let angle = rotationDegrees * .pi / 180, dx = x - centerX * side, dy = y - centerY * side
            let along = dx * cos(angle) + dy * sin(angle), across = -dx * sin(angle) + dy * cos(angle)
            let rx = radiusX * side, ry = radiusY * side
            let r = ((along / rx) * (along / rx) + (across / ry) * (across / ry)).squareRoot()
            return min(1, max(0, 1 - (r - 1) * min(rx, ry) / (softness * side)))
        }
    }

    public init(sharpen: Float, mouth: MouthRegion?) { self.sharpen = sharpen; self.mouth = mouth }

    /// Luna (h08-v4). The region holds every place her model moves the picture away from the host's (the lips, the jaw line
    /// against her hair on the left and the chin): at most 25 pixels of the 288 crop's hole lose more than 12 levels of the
    /// model's change at its 95th percentile, and half the hole is the host's own face. The amount brings the mouth's detail
    /// to the footage's without halos (1.2 overshoots it: 2.12 against 1.93).
    public static let luna = LipPicture(sharpen: 0.9, mouth: MouthRegion(centerX: 100 / 288, centerY: 118 / 288, radiusX: 115 / 288,
                                                                         radiusY: 82 / 288, rotationDegrees: -20, softness: 24 / 288))

    /// The lead-free dog (test face, pup A144 lead-free e124). Its model redraws the whole lower face, but the region can leave
    /// out the collar's tag, which the model fills in (a white disc with blue specks where the footage has a ring: 808 pixels
    /// of the crop's hole change by more than 12 levels there): no pixel of its mouth, jaw or cheeks loses more than 12 levels
    /// of the model's change, and 45% of the hole is the host's own. On the app path (20 s of tutor-mix) the square outside
    /// the mouth goes from 0.71 of the host's detail to 1.00 and its shimmer from 1.47 to 0.26 levels a frame. No sharpening:
    /// its mouth already has 1.21 of the detail of its footage's own frames (Luna's 0.63), and 0.5 took it to 1.50.
    public static let dog = LipPicture(sharpen: 0, mouth: MouthRegion(centerX: 0.48, centerY: 0.38, radiusX: 0.41, radiusY: 0.27,
                                                                      rotationDegrees: 10, softness: 24 / 288))

    /// The finished lip picture of the face whose pack has this identity (`AvatarManifest.identity`), nil where none helps.
    /// The new anime face on the realistic runtime (F4 e124, "anime-f4-e124-test") has none: its pack's own paste matte
    /// already keeps the square at its host's detail (0.99) with 0.43 levels of shimmer, and its mouth has 1.21 of its
    /// footage's detail; sharpening only added contrast to the line art (1.28).
    public static func face(identity: String) -> LipPicture? {
        switch identity {
        case "h08-development": luna
        case "cartoon-pup-a144-leadfree": dog
        default: nil
        }
    }

    /// `crop` (BGR, `side` x `side`) with the unsharp mask: each channel c + amount x (c - b), b the 5-tap binomial blur
    /// [1 4 6 4 1] / 16 along rows then columns, edges clamped, rounded to nearest even and clamped to a byte.
    public static func sharpened(_ crop: Data, side: Int, amount: Float) -> Data {
        guard amount != 0, side > 0, crop.count == side * side * 3 else { return crop }
        let row = side * 3
        var horizontal = [Int32](repeating: 0, count: side * row)
        var result = Data(count: crop.count)
        crop.withUnsafeBytes { raw in
            let source = raw.bindMemory(to: UInt8.self)
            horizontal.withUnsafeMutableBufferPointer { horizontal in
                for y in 0..<side {
                    let line = y * row
                    for x in 0..<side {
                        let x0 = max(0, x - 2) * 3, x1 = max(0, x - 1) * 3, x3 = min(side - 1, x + 1) * 3, x4 = min(side - 1, x + 2) * 3
                        for c in 0..<3 {
                            let p = line + c
                            horizontal[line + x * 3 + c] = Int32(source[p + x0]) + 4 * Int32(source[p + x1]) + 6 * Int32(source[p + x * 3])
                                + 4 * Int32(source[p + x3]) + Int32(source[p + x4])
                        }
                    }
                }
            }
            result.withUnsafeMutableBytes { out in
                let out = out.bindMemory(to: UInt8.self)
                horizontal.withUnsafeBufferPointer { horizontal in
                    for y in 0..<side {
                        let r0 = max(0, y - 2) * row, r1 = max(0, y - 1) * row, r2 = y * row, r3 = min(side - 1, y + 1) * row, r4 = min(side - 1, y + 2) * row
                        for i in 0..<row {
                            let sum = horizontal[r0 + i] + 4 * horizontal[r1 + i] + 6 * horizontal[r2 + i] + 4 * horizontal[r3 + i] + horizontal[r4 + i]
                            let value = Float(source[r2 + i]), blur = Float(sum) / 256
                            out[r2 + i] = UInt8(max(0, min(255, (value + amount * (value - blur)).rounded(.toNearestOrEven))))
                        }
                    }
                }
            }
        }
        return result
    }

    /// The paste matte (`AvatarCompositor.FaceSquare.matte`) of a face square `side` pixels wide: the mouth region laid on the
    /// outer crop (0 outside the paste hole), resized to the side bilinearly (pixel centres, as the lanes' OpenCV), times the
    /// square's own 8-pixel edge feather, as bytes (x 255, rounded).
    public static func matte(_ region: MouthRegion, geometry: CropGeometry, side: Int) -> Data {
        let outer = geometry.outer, margin = geometry.margin, paste = geometry.paste, output = Double(geometry.output)
        var laid = [Double](repeating: 0, count: outer * outer)
        for y in paste.y..<(paste.y + paste.height) {
            for x in paste.x..<(paste.x + paste.width) {
                laid[(y + margin) * outer + x + margin] = region.weight(x: Double(x), y: Double(y), side: output)
            }
        }
        var bytes = Data(count: side * side)
        let scale = Double(outer) / Double(side)
        func sample(_ d: Int) -> (Int, Int, Double) {
            let s = min(max((Double(d) + 0.5) * scale - 0.5, 0), Double(outer - 1))
            let low = Int(s.rounded(.down)); return (low, min(low + 1, outer - 1), s - Double(low))
        }
        bytes.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: UInt8.self)
            for y in 0..<side {
                let (y0, y1, fy) = sample(y)
                for x in 0..<side {
                    let (x0, x1, fx) = sample(x)
                    let top = laid[y0 * outer + x0] * (1 - fx) + laid[y0 * outer + x1] * fx
                    let bottom = laid[y1 * outer + x0] * (1 - fx) + laid[y1 * outer + x1] * fx
                    let edge = min(x + 1, side - x, y + 1, side - y)
                    let alpha = (top * (1 - fy) + bottom * fy) * min(1, Double(edge) / 8)
                    out[y * side + x] = UInt8(max(0, min(255, (alpha * 255).rounded())))
                }
            }
        }
        return bytes
    }
}

/// Mouth-region mattes by face square side (the realistic pack's boxes take 15 sides), built once each.
final class LipMatteCache: @unchecked Sendable {
    private let lock = NSLock()
    private var mattes: [Int: Data] = [:]
    private var region: LipPicture.MouthRegion?
    func matte(_ region: LipPicture.MouthRegion, geometry: CropGeometry, side: Int) -> Data {
        if let matte = lock.withLock({ self.region == region ? mattes[side] : nil }) { return matte }
        let start = ContinuousClock.now, matte = LipPicture.matte(region, geometry: geometry, side: side)
        LipPictureTiming.shared.addMatte(StreamingAvatar.ms(start.duration(to: .now)))
        lock.withLock {
            if self.region != region || mattes.count >= 64 { mattes.removeAll(); self.region = region }
            mattes[side] = matte
        }
        return matte
    }
}

/// Where a finished lip picture's time goes, for the call's diagnostics (`CompanionAvatarController`, "lipPicture"): the
/// compose's own work for it (the matte looked up, the job set up), crops sharpened on the CPU (frames the GPU could not
/// take), the GPU's time for a frame with the sharpening pass, and the mouth mattes built.
public final class LipPictureTiming: @unchecked Sendable {
    public static let shared = LipPictureTiming()
    private let lock = NSLock()
    private var prepares = 0, prepareMS = 0.0, prepareMaxMS = 0.0
    private var cpuFrames = 0, cpuMS = 0.0
    private var gpuFrames = 0, gpuMS = 0.0, gpuMaxMS = 0.0
    private var matteBuilds = 0, matteMS = 0.0
    func addPrepare(_ ms: Double) { lock.withLock { prepares += 1; prepareMS += ms; prepareMaxMS = max(prepareMaxMS, ms) } }
    func addCPU(_ ms: Double) { lock.withLock { cpuFrames += 1; cpuMS += ms } }
    func addGPU(_ ms: Double) { lock.withLock { gpuFrames += 1; gpuMS += ms; gpuMaxMS = max(gpuMaxMS, ms) } }
    func addMatte(_ ms: Double) { lock.withLock { matteBuilds += 1; matteMS += ms } }
    public func reset() {
        lock.withLock { prepares = 0; prepareMS = 0; prepareMaxMS = 0; cpuFrames = 0; cpuMS = 0; gpuFrames = 0; gpuMS = 0; gpuMaxMS = 0 }
    }
    public var summary: [String: Double] {
        lock.withLock {
            ["composes": Double(prepares), "prepareAvgMS": prepareMS / Double(max(1, prepares)), "prepareMaxMS": prepareMaxMS,
             "cpuSharpenFrames": Double(cpuFrames), "cpuSharpenAvgMS": cpuMS / Double(max(1, cpuFrames)),
             "gpuFrames": Double(gpuFrames), "gpuFrameAvgMS": gpuMS / Double(max(1, gpuFrames)), "gpuFrameMaxMS": gpuMaxMS,
             "matteBuilds": Double(matteBuilds), "matteBuildMS": matteMS]
        }
    }
}

extension AvatarPack {
    /// Everything a finished lip picture needs before the first frame, off the frame path: the mouth matte for every face
    /// side the pack uses (Luna's boxes take 15) and the GPU's self-checks for the matte and the sharpening. Without a lip
    /// picture it does nothing.
    public func prepareLipPicture() {
        guard let finish = lipPicture else { return }
        if let region = finish.mouth, matte == nil {
            for side in Set(manifest.frames.map { $0.bbox[2] - $0.bbox[0] }) { _ = lipMattes.matte(region, geometry: geometry, side: side) }
        }
        FaceMetalCompositor.shared?.prepare(geometry: geometry, matte: finish.mouth != nil || matte != nil, sharpen: finish.sharpen != 0)
    }
}
