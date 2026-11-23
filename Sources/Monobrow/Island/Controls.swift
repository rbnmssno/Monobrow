import AppKit
import SwiftUI

enum Motion {
    /// Island growing: a bouncy spring, like the Dynamic Island.
    static let grow = Animation.spring(response: 0.5, dampingFraction: 0.66)
    /// Island shrinking: quicker and almost without bounce.
    static let shrink = Animation.spring(response: 0.4, dampingFraction: 0.88)
    /// Sliders and time labels gliding to a new value.
    static let glide = Animation.timingCurve(0.22, 1, 0.36, 1, duration: GlideSliderView.glideDuration)
    static let soft = Animation.spring(response: 0.35, dampingFraction: 0.62)
    static let release = Animation.spring(response: 0.4, dampingFraction: 0.48)
}

extension Color {
    static let islandDim = Color.white.opacity(0.56)
    static let liked = Color(red: 0.118, green: 0.843, blue: 0.376)
}

// MARK: Hover tracking

/// Reports whether the pointer is over a view. Unlike SwiftUI's own hover, it works in a window
/// that never becomes key and in an app that is not active, which is always the case for the island.
struct HoverReader: NSViewRepresentable {
    @Binding var isHovering: Bool

    func makeNSView(context: Context) -> HoverNSView {
        let view = HoverNSView(frame: .zero)
        view.onChange = { value in isHovering = value }
        return view
    }

    func updateNSView(_ view: HoverNSView, context: Context) {
        view.onChange = { value in
            if isHovering != value { isHovering = value }
        }
    }
}

final class HoverNSView: NSView {
    var onChange: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let newArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(newArea)
        area = newArea
    }

    override func mouseEntered(with event: NSEvent) {
        onChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onChange?(false)
    }
}

// MARK: Hand-driven animations

/// Drives a one-shot effect. Animate `phase` linearly to the next whole number; the content gets
/// the fractional part: 0 at rest, then 0...1 while the effect plays.
struct Phased<Content: View>: View, Animatable {
    var phase: Double
    let content: (Double) -> Content

    init(_ phase: Double, @ViewBuilder content: @escaping (Double) -> Content) {
        self.phase = phase
        self.content = content
    }

    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    var body: some View {
        content(phase - phase.rounded(.down))
    }
}

/// Piecewise-linear keyframes with smooth joints: `points` are (time, value) pairs in rising time order.
func keyframe(_ t: Double, _ points: [(Double, Double)]) -> Double {
    guard let first = points.first, let last = points.last else { return 0 }
    if t <= first.0 { return first.1 }
    if t >= last.0 { return last.1 }
    for index in 1..<points.count where t <= points[index].0 {
        let a = points[index - 1], b = points[index]
        let local = (t - a.0) / max(0.0001, b.0 - a.0)
        let eased = local * local * (3 - 2 * local)
        return a.1 + (b.1 - a.1) * eased
    }
    return last.1
}

// MARK: Buttons

struct IslandButtonStyle: ButtonStyle {
    let hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Circle()
                    .fill(Color.white.opacity(configuration.isPressed ? 0.2 : 0.1))
                    .scaleEffect(hovering ? 1 : 0.5)
                    .opacity(hovering ? 1 : 0)
                    .animation(Motion.soft, value: hovering)
            )
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.84 : 1)
            .animation(configuration.isPressed ? .easeOut(duration: 0.08) : Motion.release, value: configuration.isPressed)
    }
}

/// A round island button: a highlight grows from its centre on hover, it squishes while pressed
/// and springs back on release.
struct IslandButton<Label: View>: View {
    let size: CGFloat
    let help: String
    let action: () -> Void
    let label: (Bool) -> Label
    @State private var hovering = false

    init(size: CGFloat, help: String, action: @escaping () -> Void, @ViewBuilder label: @escaping (Bool) -> Label) {
        self.size = size
        self.help = help
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: action) {
            label(hovering).frame(width: size, height: size)
        }
        .buttonStyle(IslandButtonStyle(hovering: hovering))
        .background(HoverReader(isHovering: $hovering))
        .accessibilityLabel(help)
    }
}

// MARK: Play / pause

/// Two pause bars that flow into the two halves of a play triangle. `morph` 0 is pause, 1 is play.
struct PlayPauseShape: Shape {
    var morph: CGFloat

    var animatableData: CGFloat {
        get { morph }
        set { morph = newValue }
    }

    private static let pause: [[CGPoint]] = [
        [CGPoint(x: 6.6, y: 5.1), CGPoint(x: 9.2, y: 5.1), CGPoint(x: 9.2, y: 18.9), CGPoint(x: 6.6, y: 18.9)],
        [CGPoint(x: 14.8, y: 5.1), CGPoint(x: 17.4, y: 5.1), CGPoint(x: 17.4, y: 18.9), CGPoint(x: 14.8, y: 18.9)],
    ]
    private static let play: [[CGPoint]] = [
        [CGPoint(x: 8.3, y: 5.6), CGPoint(x: 13.75, y: 8.8), CGPoint(x: 13.75, y: 15.2), CGPoint(x: 8.3, y: 18.4)],
        [CGPoint(x: 13.75, y: 8.8), CGPoint(x: 19.2, y: 12), CGPoint(x: 19.2, y: 12), CGPoint(x: 13.75, y: 15.2)],
    ]

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        var path = Path()
        for part in 0..<2 {
            for index in 0..<4 {
                let a = Self.pause[part][index]
                let b = Self.play[part][index]
                let point = CGPoint(
                    x: rect.minX + (a.x + (b.x - a.x) * morph) * scale,
                    y: rect.minY + (a.y + (b.y - a.y) * morph) * scale
                )
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
        }
        return path
    }
}

struct PlayPauseGlyph: View {
    let isPlaying: Bool
    let size: CGFloat

    var body: some View {
        let shape = PlayPauseShape(morph: isPlaying ? 0 : 1)
        ZStack {
            shape.fill(Color.white)
            shape.stroke(Color.white, style: StrokeStyle(lineWidth: 2.2 * size / 24, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .animation(.timingCurve(0.34, 1.45, 0.64, 1, duration: 0.34), value: isPlaying)
    }
}

// MARK: Skip

/// One rounded triangle of the skip icon, pointing right, in a 9.5 x 13.6 box.
struct SkipTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 9.5
        let sy = rect.height / 13.6
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }
        var path = Path()
        path.move(to: point(0, 1.1))
        path.addCurve(to: point(1.6, 0.3), control1: point(0, 0.3), control2: point(0.9, -0.2))
        path.addLine(to: point(9.0, 6.0))
        path.addCurve(to: point(9.0, 7.6), control1: point(9.5, 6.4), control2: point(9.5, 7.2))
        path.addLine(to: point(1.6, 13.3))
        path.addCurve(to: point(0, 12.5), control1: point(0.9, 13.8), control2: point(0, 13.3))
        path.closeSubpath()
        return path
    }
}

/// The double-arrow icon. While `t` runs from 0 to 1 the arrows click over: a new one grows in on
/// the left, the left one moves to the right and the right one flies off.
struct SkipGlyph: View {
    let t: Double
    let size: CGFloat

    private static let enter = UnitBezier(0.3, 1.4, 0.5, 1)
    private static let move = UnitBezier(0.3, 1.3, 0.5, 1)
    private static let leave = UnitBezier(0.4, 0, 0.6, 1)

    var body: some View {
        let unit = size / 24
        let active = t > 0
        let entering = active ? Self.enter(t) : 0
        let moving = active ? Self.move(t) : 0
        let leaving = active ? Self.leave(min(1, t / 0.6)) : 0
        let triangle = SkipTriangle().fill(Color.white).frame(width: 9.5 * unit, height: 13.6 * unit)
        ZStack {
            triangle
                .scaleEffect(max(0, entering))
                .opacity(entering.clamped(0, 1))
                .offset(x: -4.75 * unit)
            triangle
                .offset(x: (-4.75 + 9.5 * moving) * unit)
            triangle
                .scaleEffect(max(0, 1 - leaving))
                .opacity((1 - leaving).clamped(0, 1))
                .offset(x: (4.75 + 5 * leaving) * unit)
        }
        .frame(width: size, height: size)
    }
}

struct SkipButton: View {
    /// +1 for next, -1 for previous.
    let direction: Int
    let action: () -> Void
    @State private var phase = 0.0

    var body: some View {
        IslandButton(size: 38, help: direction > 0 ? "Следующий трек" : "Предыдущий трек") {
            withAnimation(.linear(duration: 0.42)) { phase += 1 }
            action()
        } label: { hovering in
            Phased(phase) { t in SkipGlyph(t: t, size: 24) }
                .scaleEffect(x: direction > 0 ? 1 : -1, y: 1)
                .offset(x: hovering ? CGFloat(direction) * 1.5 : 0)
                .animation(Motion.soft, value: hovering)
        }
    }
}

// MARK: Like

/// Sparks and a ring that burst out of the heart when a track is liked.
/// Drawn with plain shapes on purpose: SwiftUI's `Canvas` would claim about 100 MB of
/// graphics memory the first time it draws and keep it.
struct LikeBurst: View {
    let t: Double
    let accent: Color

    private static let sparkCurve = UnitBezier(0.15, 0.75, 0.3, 1)

    var body: some View {
        ZStack {
            if t > 0 {
                let ringTime = min(1, t / 0.85)
                let ringEase = 1 - (1 - ringTime) * (1 - ringTime)
                Circle()
                    .stroke(Color.liked, lineWidth: 1.5)
                    .frame(width: 30, height: 30)
                    .scaleEffect(0.7 + 0.9 * ringEase)
                    .opacity(0.5 * (1 - ringEase))
                ForEach(0..<8, id: \.self) { index in
                    spark(index)
                }
            }
        }
        .frame(width: 64, height: 64)
        .allowsHitTesting(false)
    }

    private func spark(_ index: Int) -> some View {
        let small = index % 2 == 1
        let eased = Self.sparkCurve(min(1, t / (small ? 0.77 : 1)))
        let distance = 8 + 17 * eased
        let angle = Double(index) * Double.pi / 4
        let side: CGFloat = small ? 3 : 4
        return Circle()
            .fill(small ? accent : Color.liked)
            .frame(width: side, height: side)
            .scaleEffect(max(0, 1.2 - eased))
            .opacity((1 - eased).clamped(0, 1))
            .offset(x: sin(angle) * distance, y: -cos(angle) * distance)
    }
}

struct LikeButton: View {
    let liked: Bool
    let available: Bool
    let effect: LikeEffect
    let accent: Color
    let action: () -> Void

    @State private var burst = 0.0
    @State private var deflate = 0.0
    @State private var shake = 0.0

    var body: some View {
        IslandButton(size: 36, help: liked ? "Убрать из «Любимых треков»" : "Добавить в «Любимые треки»", action: action) { hovering in
            ZStack {
                Phased(burst) { t in LikeBurst(t: t, accent: accent) }
                Phased(burst) { pop in
                    Phased(deflate) { squeeze in
                        Phased(shake) { wobble in
                            Image(systemName: liked ? "heart.fill" : "heart")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(liked ? Color.liked : Color.white.opacity(available ? 0.78 : 0.32))
                                .scaleEffect(Self.popScale(pop) * Self.squeezeScale(squeeze) * (hovering ? 1.1 : 1))
                                .offset(x: Self.wobbleOffset(wobble))
                        }
                    }
                }
                .animation(Motion.soft, value: hovering)
            }
            .frame(width: 36, height: 36)
        }
        .onChange(of: effect) { _, newEffect in
            switch newEffect.kind {
            case .liked: withAnimation(.linear(duration: 0.65)) { burst += 1 }
            case .unliked: withAnimation(.linear(duration: 0.45)) { deflate += 1 }
            case .denied: withAnimation(.linear(duration: 0.42)) { shake += 1 }
            }
        }
    }

    /// The heart pops in from small, overshoots and settles (first 0.5 s of the 0.65 s burst).
    private static func popScale(_ t: Double) -> Double {
        guard t > 0 else { return 1 }
        return keyframe(min(1, t / 0.77), [(0, 0.4), (0.55, 1.28), (1, 1)])
    }

    private static func squeezeScale(_ t: Double) -> Double {
        guard t > 0 else { return 1 }
        return keyframe(t, [(0, 1), (0.35, 0.7), (1, 1)])
    }

    private static func wobbleOffset(_ t: Double) -> Double {
        guard t > 0 else { return 0 }
        return keyframe(t, [(0, 0), (0.2, -3), (0.4, 3), (0.6, -2), (0.8, 2), (1, 0)])
    }
}

// MARK: Volume icon

private struct SpeakerBody: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 24
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * unit, y: rect.minY + y * unit)
        }
        var path = Path()
        path.move(to: point(3.5, 9.3))
        path.addCurve(to: point(4.4, 8.4), control1: point(3.5, 8.8), control2: point(3.9, 8.4))
        path.addLine(to: point(7.4, 8.4))
        path.addLine(to: point(11.7, 4.8))
        path.addCurve(to: point(13.2, 5.5), control1: point(12.3, 4.3), control2: point(13.2, 4.7))
        path.addLine(to: point(13.2, 18.5))
        path.addCurve(to: point(11.7, 19.2), control1: point(13.2, 19.3), control2: point(12.3, 19.7))
        path.addLine(to: point(7.4, 15.6))
        path.addLine(to: point(4.4, 15.6))
        path.addQuadCurve(to: point(3.5, 14.7), control: point(3.5, 15.6))
        path.closeSubpath()
        return path
    }
}

/// One sound wave of the speaker icon: an arc bulging to the right.
private struct SpeakerWave: Shape {
    let x: CGFloat
    let top: CGFloat
    let bottom: CGFloat
    let bulge: CGFloat

    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 24
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + x * unit, y: rect.minY + top * unit))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + x * unit, y: rect.minY + bottom * unit),
            control: CGPoint(x: rect.minX + bulge * unit, y: rect.minY + 12 * unit)
        )
        return path
    }
}

private struct SpeakerCross: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 24
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 16.5 * unit, y: rect.minY + 9.5 * unit))
        path.addLine(to: CGPoint(x: rect.minX + 21.5 * unit, y: rect.minY + 14.5 * unit))
        path.move(to: CGPoint(x: rect.minX + 21.5 * unit, y: rect.minY + 9.5 * unit))
        path.addLine(to: CGPoint(x: rect.minX + 16.5 * unit, y: rect.minY + 14.5 * unit))
        return path
    }
}

/// The speaker icon. Waves appear with the volume level; a cross pops in when muted.
struct SpeakerGlyph: View {
    /// 0 is muted, 1 is quiet, 2 is loud.
    let level: Int
    let size: CGFloat

    var body: some View {
        let stroke = StrokeStyle(lineWidth: 1.8 * size / 24, lineCap: .round, lineJoin: .round)
        ZStack {
            SpeakerBody().fill(Color.white)
            SpeakerWave(x: 16, top: 9.2, bottom: 14.8, bulge: 18.29)
                .stroke(Color.white, style: stroke)
                .scaleEffect(level >= 1 ? 1 : 0.4, anchor: UnitPoint(x: 16.0 / 24, y: 0.5))
                .opacity(level >= 1 ? 1 : 0)
            SpeakerWave(x: 18.6, top: 6.6, bottom: 17.4, bulge: 23.1)
                .stroke(Color.white, style: stroke)
                .scaleEffect(level >= 2 ? 1 : 0.4, anchor: UnitPoint(x: 18.6 / 24, y: 0.5))
                .opacity(level >= 2 ? 1 : 0)
            SpeakerCross()
                .stroke(Color.white, style: stroke)
                .scaleEffect(level == 0 ? 1 : 0.3, anchor: UnitPoint(x: 19.0 / 24, y: 0.5))
                .opacity(level == 0 ? 1 : 0)
        }
        .frame(width: size, height: size)
        .animation(Motion.soft, value: level)
    }
}

struct MuteButton: View {
    let volume: Int
    let action: () -> Void
    @State private var wiggle = 0.0

    var body: some View {
        IslandButton(size: 28, help: volume == 0 ? "Включить звук" : "Выключить звук") {
            withAnimation(.linear(duration: 0.45)) { wiggle += 1 }
            action()
        } label: { _ in
            Phased(wiggle) { t in
                SpeakerGlyph(level: volume == 0 ? 0 : (volume < 50 ? 1 : 2), size: 18)
                    .opacity(0.78)
                    .rotationEffect(.degrees(t > 0 ? keyframe(t, [(0, 0), (0.3, -14), (0.65, 8), (1, 0)]) : 0))
                    .scaleEffect(t > 0 ? keyframe(t, [(0, 1), (0.3, 0.9), (0.65, 1), (1, 1)]) : 1)
            }
        }
    }
}
