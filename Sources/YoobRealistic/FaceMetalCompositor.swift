import Foundation
import CoreGraphics
import CoreVideo
import Metal

/// The realistic frame composed on the GPU: host picture, face square (Lanczos-4 resize of the pasted outer crop, 304 or
/// 608 square, to the face box, 8-pixel feather, silence mix), blink picture and white bars, in one pass that reads the
/// decoder's host buffer and writes the frame's IOSurface in place (no CPU copy of either). The CPU loops in
/// `AvatarCompositor` stay the truth: the kernels do the same integer Lanczos (11-bit taps, round by adding 2^21 and
/// shifting 22, clamp) and the same float blends (round half to even), so the frames are bit-identical, and the process
/// only uses the GPU once a self-check against those loops has passed (`shared`; per outer crop size, `passes`). Set
/// AVATAR_METAL_COMPOSE=0 to keep every frame on the CPU.
///
/// The library is compiled at runtime with fast math off (MTLMathMode.safe) and FP contraction off, as the anime
/// compositor's (AvatarDemo Serve320MetalCompositor): a fused multiply-add perturbs a blend input by one ulp and can flip a
/// half-even rounding. Divisions are kept out of the kernels (edge / 8 is edge * 0.125, exact; the blink's edge / 12 comes
/// from a table the CPU fills), so nothing depends on the GPU's division accuracy.
final class FaceMetalCompositor: @unchecked Sendable {
    /// Built, checked and kept for the process; nil when there is no GPU, the flag is off, or the self-check failed.
    static let shared: FaceMetalCompositor? = {
        guard ProcessInfo.processInfo.environment["AVATAR_METAL_COMPOSE"] != "0", let metal = FaceMetalCompositor() else { return nil }
        guard let check = try? metal.selfCheck(), check.maxDifference <= 1 else { return nil }
        metal.parity = check; metal.checkedOuters[CropGeometry.h08.outer] = true
        return metal
    }()

    struct Parity: Sendable { let maxDifference: Int; let differingBytes: Int; let comparedBytes: Int }
    /// What the self-check measured against the CPU loops (the 144 model's 304 outer crop).
    private(set) var parity = Parity(maxDifference: 0, differingBytes: 0, comparedBytes: 0)
    /// Outer crop sides the self-check has run for, and whether it passed: 304 when built (`shared`); another (the 288
    /// model's 608) on its first frame, so the shipped face pays nothing for it and no side reaches the GPU unchecked.
    private var checkedOuters: [Int: Bool] = [:]
    private let checkLock = NSLock()
    /// Frames the GPU has composed in this process (diagnostics: a frame it could not take went to the CPU).
    var framesComposed: Int { lock.withLock { composed } }
    private var composed = 0

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let horizontal: MTLComputePipelineState
    private let frame: MTLComputePipelineState
    /// `LipPicture.sharpened` of the model's crop, written into the outer crop's paste hole before the resize.
    private let sharpen: MTLComputePipelineState
    /// `SpeechBlink`'s edge weights, inset / 12 for inset 0..<12, computed by the CPU exactly as its loop does.
    private let blinkWeights: MTLBuffer
    /// Bound when a frame has no face square or no blink.
    private let empty: MTLBuffer
    private let lock = NSLock()
    /// Lanczos tables per outer crop side and face side, on the GPU: row indices, byte offsets within an outer BGR row, and
    /// weights.
    private var tables: [Int: (rows: MTLBuffer, offsets: MTLBuffer, weights: MTLBuffer)] = [:]

    /// Must mirror `FrameParams` in the kernel source (ints and a float, no padding).
    private struct FrameParams {
        var width: Int32, height: Int32
        var faceX: Int32, faceY: Int32, faceSide: Int32, hasFace: Int32
        var mix: Float
        var blinkX: Int32, blinkY: Int32, blinkWidth: Int32, blinkHeight: Int32, hasBlink: Int32
        var barLeft: Int32, barRight: Int32
        /// The face square is blended in by a paste matte (`AvatarCompositor.FaceSquare.matte`), not the 8-pixel feather.
        var hasMatte: Int32
    }
    /// `AvatarCompositor.matteWeights` on the GPU: a matte byte's alpha, computed by the CPU.
    private let matteWeights: MTLBuffer
    /// Outer crop sides whose paste-matte self-check has run (on the first matted frame of that side), and whether it passed.
    private var checkedMattes: [Int: Bool] = [:]
    /// Crop geometries (by outer side) whose sharpening self-check has run, and whether it passed.
    private var checkedSharpens: [Int: Bool] = [:]
    /// Must mirror `SharpenParams` in the kernel source.
    private struct SharpenParams {
        var output: Int32, outerSide: Int32, margin: Int32, pasteX: Int32, pasteY: Int32, pasteWidth: Int32, pasteHeight: Int32
        var amount: Float
    }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        let options = MTLCompileOptions()
        if #available(iOS 18.0, macOS 15.0, *) { options.mathMode = .safe } else { options.fastMathEnabled = false }
        guard let library = try? device.makeLibrary(source: Self.source, options: options),
              let horizontalFunction = library.makeFunction(name: "face_horizontal"),
              let frameFunction = library.makeFunction(name: "compose_frame"),
              let sharpenFunction = library.makeFunction(name: "sharpen_crop"),
              let horizontal = try? device.makeComputePipelineState(function: horizontalFunction),
              let frame = try? device.makeComputePipelineState(function: frameFunction),
              let sharpen = try? device.makeComputePipelineState(function: sharpenFunction) else { return nil }
        let weights = (0..<SpeechBlink.edgePixels).map { Float($0) / Float(SpeechBlink.edgePixels) }
        guard let blinkWeights = device.makeBuffer(bytes: weights, length: weights.count * 4, options: .storageModeShared),
              let matteWeights = device.makeBuffer(bytes: AvatarCompositor.matteWeights, length: 256 * 4, options: .storageModeShared),
              let empty = device.makeBuffer(length: 16, options: .storageModeShared) else { return nil }
        self.device = device; self.queue = queue; self.horizontal = horizontal; self.frame = frame; self.sharpen = sharpen
        self.blinkWeights = blinkWeights; self.matteWeights = matteWeights; self.empty = empty
    }

    /// Composes `host` (the decoder's BGRA buffer) into `destination` (an IOSurface-backed BGRA buffer of the same size),
    /// waiting for the GPU. False when this frame cannot run here (a buffer without an IOSurface, a Lanczos table whose sums
    /// could leave 32 bits, an outer crop size whose self-check failed): the caller composes it on the CPU.
    func compose(host: CVPixelBuffer, into destination: CVPixelBuffer, face: AvatarCompositor.FaceSquare?,
                 blink: AvatarCompositor.BlinkPatch?, bars: (left: Int, right: Int)) throws -> Bool {
        if let face, !passes(outerSide: face.outerSide) { return false }
        if let face, face.matte != nil, !passesMatte(outerSide: face.outerSide) { return false }
        if let sharpen = face?.sharpen, !passesSharpen(sharpen.geometry) { return false }
        return try dispatch(host: host, into: destination, face: face, blink: blink, bars: bars)
    }

    /// Runs the self-checks a face's frames will need (the outer side, its matte, its sharpening) now, off the frame path:
    /// the first matted or sharpened frame of a call otherwise paid for them (`AvatarPack.prepareLipPicture`).
    func prepare(geometry: CropGeometry, matte: Bool, sharpen: Bool) {
        _ = passes(outerSide: geometry.outer)
        if matte { _ = passesMatte(outerSide: geometry.outer) }
        if sharpen { _ = passesSharpen(geometry) }
    }

    /// Whether the sharpening pass matches the CPU's for this crop geometry, checked the first time it is asked for.
    private func passesSharpen(_ geometry: CropGeometry) -> Bool {
        checkLock.lock(); defer { checkLock.unlock() }
        if let known = checkedSharpens[geometry.outer] { return known }
        let passed = (try? selfCheck(outerSide: geometry.outer, sharpen: geometry)).map { $0.maxDifference <= 1 } ?? false
        checkedSharpens[geometry.outer] = passed
        return passed
    }

    /// Whether the paste matte's self-check passed for this outer crop side, running it the first time a matted frame of it
    /// is asked for (the realistic face never runs it).
    private func passesMatte(outerSide: Int) -> Bool {
        checkLock.lock(); defer { checkLock.unlock() }
        if let known = checkedMattes[outerSide] { return known }
        let passed = (try? selfCheck(outerSide: outerSide, matte: true)).map { $0.maxDifference <= 1 } ?? false
        checkedMattes[outerSide] = passed
        return passed
    }

    /// Whether the self-check passed for this outer crop side, running it the first time the side is asked for.
    private func passes(outerSide: Int) -> Bool {
        checkLock.lock(); defer { checkLock.unlock() }
        if let known = checkedOuters[outerSide] { return known }
        let passed = (try? selfCheck(outerSide: outerSide)).map { $0.maxDifference <= 1 } ?? false
        checkedOuters[outerSide] = passed
        return passed
    }

    /// `compose` without the outer side's self-check (the self-check itself runs through here).
    private func dispatch(host: CVPixelBuffer, into destination: CVPixelBuffer, face: AvatarCompositor.FaceSquare?,
                          blink: AvatarCompositor.BlinkPatch?, bars: (left: Int, right: Int)) throws -> Bool {
        let width = CVPixelBufferGetWidth(destination), height = CVPixelBufferGetHeight(destination)
        guard CVPixelBufferGetWidth(host) == width, CVPixelBufferGetHeight(host) == height,
              CVPixelBufferGetPixelFormatType(host) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetPixelFormatType(destination) == kCVPixelFormatType_32BGRA,
              let hostTexture = texture(host, usage: .shaderRead), let frameTexture = texture(destination, usage: .shaderWrite) else { return false }
        if let blink, blink.x < 0 || blink.y < 0 || blink.x + blink.width > width || blink.y + blink.height > height
            || blink.bgra.count < blink.width * blink.height * 4 { return false }
        if let face, face.x < 0 || face.y < 0 || face.x + face.side > width || face.y + face.side > height
            || face.outerSide < 1 || face.outer.count < face.outerSide * face.outerSide * 3 { return false }
        if let face, let matte = face.matte, matte.count < face.side * face.side { return false }
        guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else { throw AvatarError.unavailable }
        var params = FrameParams(width: Int32(width), height: Int32(height), faceX: 0, faceY: 0, faceSide: 0, hasFace: 0, mix: 0,
                                 blinkX: 0, blinkY: 0, blinkWidth: 0, blinkHeight: 0, hasBlink: 0,
                                 barLeft: Int32(bars.left), barRight: Int32(bars.right), hasMatte: 0)
        var horizontalSums = empty, table = (rows: empty, offsets: empty, weights: empty), matteBuffer = empty
        if let face, let matte = face.matte {
            guard let buffer = matte.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: face.side * face.side,
                                                                         options: .storageModeShared) }) else {
                encoder.endEncoding(); return false
            }
            matteBuffer = buffer; params.hasMatte = 1
        }
        if let face {
            let outerSide = face.outerSide
            guard let taps = self.table(outer: outerSide, side: face.side),
                  let outer = device.makeBuffer(bytes: face.outer, length: outerSide * outerSide * 3, options: .storageModeShared),
                  let sums = device.makeBuffer(length: outerSide * face.side * 3 * 4, options: .storageModePrivate) else {
                encoder.endEncoding(); return false
            }
            table = taps; horizontalSums = sums
            if let job = face.sharpen {
                // The crop sharpened into the outer crop's hole first (the horizontal pass below reads the result).
                let geometry = job.geometry, paste = geometry.paste
                guard job.crop.count == geometry.outputBytes, geometry.outer == outerSide,
                      let crop = job.crop.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: geometry.outputBytes, options: .storageModeShared) }) else {
                    encoder.endEncoding(); return false
                }
                var sharpenParams = SharpenParams(output: Int32(geometry.output), outerSide: Int32(outerSide), margin: Int32(geometry.margin),
                                                  pasteX: Int32(paste.x), pasteY: Int32(paste.y), pasteWidth: Int32(paste.width),
                                                  pasteHeight: Int32(paste.height), amount: job.amount)
                encoder.setComputePipelineState(sharpen)
                encoder.setBuffer(crop, offset: 0, index: 0)
                encoder.setBuffer(outer, offset: 0, index: 1)
                encoder.setBytes(&sharpenParams, length: MemoryLayout<SharpenParams>.stride, index: 2)
                encoder.dispatchThreads(MTLSize(width: paste.width, height: paste.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                encoder.memoryBarrier(scope: .buffers)
            }
            var side = Int32(face.side), rows = Int32(outerSide)
            encoder.setComputePipelineState(horizontal)
            encoder.setBuffer(outer, offset: 0, index: 0)
            encoder.setBuffer(taps.offsets, offset: 0, index: 1)
            encoder.setBuffer(taps.weights, offset: 0, index: 2)
            encoder.setBuffer(sums, offset: 0, index: 3)
            encoder.setBytes(&side, length: 4, index: 4)
            encoder.setBytes(&rows, length: 4, index: 5)
            encoder.dispatchThreads(MTLSize(width: face.side, height: outerSide, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 32, height: max(1, horizontal.maxTotalThreadsPerThreadgroup / 32 / 4), depth: 1))
            params.faceX = Int32(face.x); params.faceY = Int32(face.y); params.faceSide = side; params.hasFace = 1; params.mix = face.mix
        }
        var patch = empty
        if let blink {
            guard let buffer = blink.bgra.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: blink.width * blink.height * 4,
                                                                               options: .storageModeShared) }) else {
                encoder.endEncoding(); return false
            }
            patch = buffer
            params.blinkX = Int32(blink.x); params.blinkY = Int32(blink.y); params.blinkWidth = Int32(blink.width)
            params.blinkHeight = Int32(blink.height); params.hasBlink = 1
        }
        // The vertical pass reads the horizontal sums: Metal orders the two dispatches (tracked hazards on one encoder).
        encoder.setComputePipelineState(frame)
        encoder.setTexture(hostTexture, index: 0)
        encoder.setTexture(frameTexture, index: 1)
        encoder.setBuffer(horizontalSums, offset: 0, index: 0)
        encoder.setBuffer(table.rows, offset: 0, index: 1)
        encoder.setBuffer(table.weights, offset: 0, index: 2)
        encoder.setBuffer(patch, offset: 0, index: 3)
        encoder.setBuffer(blinkWeights, offset: 0, index: 4)
        encoder.setBytes(&params, length: MemoryLayout<FrameParams>.stride, index: 5)
        encoder.setBuffer(matteBuffer, offset: 0, index: 6)
        encoder.setBuffer(matteWeights, offset: 0, index: 7)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.status == .completed else { throw AvatarError.unavailable }
        lock.withLock { composed += 1 }
        if face?.sharpen != nil, commands.gpuEndTime > commands.gpuStartTime {
            LipPictureTiming.shared.addGPU((commands.gpuEndTime - commands.gpuStartTime) * 1000)
        }
        return true
    }

    /// A texture over the buffer's IOSurface, its BGRA bytes read as four 8-bit unsigned integers (channel 0 is blue), so
    /// the kernels move exact byte values with no normalized conversion.
    private func texture(_ buffer: CVPixelBuffer, usage: MTLTextureUsage) -> MTLTexture? {
        guard let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Uint, width: CVPixelBufferGetWidth(buffer),
                                                                  height: CVPixelBufferGetHeight(buffer), mipmapped: false)
        descriptor.usage = usage; descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)
    }

    /// The Lanczos table for `outer` -> `side` on the GPU. Nil when the kernel's split vertical sums could leave Int32: with
    /// W = Σ|w| over the worst row, |hi sum| <= (255 W / 2^11 + 1) W and the lo sum <= 2047 W + 2^21 (the packs' tables:
    /// W ~ 3.5e3, sums under 8e6).
    private func table(outer: Int, side: Int) -> (rows: MTLBuffer, offsets: MTLBuffer, weights: MTLBuffer)? {
        lock.lock(); defer { lock.unlock() }
        if let table = tables[outer << 16 | side] { return table }
        let taps = LanczosTaps.shared.taps(sourceSide: outer, targetSide: side)
        let worst = (0..<side).map { row in taps.weights[(row * 8)..<(row * 8 + 8)].reduce(0) { $0 + abs($1) } }.max() ?? 0
        guard (255 * worst / 2048 + 1) * worst <= Int(Int32.max), 2047 * worst + (1 << 21) <= Int(Int32.max) else { return nil }
        let rows = taps.indices.map { Int32($0) }, offsets = taps.byteOffsets.map { Int32($0) }
        guard let rowBuffer = device.makeBuffer(bytes: rows, length: rows.count * 4, options: .storageModeShared),
              let offsetBuffer = device.makeBuffer(bytes: offsets, length: offsets.count * 4, options: .storageModeShared),
              let weightBuffer = device.makeBuffer(bytes: taps.weights32, length: taps.weights32.count * 4, options: .storageModeShared) else { return nil }
        let table = (rows: rowBuffer, offsets: offsetBuffer, weights: weightBuffer)
        if tables.count >= 64 { tables.removeAll() }
        tables[outer << 16 | side] = table
        return table
    }

    /// Composes synthetic frames both ways (random host, outer crops of `outerSide` and blink pictures; H08's largest,
    /// smallest and commonest face sides, and with another outer crop the 288 pup's 400 in place of the commonest; the
    /// silence mix at 0, a ramp value and 0.5; a blink over the face's edge; bars on both sides) and compares every byte
    /// of every row. `matte`: each face square blended by a paste matte instead (random bytes with runs of 0 and 255, as a
    /// real matte's outside and inside).
    func selfCheck(outerSide: Int = CropGeometry.h08.outer, matte: Bool = false, sharpen: CropGeometry? = nil) throws -> Parity {
        let h08 = outerSide == CropGeometry.h08.outer
        let width = h08 ? 400 : 480, height = h08 ? 560 : 600
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func random() -> UInt8 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return UInt8(truncatingIfNeeded: seed >> 33) }
        let host = try FramePool.shared.buffer(width: width, height: height)
        CVPixelBufferLockBaseAddress(host, [])
        if let base = CVPixelBufferGetBaseAddress(host) {
            let rowBytes = CVPixelBufferGetBytesPerRow(host), bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height { for x in 0..<width { for c in 0..<3 { bytes[y * rowBytes + x * 4 + c] = random() }; bytes[y * rowBytes + x * 4 + 3] = 255 } }
        }
        CVPixelBufferUnlockBaseAddress(host, [])
        let blink = AvatarCompositor.BlinkPatch(x: 40, y: 90, width: 316, height: 139,
                                                bgra: Data((0..<(316 * 139 * 4)).map { $0 % 4 == 3 ? 255 : random() }))
        var worst = 0, differing = 0, compared = 0
        for (side, mix, withBlink, bars) in [(h08 ? 341 : 400, Float(0), true, (2, 3)), (333, 0.25, false, (0, 0)), (347, 0.5, true, (0, 5)),
                                             (342, 0, false, (4, 0))] {
            var face = AvatarCompositor.FaceSquare(outer: (0..<(outerSide * outerSide * 3)).map { _ in random() }, outerSide: outerSide,
                                                   x: 30, y: 150, side: side, mix: mix)
            if matte { face.matte = Data((0..<(side * side)).map { index -> UInt8 in let v = random(); return index % 7 == 0 ? 0 : index % 5 == 0 ? 255 : v }) }
            if let sharpen {
                // A random crop (every rounding and clamp case) at two amounts, the one used and a strong one.
                face.sharpen = AvatarCompositor.Sharpen(crop: Data((0..<sharpen.outputBytes).map { _ in random() }), amount: mix == 0 ? 0.9 : 2.5,
                                                        geometry: sharpen)
            }
            let cpu = try FramePool.shared.buffer(width: width, height: height), gpu = try FramePool.shared.buffer(width: width, height: height)
            try AvatarCompositor.composeCPU(host: .pixels(host, colorSpace: nil), space: CGColorSpaceCreateDeviceRGB(), into: cpu, face: face,
                                            blink: withBlink ? blink : nil, bars: bars, scanHost: false) { _ in }
            guard try dispatch(host: host, into: gpu, face: face, blink: withBlink ? blink : nil, bars: bars) else { throw AvatarError.unavailable }
            let difference = Self.difference(cpu, gpu)
            worst = max(worst, difference.max); differing += difference.differing; compared += width * height * 4
        }
        return Parity(maxDifference: worst, differingBytes: differing, comparedBytes: compared)
    }

    /// Largest byte difference and differing bytes between two BGRA buffers of one size.
    static func difference(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> (max: Int, differing: Int) {
        CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        guard let first = CVPixelBufferGetBaseAddress(a)?.assumingMemoryBound(to: UInt8.self),
              let second = CVPixelBufferGetBaseAddress(b)?.assumingMemoryBound(to: UInt8.self) else { return (255, 1) }
        let width = CVPixelBufferGetWidth(a), height = CVPixelBufferGetHeight(a)
        let strideA = CVPixelBufferGetBytesPerRow(a), strideB = CVPixelBufferGetBytesPerRow(b)
        var worst = 0, differing = 0
        for y in 0..<height {
            for i in 0..<(width * 4) {
                let d = abs(Int(first[y * strideA + i]) - Int(second[y * strideB + i]))
                if d > 0 { differing += 1; worst = max(worst, d) }
            }
        }
        return (worst, differing)
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    // Swift never contracts a*b+c into fma; a fused last-ulp difference at an exact .5 blend input flips the half-even
    // rounding against the CPU loops. With fast math off (compile options) this keeps every float op as the CPU does it.
    #pragma STDC FP_CONTRACT OFF

    struct FrameParams {
        int width, height;
        int faceX, faceY, faceSide, hasFace;
        float mix;
        int blinkX, blinkY, blinkWidth, blinkHeight, hasBlink;
        int barLeft, barRight;
        int hasMatte;
    };

    // AvatarCompositor.resizeLanczos4, horizontal pass: output (x, row) of the intermediate, one row per outer crop row
    // (`outerSide`: 304 or 608), 8 taps per channel in wrapping 32-bit ints, as the CPU loop.
    kernel void face_horizontal(device const uchar *outer [[buffer(0)]], device const int *offsets [[buffer(1)]],
                                device const int *weights [[buffer(2)]], device int *sums [[buffer(3)]],
                                constant int &side [[buffer(4)]], constant int &outerSide [[buffer(5)]],
                                uint2 gid [[thread_position_in_grid]]) {
        int x = int(gid.x), row = int(gid.y);
        if (x >= side || row >= outerSide) return;
        device const uchar *source = outer + row * outerSide * 3;
        device const int *o = offsets + x * 8;
        device const int *w = weights + x * 8;
        for (int c = 0; c < 3; c++) {
            int value = 0;
            for (int k = 0; k < 8; k++) value += int(source[o[k] + c]) * w[k];
            sums[(row * side + x) * 3 + c] = value;
        }
    }

    struct SharpenParams {
        int output, outerSide, margin, pasteX, pasteY, pasteWidth, pasteHeight;
        float amount;
    };

    // LipPicture.sharpened for the paste hole: the crop's 5 x 5 binomial ([1 4 6 4 1] / 16 each way, edges clamped) summed
    // exactly in ints, blur = sum / 256 (a power of two: exact), value + amount (value - blur) rounded half to even and
    // clamped, written where AvatarCompositor.pastedOuter puts the hole in the outer crop.
    kernel void sharpen_crop(device const uchar *crop [[buffer(0)]], device uchar *outer [[buffer(1)]],
                             constant SharpenParams &p [[buffer(2)]], uint2 gid [[thread_position_in_grid]]) {
        int hx = int(gid.x), hy = int(gid.y);
        if (hx >= p.pasteWidth || hy >= p.pasteHeight) return;
        int x = p.pasteX + hx, y = p.pasteY + hy, n = p.output;
        int taps[5] = {1, 4, 6, 4, 1};
        for (int c = 0; c < 3; c++) {
            int sum = 0;
            for (int j = 0; j < 5; j++) {
                int row = clamp(y + j - 2, 0, n - 1) * n;
                int line = 0;
                for (int i = 0; i < 5; i++) line += taps[i] * int(crop[(row + clamp(x + i - 2, 0, n - 1)) * 3 + c]);
                sum += taps[j] * line;
            }
            float value = float(crop[(y * n + x) * 3 + c]), blur = float(sum) * 0.00390625f;
            float sharp = value + p.amount * (value - blur);
            outer[((y + p.margin) * p.outerSide + p.margin + x) * 3 + c] = uchar(clamp(rint(sharp), 0.0f, 255.0f));
        }
    }

    // One frame pixel: the host's, then the face square (vertical Lanczos pass, round and clamp, feathered blend, or the
    // paste matte's alpha where the pack has one), then the blink picture, then the white bars, in the CPU's order. Alpha is
    // the host's (opaque).
    kernel void compose_frame(texture2d<uint, access::read> host [[texture(0)]], texture2d<uint, access::write> frame [[texture(1)]],
                              device const int *sums [[buffer(0)]], device const int *rows [[buffer(1)]],
                              device const int *weights [[buffer(2)]], device const uchar *blink [[buffer(3)]],
                              constant float *blinkWeights [[buffer(4)]], constant FrameParams &p [[buffer(5)]],
                              device const uchar *matte [[buffer(6)]], constant float *matteWeights [[buffer(7)]],
                              uint2 gid [[thread_position_in_grid]]) {
        int x = int(gid.x), y = int(gid.y);
        if (x >= p.width || y >= p.height) return;
        uint4 pixel = host.read(gid);
        if (x < p.barLeft || x >= p.width - p.barRight) { frame.write(uint4(0, 0, 0, pixel.a), gid); return; }
        int side = p.faceSide, fx = x - p.faceX, fy = y - p.faceY;
        // A matte byte of 0 keeps the host's pixel (AvatarCompositor.pasteMatted).
        uint matted = (p.hasFace != 0 && p.hasMatte != 0 && fx >= 0 && fy >= 0 && fx < side && fy < side) ? uint(matte[fy * side + fx]) : 255u;
        if (p.hasFace != 0 && fx >= 0 && fy >= 0 && fx < side && fy < side && matted != 0u) {
            int edge = min(min(fx + 1, side - fx), min(fy + 1, side - fy));
            bool replace = p.hasMatte != 0 ? (matted == 255u && p.mix == 0.0f) : (edge >= 8 && p.mix == 0.0f);
            float alpha = p.hasMatte != 0 ? matteWeights[matted] * (1.0f - p.mix) : min(1.0f, float(edge) * 0.125f) * (1.0f - p.mix);
            for (int c = 0; c < 3; c++) {
                // The CPU sums in Int64: up to 255 * (Σ|w|)^2 ~ 3.1e9 for these tables, past Int32. Each horizontal sum h is
                // split as h = hi * 2^11 + lo (lo in 0..<2^11), both halves summed exactly in 32 bits, and
                // floor((hi_sum * 2^11 + lo_sum + 2^21) / 2^22) == (hi_sum + ((lo_sum + 2^21) >> 11)) >> 11 (arithmetic shifts
                // floor, as the CPU's), so the rounded value is the CPU's for every input.
                int high = 0, low = 0;
                for (int k = 0; k < 8; k++) {
                    int h = sums[(rows[fy * 8 + k] * side + fx) * 3 + c], w = weights[fy * 8 + k];
                    high += (h >> 11) * w; low += (h & 2047) * w;
                }
                int up = clamp((high + ((low + (1 << 21)) >> 11)) >> 11, 0, 255);
                if (replace) { pixel[c] = uint(up); continue; }
                float value = alpha * float(up) + (1.0f - alpha) * float(pixel[c]);
                pixel[c] = uint(clamp(rint(value), 0.0f, 255.0f));
            }
        }
        int bx = x - p.blinkX, by = y - p.blinkY;
        if (p.hasBlink != 0 && bx >= 0 && by >= 0 && bx < p.blinkWidth && by < p.blinkHeight) {
            int inset = min(min(bx + 1, p.blinkWidth - bx), min(by + 1, p.blinkHeight - by));
            device const uchar *source = blink + (by * p.blinkWidth + bx) * 4;
            for (int c = 0; c < 3; c++) {
                if (inset >= \(SpeechBlink.edgePixels)) { pixel[c] = uint(source[c]); continue; }
                float weight = blinkWeights[inset];
                float value = weight * float(source[c]) + (1.0f - weight) * float(pixel[c]);
                pixel[c] = uint(clamp(rint(value), 0.0f, 255.0f));
            }
        }
        frame.write(pixel, gid);
    }
    """
}
