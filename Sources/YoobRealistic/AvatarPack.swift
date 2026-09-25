import Foundation
import CryptoKit
import ImageIO

/// Pack-relative files whose checksum already matched their receipt.
final class VerifiedFiles: @unchecked Sendable {
    private let lock = NSLock()
    private var names: Set<String> = []
    func contains(_ name: String) -> Bool { lock.lock(); defer { lock.unlock() }; return names.contains(name) }
    func insert(_ name: String) { lock.lock(); names.insert(name); lock.unlock() }
}

public enum AvatarError: Error, LocalizedError {
    case invalidPack(String), unavailable, invalidAudio
    public var errorDescription: String? {
        switch self {
        case .invalidPack(let reason): "The companion assets could not be verified (\(reason))."
        case .unavailable: "The companion renderer is unavailable."
        case .invalidAudio: "The companion received an invalid audio window."
        }
    }
}

public struct AvatarManifest: Codable, Sendable {
    public struct HostFrame: Codable, Sendable {
        public let row: Int
        public let bbox: [Int]
        public let width: Int
        public let height: Int
        public let file: String
        /// Video frame index inside the shared container; present only in videoContainer packs, where it equals row.
        public let frame: Int?
    }
    public struct Receipt: Codable, Sendable { public let bytes: Int; public let sha256: String }
    /// A rectangle in the renderer's input crop (`innerSize` pixels).
    public struct Rect: Codable, Sendable, Equatable {
        public let x: Int, y: Int, width: Int, height: Int
        public init(x: Int, y: Int, width: Int, height: Int) { self.x = x; self.y = y; self.width = width; self.height = height }
    }
    public let version: Int
    public let identity: String
    public let fps: Int
    public let sampleRate: Int
    public let samplesPerFrame: Int
    public let encoderTailSamples: Int
    public let channelOrder: String
    public let innerSize: Int
    public let outerSize: Int
    public let outputSize: Int
    /// The renderer's mouth hole in input-crop pixels (`CropGeometry`); a manifest without one must be the 144 model's.
    public let hole: Rect?
    /// Frame pixels over which the pasted face square blends into the host frame; the compositor's is 8.
    public let featherPixels: Int?
    public let lookahead: Int
    public let leftContext: Int
    public let rightContext: Int
    public let bootstrap: Int
    public let waveformMean: Float
    public let waveformStd: Float
    public let sourceHostFrames: Int
    public let runtimeEncoder: String
    public let encoderWindowFrames: [Int]
    public let frames: [HostFrame]
    public let files: [String: Receipt]
    /// True when every host frame lives in one shared HEVC video (frame.file, decoded with VideoToolbox).
    public let videoContainer: Bool?
    /// Distance between keyframes in the shared video; seeks land on a multiple of this. Defaults to 15.
    public let videoKeyframeInterval: Int?
    /// How the model's face square is pasted over the host, when not the realistic way (the whole square over an 8-pixel
    /// feather). Absent in the H08 packs.
    public let paste: Paste?
    public struct Paste: Codable, Sendable {
        /// A file of one alpha picture per host, in host order, each the host's face box (`bbox`: side x side bytes, row by
        /// row, 255 = the model's pixel, 0 = the host's own): only that much of the model's square is pasted, and the rest of
        /// the box stays the host's picture untouched. The anime's steady paste (the Luna app's study): a
        /// mouth-shaped patch clipped to the host face, so her own jaw line, neck and collar stay.
        public let matte: String?
        /// The steady paste in time (`SteadyFilter`): each model crop blended with the previous one moved into its face box.
        public let temporal: Temporal?
        public struct Temporal: Codable, Sendable, Equatable {
            /// The motion gate's smoothstep, in grey levels (0-255), and the new crop's least weight.
            public let low: Float, high: Float, floor: Float
            /// Gaussian sigma of the difference map, in model input pixels.
            public let blur: Float
            /// New-frame weight deep in silence while the lips seal or release (1 or absent = off).
            public let silenceEMA: Float?
        }
    }
}

/// The renderer's crop sizes, read from the pack's manifest and checked at load, so a lip model of another size takes a new
/// pack rather than new code. The model reads a square `inner` crop of each host face and draws a square `output` crop,
/// `scale` times as fine. The pack's crops are cut as the pack tools cut them: the face box area-resized to `face`
/// pixels, whose centred `inner` is the model's input, and to `outer` = `scale` x `face` pixels, the host's own face square
/// at the output's scale, with the output centred in it (`margin` all round). Only the model's mouth `hole` (input pixels;
/// `paste` in output pixels) is pasted into that square: the rest of it stays the host's picture.
/// H08 and the 144 pup: inner 144, output 288, outer 304 (face 152), hole x 4, y 4, 135 x 130. The 288 pup: 288, 576, 608
/// (face 304), hole 8, 8, 270 x 260.
public struct CropGeometry: Sendable, Equatable {
    public let inner: Int
    public let output: Int
    public let outer: Int
    public let hole: AvatarManifest.Rect
    /// Output pixels per input pixel.
    public var scale: Int { output / inner }
    /// The side of the crop whose centred `inner` is the model's input.
    public var face: Int { outer / scale }
    /// Outer-crop pixels on each side of the output.
    public var margin: Int { (outer - output) / 2 }
    /// The hole in output pixels: the part of the model's crop pasted into the outer crop.
    public var paste: AvatarManifest.Rect {
        .init(x: hole.x * scale, y: hole.y * scale, width: hole.width * scale, height: hole.height * scale)
    }
    /// The pack's raw crops (`inner144.bgr`, `outer304.bgr` at 144) and the bytes of one crop of each kind (BGR).
    public var innerFile: String { "inner\(inner).bgr" }
    public var outerFile: String { "outer\(outer).bgr" }
    public var innerBytes: Int { inner * inner * 3 }
    public var outerBytes: Int { outer * outer * 3 }
    public var outputBytes: Int { output * output * 3 }
    /// The 144 lip model's (H08, the 144 pup).
    public static let h08 = CropGeometry(inner: 144, output: 288, outer: 304, hole: .init(x: 4, y: 4, width: 135, height: 130))!

    /// Nil unless the sizes nest as described: a whole scale, a face crop no smaller than the input with an even border
    /// (so the input is its exact centre and the margin whole), and the hole inside the input.
    public init?(inner: Int, output: Int, outer: Int, hole: AvatarManifest.Rect) {
        guard (16...1024).contains(inner), output >= inner, output % inner == 0, outer <= 4096, outer % (output / inner) == 0 else { return nil }
        let face = outer / (output / inner)
        guard face >= inner, (face - inner) % 2 == 0, hole.x >= 0, hole.y >= 0, hole.width > 0, hole.height > 0,
              hole.x + hole.width <= inner, hole.y + hole.height <= inner else { return nil }
        self.inner = inner; self.output = output; self.outer = outer; self.hole = hole
    }
    /// The manifest's geometry. A manifest without a hole must be the 144 one; a feather must be the compositor's 8
    /// (`AvatarCompositor.pasteFace` and the Metal kernel blend over 8 pixels).
    public init?(manifest: AvatarManifest) {
        let is144 = manifest.innerSize == 144 && manifest.outputSize == 288 && manifest.outerSize == 304
        guard manifest.featherPixels.map({ $0 == 8 }) ?? true, let hole = manifest.hole ?? (is144 ? Self.h08.hole : nil) else { return nil }
        self.init(inner: manifest.innerSize, output: manifest.outputSize, outer: manifest.outerSize, hole: hole)
    }
}

public struct AvatarPack: Sendable {
    public let root: URL
    public let manifest: AvatarManifest
    public let manifestHash: String
    /// The crop sizes and mouth hole the manifest declares (`CropGeometry`).
    public let geometry: CropGeometry
    /// The lip model's audio windows the manifest declares (`LipWindows`): H08's lookahead 9, or a low-lookahead model's.
    public let windows: LipWindows
    public let innerPixels: Data
    public let outerPixels: Data
    public let closedAudio: [Float]
    /// Decoded host frames with read-ahead, shared by every copy of this pack.
    public let hostFrames: HostFrameDecoder
    /// White side bars found on each host frame (`AvatarCompositor`), shared by every copy of this pack.
    let whiteBars = WhiteBarCache()
    let verified: VerifiedFiles
    /// The paste matte's pictures (`AvatarManifest.Paste.matte`), memory-mapped, and where each host's starts; nil for the
    /// realistic paste.
    let matte: (pictures: Data, offsets: [Int])?
    /// Host `index`'s paste matte (its face box side squared, row by row), nil for the realistic paste.
    func matte(host index: Int) -> Data? {
        guard let matte, matte.offsets.indices.contains(index) else { return nil }
        let side = manifest.frames[index].bbox[2] - manifest.frames[index].bbox[0], start = matte.offsets[index]
        return matte.pictures.subdata(in: start..<(start + side * side))
    }
    public init(root: URL) throws {
        self.root = root.resolvingSymlinksInPath()
        let data = try Data(contentsOf: self.root.appendingPathComponent("manifest.json"))
        guard data.count <= 2_000_000 else { throw AvatarError.invalidPack("manifest size") }
        manifest = try JSONDecoder().decode(AvatarManifest.self, from: data)
        manifestHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard manifest.version == 1, manifest.fps == 25, manifest.sampleRate == 16000,
              manifest.samplesPerFrame == 640, manifest.encoderTailSamples == 80,
              manifest.channelOrder == "BGR", let windows = LipWindows(manifest: manifest),
              manifest.waveformMean.isFinite, manifest.waveformStd.isFinite, manifest.waveformStd > 0.000001,
              manifest.frames.count == manifest.sourceHostFrames, (2...5250).contains(manifest.frames.count),
              manifest.encoderWindowFrames == [8] + Array(13...21) else { throw AvatarError.invalidPack("runtime contract") }
        guard let geometry = CropGeometry(manifest: manifest) else { throw AvatarError.invalidPack("crop geometry") }
        self.geometry = geometry; self.windows = windows
        for (index, frame) in manifest.frames.enumerated() {
            guard frame.row == index, frame.bbox.count == 4, (1...4096).contains(frame.width), (1...4096).contains(frame.height),
                  frame.bbox[0] >= 0, frame.bbox[1] >= 0, frame.bbox[2] <= frame.width, frame.bbox[3] <= frame.height,
                  frame.bbox[2] > frame.bbox[0], frame.bbox[3] > frame.bbox[1], frame.bbox[3] - frame.bbox[1] == frame.bbox[2] - frame.bbox[0],
                  manifest.files[frame.file] != nil else { throw AvatarError.invalidPack("host geometry") }
        }
        let receipts = manifest.files, assetRoot = self.root
        func load(_ relative: String, expected: Int) throws -> Data {
            guard let receipt = receipts[relative], receipt.bytes == expected else { throw AvatarError.invalidPack(relative) }
            let path = try Self.path(relative, root: assetRoot)
            let value = try Data(contentsOf: path, options: .mappedIfSafe)
            guard value.count == expected, SHA256.hash(data: value).map({ String(format: "%02x", $0) }).joined() == receipt.sha256 else { throw AvatarError.invalidPack(relative) }
            return value
        }
        let hostVideo = try Self.hostVideo(manifest: manifest, root: assetRoot)
        if receipts[geometry.innerFile] == nil, receipts[geometry.outerFile] == nil, let hostVideo, let videoFile = manifest.frames.first?.file {
            // A shipped pack without its raw crops (121 MB saved in the app): rebuild them from the verified host video once,
            // then map the cached copy on later launches (`DerivedCrops`).
            let manifestNow = manifest
            _ = try Self.verifiedURL(videoFile, root: assetRoot, manifest: manifestNow, verified: VerifiedFiles())
            let crops = try DerivedCrops.load(manifest: manifestNow, manifestHash: manifestHash, geometry: geometry) {
                try hostVideo.image(forVideoFrame: $0)
            }
            innerPixels = crops.inner; outerPixels = crops.outer
        } else {
            innerPixels = try load(geometry.innerFile, expected: manifest.frames.count * geometry.innerBytes)
            outerPixels = try load(geometry.outerFile, expected: manifest.frames.count * geometry.outerBytes)
        }
        let closed = try load("closed_audio.f32", expected: 40 * 1024 * 4)
        closedAudio = closed.withUnsafeBytes { raw in
            (0..<(40 * 1024)).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
        guard closedAudio.allSatisfy(\.isFinite) else { throw AvatarError.invalidPack("closed audio") }
        if let name = manifest.paste?.matte {
            // One face box of alpha per host, host after host (checked against its receipt like the crops).
            var offsets: [Int] = [], total = 0
            for frame in manifest.frames { offsets.append(total); total += (frame.bbox[2] - frame.bbox[0]) * (frame.bbox[2] - frame.bbox[0]) }
            matte = (try load(name, expected: total), offsets)
        } else { matte = nil }
        let verified = VerifiedFiles(), manifest = self.manifest, packRoot = self.root
        self.verified = verified
        if let video = hostVideo, let videoFile = manifest.frames.first?.file {
            hostFrames = HostFrameDecoder { index in
                let host = manifest.frames[index]
                _ = try AvatarPack.verifiedURL(videoFile, root: packRoot, manifest: manifest, verified: verified)
                let picture = try video.picture(forVideoFrame: index)
                guard picture.width == host.width, picture.height == host.height else { throw AvatarError.invalidPack("host image") }
                return picture
            }
            return
        }
        hostFrames = HostFrameDecoder { index in
            let host = manifest.frames[index]
            let url = try AvatarPack.verifiedURL(host.file, root: packRoot, manifest: manifest, verified: verified)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                  image.width == host.width, image.height == host.height else { throw AvatarError.invalidPack("host image") }
            return .image(image)
        }
    }
    /// The shared host video of a videoContainer pack (nil for a pack of still frames).
    static func hostVideo(manifest: AvatarManifest, root: URL) throws -> HostVideoDecoder? {
        guard manifest.videoContainer == true else { return nil }
        guard let videoFile = manifest.frames.first?.file, manifest.frames.allSatisfy({ $0.file == videoFile }),
              manifest.frames.allSatisfy({ $0.frame == nil || $0.frame == $0.row }) else { throw AvatarError.invalidPack("host video") }
        return HostVideoDecoder(url: try path(videoFile, root: root), keyframeInterval: manifest.videoKeyframeInterval ?? 15,
                                frameCount: manifest.frames.count, frameRate: manifest.fps)
    }
    public static func path(_ relative: String, root: URL) throws -> URL {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\\"),
              relative.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw AvatarError.invalidPack("path") }
        let resolved = root.appendingPathComponent(relative).resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw AvatarError.invalidPack("path escape") }
        return resolved
    }
    public func verifiedURL(_ relative: String) throws -> URL {
        try Self.verifiedURL(relative, root: root, manifest: manifest, verified: verified)
    }
    /// Checksums each file once per loaded pack; later calls for the same file skip the hash. The files are
    /// read-only pack assets, so re-hashing a host frame on every rendered frame only cost time.
    static func verifiedURL(_ relative: String, root: URL, manifest: AvatarManifest, verified: VerifiedFiles) throws -> URL {
        let path = try Self.path(relative, root: root)
        guard let receipt = manifest.files[relative] else { throw AvatarError.invalidPack("missing receipt") }
        if verified.contains(relative) { return path }
        let stream = try FileHandle(forReadingFrom: path); defer { try? stream.close() }
        var hash = SHA256(), bytes = 0
        while let chunk = try stream.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk); bytes += chunk.count }
        guard bytes == receipt.bytes, hash.finalize().map({ String(format: "%02x", $0) }).joined() == receipt.sha256 else { throw AvatarError.invalidPack("checksum") }
        verified.insert(relative)
        return path
    }
    public func verifyModel(_ directory: String) throws -> URL {
        let names = manifest.files.keys.filter { $0.hasPrefix(directory + "/") }
        guard names.count >= 3 else { throw AvatarError.invalidPack("model receipt") }
        for name in names { _ = try verifiedURL(name) }
        return try Self.path(directory, root: root)
    }
    /// When set, call frames walk only this calm stretch of the host clip, forward and back, holding each host frame for
    /// `framesPerHost` call frames. The call screen's idle frames are rendered from the same stretch, so switching between
    /// idle and speech never jumps to a different head pose.
    public var calmHosts: CalmHostWindow?
    /// When set with `calmHosts`, speaking frames on poses near the rest pose blink with the idle face's own blink pictures.
    public var blink: SpeechBlink?
    /// When set, the model's crop is sharpened and only its mouth region pasted, the host frame's own pixels around it
    /// (`LipPicture`). Nil composes exactly as before; a pack with its own paste matte keeps that matte.
    public var lipPicture: LipPicture?
    /// The mouth region's mattes by face side, shared by every copy of this pack.
    let lipMattes = LipMatteCache()
    public struct CalmHostWindow: Sendable, Equatable {
        public let first: Int, count: Int, framesPerHost: Int
        /// Hosts outside the calm stretch that render like it (its pose twins): the still idle face takes over from speech
        /// on them as cleanly as on the calm stretch itself (a stall walk hands over there).
        public let twins: [ClosedRange<Int>]
        /// Hosts near enough the rest pose that the idle face's blink pictures (aligned to `first`) fit their eyes: rendered
        /// frames on them may blink (`SpeechBlink`).
        public let blinkHosts: [ClosedRange<Int>]
        /// The clip's own blink: a scheduled speech blink within `StreamingAvatar.sourceBlinkSpacingFrames` of a pass through
        /// it is dropped, and none starts inside it.
        public let closedEyes: ClosedRange<Int>?
        /// The lanes the head path walks in silence (`HostPath`): stretches where her eyes are open and the head moves as it
        /// does when she listens or between phrases, each bounded by slow steps so the path turns there without reversing a
        /// fast motion. Those in `closedLipLanes` have her real lips closed and show the clip's own frame; the others (the
        /// chin lift) show the model's sealed mouth over her moving head.
        public let lanes: [ClosedRange<Int>]
        public let closedLipLanes: [ClosedRange<Int>]
        /// The crossings the path takes between silence lanes, in order: host pairs that render alike (within the clip's own
        /// frame-to-frame p95). A lane not in `closedLipLanes` is left at its first exit instead (`exits`).
        public let itinerary: [HostPath.Crossing]
        /// Call frames the path stays in a silence lane before heading for its exit, cycled per visit; `openLipStays` for a
        /// silence lane without her real lips closed (the lift with the model's sealed mouth), shorter so silence alternates
        /// between her moving and her own still frames.
        public let stays: [Int]
        public let openLipStays: [Int]
        /// The speech lanes: stretches where she talks in the footage, her head, brows and eyes moving as they do when she
        /// speaks (the model draws only the lips), each bounded by slow steps. A lane in both sets is walked on in place
        /// when the voice starts or stops.
        public let speechLanes: [ClosedRange<Int>]
        /// The crossings between speech lanes, in order, and the stays there, as for the silence lanes.
        public let speechItinerary: [HostPath.Crossing]
        public let speechStays: [Int]
        /// Where the path crosses from a silence lane into a speech lane when the voice starts (silence host to speech host)
        /// and back when it stops (speech host to a closed-lip host): matching poses, measured on the raw upper face. A host
        /// without one walks on until the next that has one.
        public let entries: [Int: Int]
        public let exits: [Int: Int]
        /// Where the path starts, and which way, at the call's first frame, so the call's 8-frame fade from the idle face
        /// blends it with pictures that match it.
        public let pathStart: Int
        public let pathStartRising: Bool
        /// Yoob SDK: the last host the speech walk may reach past the calm stretch (`HostWalker`), for a pack trimmed to the
        /// calm stretch and the hosts after it (the CDN's realistic Luna: calm 1-9, speech out to 34). Nil with a head path.
        public let wideLast: Int?
        public var calmLast: Int { first + count - 1 }
        public init(first: Int, count: Int, framesPerHost: Int, twins: [ClosedRange<Int>] = [], blinkHosts: [ClosedRange<Int>] = [],
                    closedEyes: ClosedRange<Int>? = nil, lanes: [ClosedRange<Int>] = [], closedLipLanes: [ClosedRange<Int>]? = nil,
                    itinerary: [HostPath.Crossing] = [], stays: [Int] = [], openLipStays: [Int]? = nil,
                    speechLanes: [ClosedRange<Int>] = [], speechItinerary: [HostPath.Crossing] = [], speechStays: [Int] = [],
                    entries: [Int: Int] = [:], exits: [Int: Int] = [:], pathStart: Int? = nil, pathStartRising: Bool = true,
                    wideLast: Int? = nil) {
            self.first = first; self.count = count; self.framesPerHost = max(1, framesPerHost)
            self.twins = twins; self.blinkHosts = blinkHosts; self.closedEyes = closedEyes
            self.lanes = lanes; self.closedLipLanes = closedLipLanes ?? lanes; self.itinerary = itinerary; self.stays = stays
            self.openLipStays = openLipStays ?? stays
            self.speechLanes = speechLanes; self.speechItinerary = speechItinerary; self.speechStays = speechStays
            self.entries = entries; self.exits = exits
            self.pathStart = pathStart ?? first; self.pathStartRising = pathStartRising
            self.wideLast = wideLast
        }
        /// Whether the idle face can take over from speech on `host`: the calm stretch or one of its twins.
        public func isHome(_ host: Int) -> Bool { (first...calmLast).contains(host) || twins.contains { $0.contains(host) } }
        /// Whether a rendered frame on `host` may carry the idle face's blink.
        public func isBlinkable(_ host: Int) -> Bool { blinkHosts.contains { $0.contains(host) } }
        /// Whether the head path runs: the window has lanes to walk.
        public var hasPath: Bool { !lanes.isEmpty && !itinerary.isEmpty && !stays.isEmpty }
        /// Whether `host` is in a silence lane.
        public func isCalm(_ host: Int) -> Bool { lanes.contains { $0.contains(host) } }
        /// Whether `host` is in a closed-lip lane: her real lips closed, so in silence the frame is the clip's own picture.
        public func isClosedLips(_ host: Int) -> Bool { closedLipLanes.contains { $0.contains(host) } }
        /// Whether `host` is in a speech lane.
        public func isSpeech(_ host: Int) -> Bool { speechLanes.contains { $0.contains(host) } }
        /// Realistic (H08 v4). The idle face is host 206 rendered with a closed mouth (`IdleLoops/realistic-still`, with a
        /// blink transplanted from hosts 10-12), shown only before the first rendered frame and after a stall. The head
        /// path (`HostPath`) walks the clip in two sets of lane, chosen with the pack tools from the pose
        /// table (`host_pose.json`), the raw frames and the raw lip gaps (MediaPipe inner-lip gap over mouth width):
        /// - Silence: 103-125 (11.6 px/s) and 319-373 (7.6 px/s), the still stretches at the rest pose, and 1-9 (18.8 px/s),
        ///   the calm opening: her real lips closed on every host (gap at most 0.02; host 206's is 0.004), the frame the
        ///   clip's own; and the chin lift 202-259 (47.8 px/s) with the model's sealed mouth over her moving head, since
        ///   her real lips are open on half of it (gap up to 0.25). Eyes open on every host (openness at least 0.30, open
        ///   is 0.33) but the lift's own blink; every lane end a slow step (0.30-0.82 px; the lift's 1.61 and 0.54).
        ///   Since 2026-09-25 silence no longer enters the lift (`HostPath.silenceEntersOpenLipLanes`): under the sealed
        ///   mouth her jaw and chin moved as much as in speech. It is walked in silence only on the way out after a phrase
        ///   that ends on it, and its itinerary crossings stay listed for that switch.
        /// - Speech: the lift, and 93-102, talking at the rest pose (14 px/s). The fast nod 158-201 and the stretches with
        ///   the head 20-60 px up and turned (20-89, 130-157, 270-309) stay out of both sets.
        /// Crossings are host pairs whose raw upper faces (above the model's square) differ by at most 7 luma, against the
        /// clip's own frame-to-frame median of 4.2 and p95 of 14.6 on that measure: between silence lanes 3.1-3.7 (each
        /// closed-lip lane leaves toward the two others and the lift in turn; the lift is left at its first exit); into
        /// speech from 81 of the 87 closed-lip hosts (3.1-7.0; 125, 319-320 and 365-367 walk on a few frames first) and
        /// back to a closed-lip host from all of 93-102, the lift's ends 202-210 and 247-259 (3.1-6.7; the middle of the
        /// lift walks on to its end first).
        /// Twins: raw frames within 5.3 luma of the still (face, mouth left out): 113-115, 329-347, 1-6. Blink hosts: the
        /// closed-lip lanes and 93-102 sit within 2.8 px of host 206 with the same pitch, yaw and roll to within a degree,
        /// so the idle face's eye pictures fit them (pasted, their edges differ from the frame by about 4 luma, blended
        /// over 12 px); the lift blinks on its own (226-231, once a pass), so no picture is scheduled there.
        /// Needs a pack with at least 374 hosts.
        public static let realistic = CalmHostWindow(
            first: 206, count: 1, framesPerHost: 3,
            twins: [113...115, 329...347, 1...6],
            blinkHosts: [1...9, 93...125, 316...373], closedEyes: 226...231,
            lanes: [103...125, 319...373, 1...9, 202...259], closedLipLanes: [103...125, 319...373, 1...9],
            itinerary: [.init(114, 345), .init(347, 5), .init(4, 115), .init(116, 259), .init(115, 347),
                        .init(333, 207), .init(336, 3), .init(1, 258), .init(2, 115)],
            stays: [22, 34, 28, 44, 20, 32, 40], openLipStays: [20, 30, 16, 24, 22],
            speechLanes: [202...259, 93...102],
            speechItinerary: [.init(259, 102), .init(102, 259)],
            speechStays: [30, 12, 34, 16, 24, 10, 40],
            entries: [1: 258, 2: 258, 3: 259, 4: 259, 5: 259, 6: 207, 7: 259, 8: 259, 9: 247,
                      103: 102, 104: 258, 105: 257, 106: 257, 107: 257, 108: 257, 109: 257, 110: 257, 111: 257, 112: 257,
                      113: 258, 114: 258, 115: 259, 116: 259, 117: 259, 118: 101, 119: 99, 120: 94, 121: 95, 122: 95, 123: 202, 124: 202,
                      321: 203, 322: 203, 323: 203, 324: 203, 325: 203, 326: 205, 327: 205, 328: 259, 329: 259, 330: 259, 331: 259,
                      332: 258, 333: 207, 334: 207, 335: 207, 336: 207, 337: 207, 338: 207, 339: 207, 340: 207, 341: 207, 342: 207,
                      343: 207, 344: 207, 345: 258, 346: 258, 347: 259, 348: 259, 349: 259, 350: 259, 351: 259, 352: 259, 353: 259,
                      354: 259, 355: 259, 356: 259, 357: 259, 358: 93, 359: 210, 360: 210, 361: 210, 362: 210, 363: 210, 364: 247,
                      368: 247, 369: 210, 370: 210, 371: 210, 372: 210, 373: 210],
            exits: [93: 119, 94: 120, 95: 121, 96: 121, 97: 121, 98: 120, 99: 119, 100: 118, 101: 103, 102: 103,
                    202: 123, 203: 324, 204: 324, 205: 327, 206: 332, 207: 333, 208: 333, 209: 8, 210: 9, 247: 9,
                    248: 107, 253: 107, 254: 107, 255: 107, 256: 107, 257: 112, 258: 114, 259: 115],
            pathStart: 331, pathStartRising: true)
        public func fits(hostCount: Int) -> Bool {
            let allLanes = lanes + speechLanes
            let inLanes: (Int) -> Bool = { host in allLanes.contains { $0.contains(host) } }
            return count >= 1 && first >= 0 && calmLast < hostCount && (wideLast.map { $0 >= calmLast && $0 < hostCount } ?? true)
                && twins.allSatisfy { $0.lowerBound >= 0 && $0.upperBound < hostCount }
                && allLanes.allSatisfy { $0.lowerBound >= 0 && $0.upperBound < hostCount }
                && closedLipLanes.allSatisfy { lane in lanes.contains { $0.contains(lane.lowerBound) && $0.contains(lane.upperBound) } }
                && itinerary.allSatisfy { isCalm($0.from) && isCalm($0.to) }
                && speechItinerary.allSatisfy { isSpeech($0.from) && isSpeech($0.to) }
                && entries.allSatisfy { isCalm($0.key) && isSpeech($0.value) } && exits.allSatisfy { isSpeech($0.key) && isClosedLips($0.value) }
                && (allLanes.isEmpty || inLanes(pathStart))
        }
    }
    public func hostIndex(for frame: Int) -> Int {
        if let calm = calmHosts, calm.fits(hostCount: manifest.frames.count) {
            guard calm.count > 1 else { return calm.first }
            let period = 2 * (calm.count - 1), position = (max(0, frame) / calm.framesPerHost) % period
            return calm.first + (position < calm.count ? position : period - position)
        }
        let n = manifest.frames.count, period = 2 * (n - 1)
        let position = (max(0, frame) + 1) % period
        return position < n ? position : period - position
    }
}
