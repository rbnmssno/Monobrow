import AppKit
import SwiftUI

/// Sizes of the island for one screen. Everything is derived from the camera housing (the notch),
/// so the island fits any MacBook resolution; screens without a notch get a small pill at the top edge.
struct IslandMetrics: Equatable {
    var hasNotch: Bool
    /// Width of the notch. On a screen without one: the gap between the cover and the equalizer.
    var notchWidth: CGFloat
    /// Height of the collapsed island: the notch height, or the menu bar height without a notch.
    var barHeight: CGFloat

    static let expandedWidth: CGFloat = 460
    static let peekWidth: CGFloat = 380
    static let equalizerWidth: CGFloat = 19.5
    static let sideMargin: CGFloat = 70
    static let bottomMargin: CGFloat = 90
    static let hotZone = CGSize(width: 200, height: 5)

    /// Space at the top of the open island that the notch covers.
    var topInset: CGFloat { hasNotch ? barHeight : 6 }
    var compactArt: CGFloat { hasNotch ? (barHeight - 14).clamped(14, 26) : (barHeight - 8).clamped(14, 22) }
    var compactPadding: CGFloat { hasNotch ? 12 : 9 }
    var wing: CGFloat { compactArt + compactPadding * 2 }
    var compactEqualizerHeight: CGFloat { min(14, max(8, barHeight - 10)) }

    func size(_ mode: IslandMode) -> CGSize {
        switch mode {
        case .hidden:
            // Slightly smaller than the notch, so no black edge can show around the camera housing.
            return hasNotch
                ? CGSize(width: notchWidth - 6, height: barHeight - 4)
                : CGSize(width: notchWidth + wing * 2, height: 0)
        case .compact:
            return CGSize(width: notchWidth + wing * 2, height: barHeight)
        case .peek:
            return CGSize(width: Self.peekWidth, height: topInset + 64)
        case .expanded:
            return CGSize(width: Self.expandedWidth, height: topInset + 172)
        }
    }

    func bottomRadius(_ mode: IslandMode) -> CGFloat {
        switch mode {
        case .hidden: return hasNotch ? 9 : 0
        case .compact: return min(13, barHeight / 2)
        case .peek: return 28
        case .expanded: return 34
        }
    }

    /// Radius of the concave corners that join the island to the top edge of the screen.
    func ear(_ mode: IslandMode) -> CGFloat {
        switch mode {
        case .hidden: return 0
        case .compact: return 7
        case .peek, .expanded: return 10
        }
    }

    var windowSize: CGSize {
        CGSize(width: Self.expandedWidth + 20 + Self.sideMargin * 2, height: size(.expanded).height + Self.bottomMargin)
    }

    /// The island's body in window coordinates with the origin at the top-left corner.
    func shapeRect(_ mode: IslandMode) -> CGRect {
        let size = size(mode)
        return CGRect(x: (windowSize.width - size.width) / 2, y: 0, width: size.width, height: size.height)
    }

    var hotZoneRect: CGRect {
        CGRect(x: (windowSize.width - Self.hotZone.width) / 2, y: 0, width: Self.hotZone.width, height: Self.hotZone.height)
    }

    /// Cover frame relative to the top-left corner of the island body.
    func artFrame(_ mode: IslandMode) -> CGRect {
        switch mode {
        case .hidden, .compact:
            return CGRect(x: compactPadding, y: (barHeight - compactArt) / 2, width: compactArt, height: compactArt)
        case .peek:
            return CGRect(x: 18, y: topInset + 10, width: 40, height: 40)
        case .expanded:
            return CGRect(x: 22, y: topInset + 12, width: 56, height: 56)
        }
    }

    func artRadius(_ mode: IslandMode) -> CGFloat {
        switch mode {
        case .hidden, .compact: return compactArt * 0.25
        case .peek: return 9
        case .expanded: return 12
        }
    }

    func equalizerFrame(_ mode: IslandMode, shapeWidth: CGFloat) -> CGRect {
        let width = Self.equalizerWidth
        switch mode {
        case .hidden, .compact:
            let height = compactEqualizerHeight
            let right = hasNotch ? 14.0 : compactPadding
            return CGRect(x: shapeWidth - right - width, y: (barHeight - height) / 2, width: width, height: height)
        case .peek:
            return CGRect(x: shapeWidth - 20 - width, y: topInset + 10 + 13, width: width, height: 14)
        case .expanded:
            return CGRect(x: shapeWidth - 22 - width, y: topInset + 12 + 20, width: width, height: 16)
        }
    }
}

/// Where the island window goes on a screen and how big the island is there.
struct IslandLayout {
    let metrics: IslandMetrics
    let windowFrame: NSRect

    init(screen: NSScreen) {
        let frame = screen.frame
        let notchHeight = screen.safeAreaInsets.top
        let left = screen.auxiliaryTopLeftArea?.width ?? 0
        let right = screen.auxiliaryTopRightArea?.width ?? 0
        let notchWidth = frame.width - left - right

        let metrics: IslandMetrics
        let centerX: CGFloat
        if notchHeight > 0, left > 0, right > 0, notchWidth > 40, notchWidth < 420 {
            metrics = IslandMetrics(hasNotch: true, notchWidth: notchWidth, barHeight: notchHeight)
            centerX = frame.minX + left + notchWidth / 2
        } else {
            let menuBar = frame.maxY - screen.visibleFrame.maxY
            let barHeight = (menuBar > 20 ? menuBar : NSStatusBar.system.thickness).clamped(24, 40)
            metrics = IslandMetrics(hasNotch: false, notchWidth: 44, barHeight: barHeight)
            centerX = frame.midX
        }
        self.metrics = metrics
        let size = metrics.windowSize
        windowFrame = NSRect(
            x: (centerX - size.width / 2).rounded(),
            y: frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    var isBuiltIn: Bool {
        if safeAreaInsets.top > 0 { return true }
        guard let displayID else { return false }
        return CGDisplayIsBuiltin(displayID) != 0
    }
}

/// The island's outline: flat against the top of the screen, concave "ears" at the top corners,
/// rounded corners at the bottom. The rect includes the ears on both sides.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var ear: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, ear) }
        set {
            bottomRadius = newValue.first
            ear = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0 else { return path }
        let e = max(0, min(ear, rect.height, rect.width / 4))
        let bodyWidth = rect.width - e * 2
        let r = max(0, min(bottomRadius, bodyWidth / 2, rect.height - e))
        let left = rect.minX + e
        let right = rect.maxX - e

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: right, y: rect.minY), tangent2End: CGPoint(x: right, y: rect.minY + e), radius: e)
        path.addLine(to: CGPoint(x: right, y: rect.maxY - r))
        path.addArc(tangent1End: CGPoint(x: right, y: rect.maxY), tangent2End: CGPoint(x: right - r, y: rect.maxY), radius: r)
        path.addLine(to: CGPoint(x: left + r, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: left, y: rect.maxY), tangent2End: CGPoint(x: left, y: rect.maxY - r), radius: r)
        path.addLine(to: CGPoint(x: left, y: rect.minY + e))
        path.addArc(tangent1End: CGPoint(x: left, y: rect.minY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: e)
        path.closeSubpath()
        return path
    }
}
