import AppKit
import SwiftUI

private struct CoverSlot {
    var image: NSImage?
    var key: String
}

/// The album cover. A new cover slides in from the side the track was switched to while the old
/// one slides out; on pause it shrinks and dims a little; a double-click like flashes a heart.
struct CoverView: View {
    let image: NSImage?
    let key: String
    let direction: Int
    let cornerRadius: CGFloat
    let dimmed: Bool
    let love: Int
    let animated: Bool

    @State private var current: CoverSlot
    @State private var outgoing: CoverSlot?
    @State private var swapPhase = 0.0
    @State private var swapDirection = 1
    @State private var lovePhase = 0.0

    private static let slideIn = UnitBezier(0.2, 1.25, 0.35, 1)
    private static let slideOut = UnitBezier(0.4, 0, 0.7, 0.4)

    init(image: NSImage?, key: String, direction: Int, cornerRadius: CGFloat, dimmed: Bool, love: Int, animated: Bool) {
        self.image = image
        self.key = key
        self.direction = direction
        self.cornerRadius = cornerRadius
        self.dimmed = dimmed
        self.love = love
        self.animated = animated
        _current = State(initialValue: CoverSlot(image: image, key: key))
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            Phased(swapPhase) { t in
                ZStack {
                    if t > 0, let outgoing {
                        let eased = Self.slideOut(min(1, t / 0.58))
                        face(outgoing, side: side)
                            .scaleEffect(1 - 0.3 * eased)
                            .offset(x: -CGFloat(swapDirection) * 0.7 * side * eased)
                            .opacity(1 - eased)
                    }
                    let eased = t > 0 ? Self.slideIn(t) : 1
                    face(current, side: side)
                        .scaleEffect(0.7 + 0.3 * eased)
                        .offset(x: CGFloat(swapDirection) * 0.7 * side * (1 - eased))
                        .opacity(eased.clamped(0, 1))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(Color(white: 0.16))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .scaleEffect(dimmed ? 0.86 : 1)
            .brightness(dimmed ? -0.2 : 0)
            .saturation(dimmed ? 0.85 : 1)
            .animation(Motion.grow, value: dimmed)
            .overlay {
                Phased(lovePhase) { t in
                    Image(systemName: "heart.fill")
                        .font(.system(size: side * 0.5, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
                        .scaleEffect(t > 0 ? keyframe(t, [(0, 0.2), (0.22, 1.2), (0.4, 0.92), (0.62, 1), (1, 1.25)]) : 1)
                        .offset(y: t > 0 ? keyframe(t, [(0, 0), (0.62, 0), (1, -6)]) : 0)
                        .opacity(t > 0 ? keyframe(t, [(0, 0), (0.22, 1), (0.62, 1), (1, 0)]) : 0)
                }
                .allowsHitTesting(false)
            }
        }
        .onChange(of: key) { _, newKey in
            outgoing = current
            current = CoverSlot(image: image, key: newKey)
            swapDirection = direction >= 0 ? 1 : -1
            if animated {
                withAnimation(.linear(duration: 0.52)) { swapPhase += 1 }
            }
        }
        .onChange(of: love) { _, _ in
            withAnimation(.linear(duration: 0.9)) { lovePhase += 1 }
        }
    }

    @ViewBuilder
    private func face(_ slot: CoverSlot, side: CGFloat) -> some View {
        if let image = slot.image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: side, height: side)
                .clipped()
        } else {
            ZStack {
                LinearGradient(colors: [Color(white: 0.24), Color(white: 0.13)], startPoint: .top, endPoint: .bottom)
                Image(systemName: "music.note")
                    .font(.system(size: side * 0.42, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            .frame(width: side, height: side)
        }
    }
}
