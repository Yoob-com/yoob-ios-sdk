import Foundation
import CoreGraphics
import ImageIO

/// The blink of the still idle face, drawn on speaking frames too. The host clip blinks once in the whole walk (hosts
/// 226-231, at the top of the chin lift), so a reply of short phrases, which rests on the calm pose between them, stared
/// for up to 18 s. The eye pictures were aligned to host 206 (`IdleLoops/realistic-still`); they fit any host near
/// enough the rest pose (`CalmHostWindow.blinkHosts`, within 3 px), where they replace the frame's eyes with their edges
/// blended over `edgePixels`, so the rectangle never shows.
public struct SpeechBlink: @unchecked Sendable {
    /// Placement of the eye pictures in the frame, in frame pixels.
    public let x: Int, y: Int, width: Int, height: Int
    /// RGBA, `width * height * 4` bytes each, in the frame's own colour space (they were cut from a frame composed like
    /// speech).
    public let pictures: [Data]
    /// The same pictures in BGRA byte order, for the compositor's BGRA frames (swizzled once here, not per frame).
    let bgraPictures: [Data]
    /// Picture for each 40 ms step of one blink.
    public let sequence: [Int]
    /// When the blinks fall, on the call's frame clock (`frame * 0.04`).
    public let schedule: IdleBlinkSchedule
    /// Pixels over which a picture's edge blends into the frame.
    public static let edgePixels = 12
    /// The blink schedule's cell for rendered frames: one blink per 3.6 s (16-17 a minute, the natural 15-20 in
    /// conversation) rather than the still idle face's 4.5 s; its double blinks are dropped by the renderer's 2 s spacing.
    public static let cellSeconds = 3.6

    public init?(rect: [Int], sequence: [Int], pictures: [Data]) {
        guard rect.count == 4, rect[2] > 0, rect[3] > 0, !sequence.isEmpty, !pictures.isEmpty,
              sequence.allSatisfy({ pictures.indices.contains($0) }),
              pictures.allSatisfy({ $0.count == rect[2] * rect[3] * 4 }) else { return nil }
        x = rect[0]; y = rect[1]; width = rect[2]; height = rect[3]
        self.pictures = pictures; self.sequence = sequence
        bgraPictures = pictures.map { rgba in
            var bgra = rgba
            bgra.withUnsafeMutableBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                for pixel in stride(from: 0, to: bytes.count, by: 4) { bytes.swapAt(pixel, pixel + 2) }
            }
            return bgra
        }
        var timing = IdleBlinkSchedule(sequence: sequence); timing.cellSeconds = Self.cellSeconds
        schedule = timing
    }

    /// The pictures decoded from `urls` (JPEG or PNG of the rectangle's size), in their own colour space.
    public init?(rect: [Int], sequence: [Int], pictureURLs urls: [URL]) {
        guard rect.count == 4, rect[2] > 0, rect[3] > 0 else { return nil }
        var pictures: [Data] = []
        for url in urls {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                  image.width == rect[2], image.height == rect[3] else { return nil }
            let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
            var rgba = Data(repeating: 255, count: rect[2] * rect[3] * 4)
            let drawn: Bool = rgba.withUnsafeMutableBytes { raw in
                guard let context = CGContext(data: raw.baseAddress, width: rect[2], height: rect[3], bitsPerComponent: 8,
                                              bytesPerRow: rect[2] * 4, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: rect[2], height: rect[3]))
                return true
            }
            guard drawn else { return nil }
            pictures.append(rgba)
        }
        self.init(rect: rect, sequence: sequence, pictures: pictures)
    }

    /// The still idle face's manifest (`still.json`: `rect`, `sequence`, `blinks`) and pictures in `directory`.
    public static func load(directory: URL) -> SpeechBlink? {
        struct Manifest: Decodable { let rect: [Int]; let sequence: [Int]; let blinks: [String] }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("still.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
        return SpeechBlink(rect: manifest.rect, sequence: manifest.sequence,
                           pictureURLs: manifest.blinks.map { directory.appendingPathComponent($0) })
    }

    /// Draws `picture` over an RGBA frame of `frameWidth` x `frameHeight` (the frame is drawn top row first). The picture
    /// replaces the frame inside, and blends in linearly over `edgePixels` from its edges.
    public func draw(picture: Int, into rgba: UnsafeMutableBufferPointer<UInt8>, frameWidth: Int, frameHeight: Int) {
        draw(pictures, picture: picture, into: rgba, frameWidth: frameWidth, frameHeight: frameHeight)
    }
    /// Picture `picture` in BGRA for the compositor, nil when there is no such picture.
    func patch(_ picture: Int) -> AvatarCompositor.BlinkPatch? {
        guard bgraPictures.indices.contains(picture) else { return nil }
        return AvatarCompositor.BlinkPatch(x: x, y: y, width: width, height: height, bgra: bgraPictures[picture])
    }
    private func draw(_ pictures: [Data], picture: Int, into rgba: UnsafeMutableBufferPointer<UInt8>, frameWidth: Int, frameHeight: Int) {
        guard pictures.indices.contains(picture) else { return }
        pictures[picture].withUnsafeBytes { raw in
            Self.blend(patch: raw.bindMemory(to: UInt8.self), x: x, y: y, width: width, height: height, into: rgba, rowBytes: frameWidth * 4,
                       frameWidth: frameWidth, frameHeight: frameHeight)
        }
    }
    /// Blends a `width` x `height` picture (4 bytes a pixel, the frame's own channel order) into a frame of rows `rowBytes`
    /// apart at (`x`, `y`): replaced inside, linearly over `edgePixels` from its edges, alpha untouched. Each channel blends
    /// on its own, so a BGRA frame with a BGRA picture gets the very bytes an RGBA frame gets, reordered.
    static func blend(patch: UnsafeBufferPointer<UInt8>, x: Int, y: Int, width: Int, height: Int, into frame: UnsafeMutableBufferPointer<UInt8>,
                      rowBytes: Int, frameWidth: Int, frameHeight: Int) {
        guard x >= 0, y >= 0, x + width <= frameWidth, y + height <= frameHeight, patch.count >= width * height * 4,
              frame.count >= (frameHeight - 1) * rowBytes + frameWidth * 4 else { return }
        let edge = Float(edgePixels)
        for row in 0..<height {
            let frameRow = (y + row) * rowBytes + x * 4, patchRow = row * width * 4
            for column in 0..<width {
                let inset = min(column + 1, width - column, row + 1, height - row)
                let pixel = frameRow + column * 4, source = patchRow + column * 4
                if Float(inset) >= edge {
                    frame[pixel] = patch[source]; frame[pixel + 1] = patch[source + 1]; frame[pixel + 2] = patch[source + 2]
                    continue
                }
                let weight = Float(inset) / edge
                for channel in 0..<3 {
                    let value = weight * Float(patch[source + channel]) + (1 - weight) * Float(frame[pixel + channel])
                    frame[pixel + channel] = UInt8(max(0, min(255, value.rounded(.toNearestOrEven))))
                }
            }
        }
    }
}

/// When a speaking frame may start a blink, from what the renderer knows when it renders the frame. All of it is decided
/// from the audio the renderer already has, so delivery in bursts and at 1x blink on the same frames.
public enum SpeechBlinkGate {
    /// Frames into a stretch of held speech before a blink may start: the call screen's 0.22 s crossfade to speech has
    /// ended, so no half-drawn eyelid blends with the idle face.
    public static let holdFrames = 8
    /// Whether a blink may start on this frame: frames have been shown for `holdFrames` (the crossfade to speech has
    /// ended) and the head is on a blinkable pose for the whole blink (the path ahead is known).
    public static func allows(heldFrames: Int, hostsThroughBlink: [Int], window: AvatarPack.CalmHostWindow, blinkFrames: Int) -> Bool {
        heldFrames >= holdFrames
            && hostsThroughBlink.count >= blinkFrames && hostsThroughBlink.prefix(blinkFrames).allSatisfy(window.isBlinkable)
    }
}
