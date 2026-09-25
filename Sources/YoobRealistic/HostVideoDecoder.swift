import AVFoundation
import CoreGraphics
import VideoToolbox

/// Sequential VideoToolbox decode of the shared HEVC host-frame video of a videoContainer pack.
/// Call frames advance one host at a time with a short prefetch, so one forward cursor serves
/// nearly every request; a jump (renderer restart, ping-pong turnaround) reopens the reader at
/// the keyframe at or below the requested frame and decodes forward. Decodes are serialized
/// here and run on HostFrameDecoder's background queue, never on the render path; only the
/// delivered pixel buffers are retained, by HostFrameDecoder's bounded slots.
final class HostVideoDecoder: @unchecked Sendable {
    private let url: URL
    private let keyframeInterval: Int
    private let frameCount: Int
    private let frameRate: Int
    private let queue = DispatchQueue(label: "companion.host-video-decode")
    private var asset: AVAsset?
    private var track: AVAssetTrack?
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    /// Index of the video frame the reader delivers next; frameCount once the video is drained.
    private var nextIndex = -1
    /// The colour space VideoToolbox tags this video's frames with (its CGImage's), read once: the tag comes from the
    /// track's colour description, the same for every frame, and making a CGImage per frame only to read it cost time.
    private var space: CGColorSpace?
    private var spaceRead = false
    /// Every frame decoded on the way to a request, newest last: the head path walks its lanes backwards as well as forwards
    /// (`hostTraversal` upstream-forward-backward), and a backward step in an HEVC stream reopens the reader at the
    /// keyframe and decodes forward again, up to 14 frames for one picture. That made a call's compose 50 ms a frame on
    /// an iPhone Air against 3.6 ms forward, and half the frames were never shown. Kept, a backward walk through one group of pictures decodes it once.
    private var decoded: [Int: CVPixelBuffer] = [:]
    private var decodedOrder: [Int] = []
    /// One group of pictures plus the frame after it: ~130 MB of 1080 x 1920 BGRA.
    static let cachedFrames = 16

    init(url: URL, keyframeInterval: Int, frameCount: Int, frameRate: Int) {
        self.url = url
        self.keyframeInterval = max(1, keyframeInterval)
        self.frameCount = frameCount
        self.frameRate = frameRate
    }

    /// Frame `index` as the decoder delivered it (32BGRA), with the colour space its CGImage would carry.
    func picture(forVideoFrame index: Int) throws -> HostPicture {
        try queue.sync {
            let buffer = try bufferLocked(forVideoFrame: index)
            if !spaceRead { space = try Self.image(of: buffer).colorSpace; spaceRead = true }
            return .pixels(buffer, colorSpace: space)
        }
    }

    /// Frame `index` as VideoToolbox's CGImage of the decoded buffer (`DerivedCrops` reads the face box from it).
    func image(forVideoFrame index: Int) throws -> CGImage {
        try queue.sync { try Self.image(of: try bufferLocked(forVideoFrame: index)) }
    }

    private static func image(of buffer: CVPixelBuffer) throws -> CGImage {
        var image: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image) == noErr, let image else {
            throw AvatarError.invalidPack("host video")
        }
        return image
    }

    /// Lock-free: only called on the serial queue.
    private func bufferLocked(forVideoFrame index: Int) throws -> CVPixelBuffer {
        if track == nil {
            let asset = AVAsset(url: url)
            guard let found = asset.tracks(withMediaType: .video).first else { throw AvatarError.invalidPack("host video") }
            self.asset = asset
            track = found
        }
        if let hit = decoded[index] { return hit }
        // Continue forward while the request is close ahead of the cursor; otherwise seek to
        // the keyframe at or below the request and decode forward from there.
        if nextIndex < 0 || index < nextIndex || index - nextIndex > keyframeInterval {
            try start(at: index - index % keyframeInterval)
        }
        do { return try drain(until: index) }
        catch {
            // A seek can land on the wrong side of a GOP (lane jumps in the head path reopen the reader often).
            // One reopen from the request's own keyframe recovers; only then does this frame fail.
            try start(at: max(0, index - index % keyframeInterval))
            return try drain(until: index)
        }
    }

    private func drain(until index: Int) throws -> CVPixelBuffer {
        while nextIndex <= index {
            guard let sample = output?.copyNextSampleBuffer() else { throw AvatarError.invalidPack("host video") }
            let shown = indexOf(sample)
            guard let buffer = CMSampleBufferGetImageBuffer(sample),
                  CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { throw AvatarError.invalidPack("host video") }
            keep(buffer, at: shown)
            nextIndex = shown + 1
            if shown == index { return buffer }
        }
        throw AvatarError.invalidPack("host video")
    }

    private func keep(_ buffer: CVPixelBuffer, at index: Int) {
        if decoded.updateValue(buffer, forKey: index) != nil { decodedOrder.removeAll { $0 == index } }
        decodedOrder.append(index)
        while decodedOrder.count > Self.cachedFrames { decoded[decodedOrder.removeFirst()] = nil }
    }

    /// Lock-free: only called on the serial queue. Starts delivery at `keyframe`, which must be a keyframe index.
    private func start(at keyframe: Int) throws {
        guard let asset, let track else { throw AvatarError.invalidPack("host video") }
        let reader = try AVAssetReader(asset: asset)
        let start = CMTime(seconds: Double(keyframe) / Double(frameRate), preferredTimescale: 600)
        reader.timeRange = CMTimeRange(start: start, duration: .positiveInfinity)
        // IOSurface-backed and Metal-compatible, so the GPU compositor reads the decoded frame in place (`FaceMetalCompositor`).
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        guard reader.canAdd(output) else { throw AvatarError.invalidPack("host video") }
        reader.add(output)
        guard reader.startReading() else { throw AvatarError.invalidPack("host video") }
        self.reader = reader
        self.output = output
        nextIndex = keyframe
    }

    private func indexOf(_ sample: CMSampleBuffer) -> Int {
        let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        return min(frameCount - 1, max(0, Int((seconds * Double(frameRate)).rounded())))
    }
}
