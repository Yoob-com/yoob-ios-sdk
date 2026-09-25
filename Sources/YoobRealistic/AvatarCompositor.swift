import Foundation
import CoreGraphics
import CoreVideo
import ImageIO

public struct AvatarImage: @unchecked Sendable {
    /// Byte order of one pixel. Alpha is always opaque (255).
    public enum PixelLayout: Sendable {
        /// R, G, B, A: premultipliedLast.
        case rgba
        /// B, G, R, A: premultipliedFirst in 32-bit little-endian words, the host video decoder's own order (32BGRA), so
        /// the host frame is copied rather than redrawn, and the order the display takes without a swizzle.
        case bgra
        public var bitmapInfo: CGBitmapInfo {
            switch self {
            case .rgba: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            case .bgra: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            }
        }
    }
    private enum Storage { case data(Data), buffer(CVPixelBuffer) }
    public let width: Int
    public let height: Int
    public let layout: PixelLayout
    private let storage: Storage
    /// The space the pixel values are in: the host video's own space, so the display converts the whole frame, pasted
    /// face square included, the same way it converts the idle loop video.
    public var colorSpace: CGColorSpace = CGColorSpaceCreateDeviceRGB()
    /// The host frame this picture was composed on, when the head path chose it.
    public var host: Int?
    /// With the head path: the call screen should show this rendered picture rather than the still idle face (every
    /// rendered frame, until a stall walk hands over on a home pose).
    public var holdsSpeech = false
    /// How much of the face square is the host frame's own picture rather than the model's render: 1 in silence (the
    /// real footage's sealed lips), 0 while the voice plays, in between over the silence weight's 4-frame ramps.
    public var rawMix: Float = 0
    /// The silence seal the renderer drew this frame's lips with (0 open, 1 sealed; diagnostics).
    public var sealWeight: Float = 0
    /// The blink picture drawn on this frame (`SpeechBlink`), when the eyes are mid-blink.
    public var blink: Int?
    public init(width: Int, height: Int, pixels: Data, layout: PixelLayout, colorSpace: CGColorSpace = CGColorSpaceCreateDeviceRGB()) {
        self.width = width; self.height = height; storage = .data(pixels); self.layout = layout; self.colorSpace = colorSpace
    }
    /// A composed frame in an IOSurface-backed BGRA pixel buffer the compositor no longer writes to.
    init(buffer: CVPixelBuffer, colorSpace: CGColorSpace) {
        width = CVPixelBufferGetWidth(buffer); height = CVPixelBufferGetHeight(buffer); layout = .bgra
        storage = .buffer(buffer); self.colorSpace = colorSpace
    }
    /// The composed pixel buffer (IOSurface-backed, BGRA), which the call screen shows without a copy. Nil for a picture
    /// made from bytes.
    public var pixelBuffer: CVPixelBuffer? { if case .buffer(let buffer) = storage { buffer } else { nil } }
    /// `width * height * 4` bytes, top row first, in `layout` (a copy without row padding, for a pixel buffer).
    public var pixels: Data {
        switch storage {
        case .data(let data): return data
        case .buffer(let buffer):
            CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return Data() }
            let stride = CVPixelBufferGetBytesPerRow(buffer), row = width * 4
            var data = Data(count: row * height)
            data.withUnsafeMutableBytes { out in
                for y in 0..<height { memcpy(out.baseAddress! + y * row, base + y * stride, row) }
            }
            return data
        }
    }
    public func cgImage() throws -> CGImage {
        let provider: CGDataProvider?, bytesPerRow: Int
        switch storage {
        case .data(let data):
            provider = CGDataProvider(data: data as CFData); bytesPerRow = width * 4
        case .buffer(let buffer):
            // The image reads the buffer in place: it stays locked (read-only) and retained until the image is released,
            // so the frame pool cannot hand it out again while the image lives.
            guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw AvatarError.unavailable }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { CVPixelBufferUnlockBaseAddress(buffer, .readOnly); throw AvatarError.unavailable }
            bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            provider = CGDataProvider(dataInfo: Unmanaged.passRetained(buffer).toOpaque(), data: base, size: bytesPerRow * height) { info, _, _ in
                let buffer = Unmanaged<CVPixelBuffer>.fromOpaque(info!).takeRetainedValue()
                CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            }
        }
        guard let provider,
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: layout.bitmapInfo,
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw AvatarError.unavailable }
        return image
    }
}

/// A decoded host frame.
public enum HostPicture: @unchecked Sendable {
    /// A frame of the host video as the decoder delivered it (32BGRA), and the colour space VideoToolbox tags its CGImage
    /// with: the compositor copies its rows instead of drawing a CGImage of it.
    case pixels(CVPixelBuffer, colorSpace: CGColorSpace?)
    /// A still host frame (a pack of PNG frames).
    case image(CGImage)
    public var width: Int {
        switch self { case .pixels(let buffer, _): CVPixelBufferGetWidth(buffer); case .image(let image): image.width }
    }
    public var height: Int {
        switch self { case .pixels(let buffer, _): CVPixelBufferGetHeight(buffer); case .image(let image): image.height }
    }
    var colorSpace: CGColorSpace? {
        switch self { case .pixels(_, let space): space; case .image(let image): image.colorSpace }
    }
}

/// The white side bars of each host frame, as columns from the left and from the right (`AvatarCompositor`).
final class WhiteBarCache: @unchecked Sendable {
    private let lock = NSLock()
    private var bars: [Int: (left: Int, right: Int)] = [:]
    func bars(host: Int) -> (left: Int, right: Int)? { lock.withLock { bars[host] } }
    func store(_ value: (left: Int, right: Int), host: Int) { lock.withLock { bars[host] = value } }
}

/// IOSurface-backed BGRA pixel buffers for composed frames, one pool per frame size. A buffer returns to its pool when the
/// last picture holding it is released, so the call screen can show a frame straight from its surface.
final class FramePool: @unchecked Sendable {
    static let shared = FramePool()
    private let lock = NSLock()
    private var pools: [Int: CVPixelBufferPool] = [:]
    func buffer(width: Int, height: Int) throws -> CVPixelBuffer {
        let pool = try lock.withLock {
            if let pool = pools[width << 16 | height] { return pool }
            let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](), kCVPixelBufferMetalCompatibilityKey as String: true]
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess, let pool else { throw AvatarError.unavailable }
            pools[width << 16 | height] = pool
            return pool
        }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { throw AvatarError.unavailable }
        return buffer
    }
}

public enum AvatarCompositor {
    /// Host PNG decode is the dominant per-frame cost (~16 ms of ~25 ms on an M-series Mac), so the next two
    /// host frames are decoded ahead on a background queue. Pixel math is unchanged and output is bit-exact.
    public static let prefetchFrames = 2
    /// The layout of every composed frame.
    public static let layout = AvatarImage.PixelLayout.bgra
    /// Columns from each side scanned for white bars.
    static let barScanColumns = 40

    /// The face square of one frame: the host's outer crop with the model's crop pasted in (`outerSide` square BGR: 304
    /// for the 144 model), resized to `side` and blended in at (`x`, `y`) with `mix` of the host's own face kept. With a
    /// `matte` (`side` x `side` bytes, the pack's paste matte for this host) the square is blended in by that alpha
    /// (value / 255) instead of the 8-pixel feather at its edges: 0 keeps the host's pixel as it is.
    struct FaceSquare {
        let outer: [UInt8]; let outerSide: Int; let x: Int; let y: Int; let side: Int; let mix: Float
        var matte: Data? = nil
        /// The model's crop to sharpen into the paste hole (`LipPicture.sharpened`): `outer` then holds the crop unsharpened,
        /// and the GPU sharpens it in its own pass (`FaceMetalCompositor`), the CPU loops before the resize (`sharpenedOuter`).
        var sharpen: Sharpen? = nil
    }
    struct Sharpen { let crop: Data; let amount: Float; let geometry: CropGeometry }
    /// `face.outer` with the hole pasted from the sharpened crop, when the face asks for it (the CPU loops' way).
    static func sharpenedOuter(_ face: FaceSquare) -> FaceSquare {
        guard let sharpen = face.sharpen else { return face }
        let crop = LipPicture.sharpened(sharpen.crop, side: sharpen.geometry.output, amount: sharpen.amount)
        var outer = face.outer
        let geometry = sharpen.geometry, side = geometry.outer, paste = geometry.paste, margin = geometry.margin
        crop.withUnsafeBytes { crop in
            for y in paste.y..<(paste.y + paste.height) {
                for i in 0..<(paste.width * 3) {
                    outer[((y + margin) * side + margin + paste.x) * 3 + i] = crop[(y * geometry.output + paste.x) * 3 + i]
                }
            }
        }
        return FaceSquare(outer: outer, outerSide: face.outerSide, x: face.x, y: face.y, side: face.side, mix: face.mix, matte: face.matte)
    }
    /// A matte byte's alpha, value / 255, computed once so the CPU loops and the Metal kernel blend with the same floats.
    static let matteWeights: [Float] = (0..<256).map { Float($0) / 255 }
    /// A blink picture in BGRA and where it goes.
    struct BlinkPatch { let x: Int; let y: Int; let width: Int; let height: Int; let bgra: Data }

    /// Whether the GPU composes frames: the Metal compositor built and passed its parity self-check (`FaceMetalCompositor`).
    public static var usesMetal: Bool { FaceMetalCompositor.shared != nil }
    /// Builds the Metal compositor and runs its self-check now (tens of ms, once per process) rather than on the first frame.
    public static func warmUp() { _ = FaceMetalCompositor.shared }
    /// Frames the GPU composed in this process (the rest went to the CPU loops).
    public static var gpuFrames: Int { FaceMetalCompositor.shared?.framesComposed ?? 0 }
    /// The GPU self-check against the CPU loops: largest byte difference, differing bytes, bytes compared. Nil without Metal.
    public static var metalParity: (maxDifference: Int, differingBytes: Int, comparedBytes: Int)? {
        FaceMetalCompositor.shared.map { ($0.parity.maxDifference, $0.parity.differingBytes, $0.parity.comparedBytes) }
    }

    /// `host` overrides the call frame's host (the head path); `prefetchHosts` names the hosts to decode ahead; `blink`
    /// draws that picture of `pack.blink` over the eyes. `rawMix` keeps that much of the host frame's own face square in
    /// place of the model's render: at 1 (silence) the frame is the real footage and `cropBGR` may be empty, so the sealed
    /// lips are the clip's own and never redrawn; in between (the silence weight's ramps) the two are blended.
    /// The frame is a BGRA pixel buffer (`layout`). The GPU composes it when it can (`FaceMetalCompositor`: host, face,
    /// blink and bars in one pass, bit-identical to the CPU loops); otherwise the CPU copies the host rows from the
    /// decoder's own BGRA buffer and blends the BGR face and the blink per channel. Either way every byte equals the RGBA
    /// compose's, reordered. `gpu: false` keeps it on the CPU (benchmarks, parity checks).
    public static func compose(pack: AvatarPack, frame: Int, cropBGR: Data, host chosen: Int? = nil, prefetchHosts: [Int]? = nil,
                               blink: Int? = nil, rawMix: Float = 0, gpu: Bool = true) throws -> AvatarImage {
        let mix = min(max(rawMix, 0), 1)
        guard cropBGR.count == pack.geometry.outputBytes || (mix >= 1 && cropBGR.isEmpty) else { throw AvatarError.invalidPack("crop bytes") }
        let index = chosen.map { min(max(0, $0), pack.manifest.frames.count - 1) } ?? pack.hostIndex(for: frame), host = pack.manifest.frames[index]
        let next = prefetchHosts ?? (1...prefetchFrames).map { pack.hostIndex(for: frame + $0) }
        let picture = try pack.hostFrames.picture(index, prefetch: next)
        let width = host.width, height = host.height
        guard picture.width == width, picture.height == height else { throw AvatarError.invalidPack("host image") }
        // Compose in the host picture's own RGB space, so drawing it converts nothing. The pack's crops were cut from the
        // same unconverted values; converting only the host (a decoded video frame is tagged BT.709, up to ~12 levels
        // brighter in skin tones on iOS) made the pasted face square visible.
        let space = picture.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
        let side = host.bbox[2] - host.bbox[0]
        // A face's finished lip picture (`LipPicture`): the crop sharpened, and the mouth region's matte where the pack has no
        // paste matte of its own. Without one, the crop and the matte are the pack's as always.
        // The sharpening runs on the GPU with the rest of the frame (the CPU loops only when the GPU cannot take the frame):
        // on the CPU it cost the frame path about 1 ms on this Mac and more on the phone, beside the encoder.
        let finish = pack.lipPicture, finishStart = ContinuousClock.now
        let matte = pack.matte(host: index) ?? finish?.mouth.map { pack.lipMattes.matte($0, geometry: pack.geometry, side: side) }
        var face = mix < 1 ? FaceSquare(outer: pastedOuter(pack: pack, index: index, cropBGR: cropBGR), outerSide: pack.geometry.outer,
                                        x: host.bbox[0], y: host.bbox[1], side: side, mix: mix, matte: matte) : nil
        if let amount = finish?.sharpen, amount != 0, !cropBGR.isEmpty, face != nil {
            face?.sharpen = Sharpen(crop: cropBGR, amount: amount, geometry: pack.geometry)
        }
        if finish != nil { LipPictureTiming.shared.addPrepare(StreamingAvatar.ms(finishStart.duration(to: .now))) }
        let patch = blink.flatMap { pack.blink?.patch($0) }
        // White side bars depend only on the scanned columns: when neither the face square nor the blink reaches them, they
        // are the host frame's own, found once per host. Otherwise the composed frame is scanned, as it always was.
        let scan = min(barScanColumns, width)
        let bands = [0..<scan, (width - scan)..<width]
        func clear(_ x: Int, _ extent: Int) -> Bool { !bands.contains { x < $0.upperBound && $0.lowerBound < x + extent } }
        let barsFromHost = (face.map { clear($0.x, $0.side) } ?? true) && (patch.map { clear($0.x, $0.width) } ?? true)
        let destination = try FramePool.shared.buffer(width: width, height: height)
        if gpu, barsFromHost, case .pixels(let buffer, _) = picture, let metal = FaceMetalCompositor.shared {
            let bars = try pack.whiteBars.bars(host: index) ?? {
                let found = try hostBars(buffer)
                pack.whiteBars.store(found, host: index)
                return found
            }()
            // A frame the GPU cannot take, or a failed command buffer, is composed on the CPU below.
            if (try? metal.compose(host: buffer, into: destination, face: face, blink: patch, bars: bars)) == true {
                return AvatarImage(buffer: destination, colorSpace: space)
            }
        }
        try composeCPU(host: picture, space: space, into: destination, face: face, blink: patch,
                       bars: barsFromHost ? pack.whiteBars.bars(host: index) : nil, scanHost: barsFromHost) { pack.whiteBars.store($0, host: index) }
        return AvatarImage(buffer: destination, colorSpace: space)
    }

    /// The CPU compose into `destination`: the host, the face square, the blink, then the white bars blackened. `bars` are
    /// the host's own when known. Otherwise they are scanned: on the host alone when `scanHost` (the caller knows the face
    /// and the blink stay clear of the scanned columns, and caches what `found` gets), else on the composed frame.
    static func composeCPU(host picture: HostPicture, space: CGColorSpace, into destination: CVPixelBuffer, face: FaceSquare?, blink: BlinkPatch?,
                           bars known: (left: Int, right: Int)?, scanHost: Bool, found: ((left: Int, right: Int)) -> Void) throws {
        let width = CVPixelBufferGetWidth(destination), height = CVPixelBufferGetHeight(destination)
        guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else { throw AvatarError.unavailable }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }
        guard let base = CVPixelBufferGetBaseAddress(destination) else { throw AvatarError.unavailable }
        let rowBytes = CVPixelBufferGetBytesPerRow(destination)
        let bgra = UnsafeMutableBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: rowBytes * height)
        try fillHost(picture, into: bgra, rowBytes: rowBytes, width: width, height: height, space: space)
        var bars = known
        if bars == nil, scanHost {
            let scanned = whiteBars(bgra, rowBytes: rowBytes, width: width, height: height)
            found(scanned); bars = scanned
        }
        if let face {
            // A sharpened crop on the CPU: counted, as a frame the GPU could not take (`LipPictureTiming`).
            let start = ContinuousClock.now, finished = sharpenedOuter(face)
            if face.sharpen != nil { LipPictureTiming.shared.addCPU(StreamingAvatar.ms(start.duration(to: .now))) }
            pasteFace(finished, into: bgra, rowBytes: rowBytes)
        }
        if let blink {
            blink.bgra.withUnsafeBytes { patch in
                SpeechBlink.blend(patch: patch.bindMemory(to: UInt8.self), x: blink.x, y: blink.y, width: blink.width, height: blink.height,
                                  into: bgra, rowBytes: rowBytes, frameWidth: width, frameHeight: height)
            }
        }
        // Match the accepted delivery policy: blacken white side bars without stretching the host.
        let (left, right) = bars ?? whiteBars(bgra, rowBytes: rowBytes, width: width, height: height)
        for y in 0..<height {
            for x in 0..<left { let p = y * rowBytes + x * 4; bgra[p] = 0; bgra[p + 1] = 0; bgra[p + 2] = 0 }
            for x in (width - right)..<width { let p = y * rowBytes + x * 4; bgra[p] = 0; bgra[p + 1] = 0; bgra[p + 2] = 0 }
        }
    }

    /// The host picture as the frame's BGRA rows (`rowBytes` apart). A video frame is the decoder's own BGRA rows (its alpha
    /// is opaque), so copying them equals drawing its CGImage into a context of its own space. A still frame is drawn over
    /// opaque white, as the RGBA compose drew it.
    static func fillHost(_ picture: HostPicture, into bgra: UnsafeMutableBufferPointer<UInt8>, rowBytes: Int, width: Int, height: Int,
                         space: CGColorSpace) throws {
        switch picture {
        case .pixels(let buffer, _):
            guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
                  CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw AvatarError.invalidPack("host video") }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw AvatarError.invalidPack("host video") }
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            if stride == rowBytes { memcpy(bgra.baseAddress!, base, rowBytes * height) }
            else { for y in 0..<height { memcpy(bgra.baseAddress! + y * rowBytes, base + y * stride, width * 4) } }
        case .image(let image):
            bgra.update(repeating: 255)
            guard let context = CGContext(data: bgra.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: rowBytes, space: space, bitmapInfo: AvatarImage.PixelLayout.bgra.bitmapInfo.rawValue) else {
                throw AvatarError.unavailable
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// The face square Lanczos-resized to its side and blended in over an 8-pixel feather, `mix` of the host's own face kept.
    /// With a matte, blended in by the matte's alpha instead (`pasteMatted`).
    static func pasteFace(_ face: FaceSquare, into bgra: UnsafeMutableBufferPointer<UInt8>, rowBytes: Int) {
        let side = face.side, mix = face.mix
        let up = resizeLanczos4(face.outer, sourceSide: face.outerSide, targetSide: side)
        if let matte = face.matte, matte.count >= side * side {
            pasteMatted(up, face: face, matte: matte, into: bgra, rowBytes: rowBytes); return
        }
        up.withUnsafeBufferPointer { up in
            for y in 0..<side {
                let row = (face.y + y) * rowBytes + face.x * 4
                for x in 0..<side {
                    let edge = min(x + 1, side - x, y + 1, side - y)
                    let pixel = row + x * 4, sourcePixel = (y * side + x) * 3
                    // BGR source, BGRA frame: channel c is c in both.
                    if edge >= 8, mix == 0 {
                        // alpha == 1: the blend below reduces exactly to the resized value.
                        bgra[pixel] = up[sourcePixel]; bgra[pixel + 1] = up[sourcePixel + 1]; bgra[pixel + 2] = up[sourcePixel + 2]
                        continue
                    }
                    let alpha = min(1, Float(edge) / 8) * (1 - mix)
                    for channel in 0..<3 {
                        let value = alpha * Float(up[sourcePixel + channel]) + (1 - alpha) * Float(bgra[pixel + channel])
                        bgra[pixel + channel] = UInt8(max(0, min(255, value.rounded(.toNearestOrEven))))
                    }
                }
            }
        }
    }

    /// The resized face square `up` blended in by the matte: alpha = matte / 255 x (1 - `mix`), as the anime lane's rect matte
    /// paste (`abi.paste` with a matte: the square's own edge feather is not used). A 0 keeps the host's pixel; a 255 with no
    /// silence mix takes the square's (the blend below gives exactly those values; the shortcuts only skip the arithmetic).
    static func pasteMatted(_ up: [UInt8], face: FaceSquare, matte: Data, into bgra: UnsafeMutableBufferPointer<UInt8>, rowBytes: Int) {
        let side = face.side, mix = face.mix
        up.withUnsafeBufferPointer { up in
            matte.withUnsafeBytes { raw in
                let matte = raw.bindMemory(to: UInt8.self)
                matteWeights.withUnsafeBufferPointer { weights in
                    for y in 0..<side {
                        let row = (face.y + y) * rowBytes + face.x * 4
                        for x in 0..<side {
                            let value = matte[y * side + x]
                            if value == 0 { continue }
                            let pixel = row + x * 4, sourcePixel = (y * side + x) * 3
                            if value == 255, mix == 0 {
                                bgra[pixel] = up[sourcePixel]; bgra[pixel + 1] = up[sourcePixel + 1]; bgra[pixel + 2] = up[sourcePixel + 2]
                                continue
                            }
                            let alpha = weights[Int(value)] * (1 - mix)
                            for channel in 0..<3 {
                                let blended = alpha * Float(up[sourcePixel + channel]) + (1 - alpha) * Float(bgra[pixel + channel])
                                bgra[pixel + channel] = UInt8(max(0, min(255, blended.rounded(.toNearestOrEven))))
                            }
                        }
                    }
                }
            }
        }
    }

    /// Host `index`'s outer crop with the model's crop pasted in (`CropGeometry`): the mouth hole, `scale` times as large in
    /// the output, is copied to where the output sits centred in the outer crop. At 144: rows and columns 8..<268 and
    /// 8..<278 of the 288 output, into the 304 outer crop 8 pixels further in.
    static func pastedOuter(pack: AvatarPack, index: Int, cropBGR: Data) -> [UInt8] {
        pastedOuter(pack.outerPixels, geometry: pack.geometry, index: index, cropBGR: cropBGR)
    }
    static func pastedOuter(_ outerPixels: Data, geometry: CropGeometry, index: Int, cropBGR: Data) -> [UInt8] {
        let side = geometry.outer, paste = geometry.paste, margin = geometry.margin
        let outerOffset = index * geometry.outerBytes
        var outer = [UInt8](outerPixels[outerOffset..<(outerOffset + geometry.outerBytes)])
        guard !cropBGR.isEmpty else { return outer }
        outer.withUnsafeMutableBufferPointer { outer in
            cropBGR.withUnsafeBytes { crop in
                for y in paste.y..<(paste.y + paste.height) {
                    let destination = ((y + margin) * side + margin + paste.x) * 3, source = (y * geometry.output + paste.x) * 3
                    (outer.baseAddress! + destination).update(from: crop.bindMemory(to: UInt8.self).baseAddress! + source, count: paste.width * 3)
                }
            }
        }
        return outer
    }

    /// Columns of white bar from each side, at most `barScanColumns`: a column is white when its mean channel is above 240.
    static func whiteBars(_ bgra: UnsafeMutableBufferPointer<UInt8>, rowBytes: Int, width: Int, height: Int) -> (left: Int, right: Int) {
        whiteBars(UnsafeBufferPointer(bgra), rowBytes: rowBytes, width: width, height: height)
    }
    static func whiteBars(_ bgra: UnsafeBufferPointer<UInt8>, rowBytes: Int, width: Int, height: Int) -> (left: Int, right: Int) {
        func whiteColumn(_ x: Int) -> Bool {
            var sum = 0
            for y in 0..<height { let p = y * rowBytes + x * 4; sum += Int(bgra[p]) + Int(bgra[p + 1]) + Int(bgra[p + 2]) }
            return Double(sum) / Double(height * 3) > 240
        }
        var left = 0, right = 0
        while left < min(barScanColumns, width) && whiteColumn(left) { left += 1 }
        while right < min(barScanColumns, width) && whiteColumn(width - 1 - right) { right += 1 }
        return (left, right)
    }
    /// The white bars of a host video frame, read from the decoder's buffer.
    static func hostBars(_ buffer: CVPixelBuffer) throws -> (left: Int, right: Int) {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw AvatarError.invalidPack("host video") }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw AvatarError.invalidPack("host video") }
        let height = CVPixelBufferGetHeight(buffer), rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        return whiteBars(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: rowBytes * height), rowBytes: rowBytes,
                         width: CVPixelBufferGetWidth(buffer), height: height)
    }

    // Separable 8-tap Lanczos with 11-bit coefficients, matching OpenCV's uint8 resize convention.
    /// Horizontal pass: 8 unrolled taps per output pixel in Int32 (a tap sum stays below 255 × Σ|w| ≈ 7e5). Vertical pass:
    /// each output row adds 8 weighted source scanlines as whole rows, which vectorizes, then rounds, shifts and clamps.
    /// Integer sums don't depend on order, so the output is identical to the per-pixel reference (`AvatarTests`).
    static func resizeLanczos4(_ source: [UInt8], sourceSide: Int, targetSide: Int) -> [UInt8] {
        // An empty target stays an empty result, as before. (The compositor's side comes from a manifest face box, which
        // `AvatarPack` validates as non-empty, so it is never 0 in production.)
        guard targetSide > 0 else { return [] }
        // The loops read `source` through unchecked pointers: a short buffer must stop here, not read out of bounds.
        precondition(sourceSide > 0 && source.count >= sourceSide * sourceSide * 3,
                     "resizeLanczos4 needs a \(sourceSide)×\(sourceSide) RGB source, got \(source.count) bytes")
        let taps = LanczosTaps.shared.taps(sourceSide: sourceSide, targetSide: targetSide)
        let rowWidth = targetSide * 3
        var horizontal = [Int32](repeating: 0, count: sourceSide * rowWidth)
        var result = [UInt8](repeating: 0, count: targetSide * rowWidth)
        var accumulator = [Int64](repeating: 0, count: rowWidth)
        source.withUnsafeBufferPointer { source in
            taps.byteOffsets.withUnsafeBufferPointer { offsets in
                taps.weights32.withUnsafeBufferPointer { weights in
                    horizontal.withUnsafeMutableBufferPointer { horizontal in
                        for y in 0..<sourceSide {
                            let row = source.baseAddress! + y * sourceSide * 3, out = horizontal.baseAddress! + y * rowWidth
                            for x in 0..<targetSide {
                                let o = offsets.baseAddress! + x * 8, w = weights.baseAddress! + x * 8
                                for c in 0..<3 {
                                    let s = row + c
                                    var value = Int32(s[o[0]]) &* w[0]
                                    value &+= Int32(s[o[1]]) &* w[1]; value &+= Int32(s[o[2]]) &* w[2]; value &+= Int32(s[o[3]]) &* w[3]
                                    value &+= Int32(s[o[4]]) &* w[4]; value &+= Int32(s[o[5]]) &* w[5]; value &+= Int32(s[o[6]]) &* w[6]
                                    value &+= Int32(s[o[7]]) &* w[7]
                                    out[x * 3 + c] = value
                                }
                            }
                        }
                    }
                }
            }
        }
        taps.indices.withUnsafeBufferPointer { indices in
            taps.weights32.withUnsafeBufferPointer { weights in
                horizontal.withUnsafeBufferPointer { horizontal in
                    accumulator.withUnsafeMutableBufferPointer { sum in
                        result.withUnsafeMutableBufferPointer { result in
                            for y in 0..<targetSide {
                                sum.update(repeating: 0)
                                for k in 0..<8 {
                                    let line = horizontal.baseAddress! + indices[y * 8 + k] * rowWidth, weight = Int64(weights[y * 8 + k])
                                    for i in 0..<rowWidth { sum[i] &+= Int64(line[i]) &* weight }
                                }
                                let out = result.baseAddress! + y * rowWidth
                                for i in 0..<rowWidth { out[i] = UInt8(clamping: (sum[i] &+ (1 << 21)) >> 22) }
                            }
                        }
                    }
                }
            }
        }
        return result
    }
}

/// Lanczos taps depend only on the two sides. The H08 host crop side varies per frame (15 sides, 333...347), so cache
/// every side pair a pack uses; the bound only guards against unbounded growth.
final class LanczosTaps: @unchecked Sendable {
    static let shared = LanczosTaps()
    struct Table {
        let indices: [Int]
        let weights: [Int]
        /// `indices * 3`: tap byte offsets within an RGB row, and the weights as Int32, for the unrolled resize loops.
        let byteOffsets: [Int]
        let weights32: [Int32]
        init(indices: [Int], weights: [Int]) {
            self.indices = indices; self.weights = weights
            byteOffsets = indices.map { $0 * 3 }; weights32 = weights.map { Int32($0) }
        }
    }
    private let lock = NSLock()
    private var tables: [Int: Table] = [:]

    /// Whether this side pair's table is still cached (not evicted).
    func isCached(sourceSide: Int, targetSide: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return tables[sourceSide << 16 | targetSide] != nil
    }

    func taps(sourceSide: Int, targetSide: Int) -> Table {
        let key = sourceSide << 16 | targetSide
        lock.lock(); defer { lock.unlock() }
        if let table = tables[key] { return table }
        var indices: [Int] = [], weights: [Int] = []
        indices.reserveCapacity(targetSide * 8); weights.reserveCapacity(targetSide * 8)
        for destination in 0..<targetSide {
            let coordinate = Float((Double(destination) + 0.5) * Double(sourceSide) / Double(targetSide) - 0.5)
            let center = Int(floor(coordinate)), fraction = Double(coordinate - Float(center))
            var row = (0..<8).map { i -> Double in
                let x = fraction - Double(i - 3)
                if abs(x) < 1e-12 { return 1 }
                if abs(x) >= 4 { return 0 }
                return sin(.pi * x) * sin(.pi * x / 4) / (.pi * .pi * x * x / 4)
            }
            let sum = row.reduce(0, +)
            row = row.map { $0 / sum }
            indices += (0..<8).map { min(sourceSide - 1, max(0, center + $0 - 3)) }
            weights += row.map { Int(($0 * 2048).rounded(.toNearestOrEven)) }
        }
        let table = Table(indices: indices, weights: weights)
        if tables.count >= 64 { tables.removeAll() }
        tables[key] = table
        return table
    }
}

/// Decoded host frames for the current frame and the next few, decoded concurrently off the render path.
/// Call frames advance one host frame at a time (ping-pong), so the next frames are known in advance.
public final class HostFrameDecoder: @unchecked Sendable {
    private final class Slot: @unchecked Sendable {
        let done = DispatchGroup()
        var result: Result<HostPicture, Error>?
    }
    private let load: @Sendable (Int) throws -> HostPicture
    private let queue = DispatchQueue(label: "companion.host-frame-decode", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var slots: [Int: Slot] = [:]

    init(load: @escaping @Sendable (Int) throws -> HostPicture) { self.load = load }

    /// Returns host `index` decoded (waiting for an in-flight decode) and starts decoding `prefetch`.
    /// Keeps at most the requested frames, so memory stays at (1 + prefetch) decoded host bitmaps.
    public func picture(_ index: Int, prefetch: [Int]) throws -> HostPicture {
        lock.lock()
        let slot = slots[index] ?? start(index)
        for next in prefetch where slots[next] == nil { _ = start(next) }
        let keep = Set([index] + prefetch)
        slots = slots.filter { keep.contains($0.key) }
        lock.unlock()
        slot.done.wait()
        return try slot.result!.get()
    }
    /// Lock must be held.
    private func start(_ index: Int) -> Slot {
        let slot = Slot(), load = self.load
        slot.done.enter()
        queue.async {
            slot.result = Result { try load(index) }
            slot.done.leave()
        }
        slots[index] = slot
        return slot
    }
}
