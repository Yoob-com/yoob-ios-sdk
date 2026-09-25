import SwiftUI

/// Shows a `YoobAvatar`: its poster while it loads, idle frames while it is silent, and the rendered face while it speaks.
/// The idle and speaking layers cross-fade as one picture, so the switch never flashes the background.
public struct YoobAvatarView: View {
    private let avatar: YoobAvatar
    private let contentMode: ContentMode
    private let fade: Double
    private let motion: Bool
    @State private var motionState = MotionState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - contentMode: `.fill` crops to the view (the default, for full-screen characters); `.fit` letterboxes.
    ///   - fade: Seconds for the idle ↔ speaking cross-fade.
    ///   - speakingMotion: Realistic characters nod on stressed syllables and sway slightly, more while speaking, and
    ///     breathe in silence (a whole-picture transform of at most a few points). Off with Reduce Motion.
    public init(_ avatar: YoobAvatar, contentMode: ContentMode = .fill, fade: Double = 0.15, speakingMotion: Bool = true) {
        self.avatar = avatar
        self.contentMode = contentMode
        self.fade = fade
        self.motion = speakingMotion
    }

    public var body: some View {
        let moving = motion && !reduceMotion && avatar.manifest?.engine == .realistic
        // While a lip frame fades in, every display refresh draws the fade's next step (120 Hz on ProMotion iPhones whose
        // app allows it); otherwise the speaking motion's 30 Hz is enough.
        let fading = avatar.fadingFrom != nil
        TimelineView(.animation(minimumInterval: fading ? nil : 1.0 / 30, paused: !(moving || fading))) { timeline in
            let pose = moving ? motionState.update(level: avatar.voiceLevel, speaking: avatar.isShowingSpeech,
                                                   at: timeline.date.timeIntervalSinceReferenceDate) : .zero
            layers(at: timeline.date)
                .scaleEffect(1 + pose.scale, anchor: UnitPoint(x: 0.5, y: 0.45))
                .rotationEffect(.degrees(pose.degrees), anchor: UnitPoint(x: 0.5, y: 0.62))
                .offset(x: pose.dx, y: pose.dy)
        }
        .clipped()
        .accessibilityElement()
        .accessibilityLabel(avatar.manifest?.displayName ?? "Character")
        .accessibilityAddTraits(.isImage)
    }

    /// The motion's state lives outside SwiftUI's diffing: advanced once per animation frame.
    private final class MotionState {
        private var motion = SpeakingMotion()
        func update(level: Double, speaking: Bool, at time: Double) -> SpeakingMotion.Pose {
            motion.update(level: level, speaking: speaking, at: time)
        }
    }

    private func layers(at date: Date) -> some View {
        ZStack {
            IdleLayer(avatar: avatar, contentMode: contentMode)
                .compositingGroup()
                .opacity(avatar.isShowingSpeech ? 0 : 1)
            if let frame = avatar.speechFrame {
                // The lip cadence's fade: the new frame drawn at its weight over the one before (both opaque, so the result
                // is their mix).
                let weight = avatar.lipBlendWeight(at: date)
                ZStack {
                    if weight < 1, let from = avatar.fadingFrom { picture(from) }
                    picture(frame).opacity(weight)
                }
                .compositingGroup()
                .opacity(avatar.isShowingSpeech ? 1 : 0)
            }
        }
        .animation(.easeInOut(duration: fade), value: avatar.isShowingSpeech)
    }

    private func picture(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
            .aspectRatio(avatar.aspectRatio, contentMode: contentMode)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct IdleLayer: View {
    let avatar: YoobAvatar
    let contentMode: ContentMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let frames = avatar.idleFrames
        TimelineView(.periodic(from: .now, by: 1 / max(1, avatar.idleFramesPerSecond))) { timeline in
            if let image = frames.isEmpty ? avatar.poster : frames[index(at: timeline.date, count: frames.count)] {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(avatar.aspectRatio, contentMode: contentMode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        }
    }

    /// Forward and back: 0, 1, … n-1, n-2, … 1, so the loop has no seam.
    private func index(at date: Date, count: Int) -> Int {
        guard count > 1, !reduceMotion, !avatar.isShowingSpeech else { return 0 }
        let period = 2 * (count - 1)
        let step = Int(date.timeIntervalSinceReferenceDate * avatar.idleFramesPerSecond) % period
        return step < count ? step : period - step
    }
}
