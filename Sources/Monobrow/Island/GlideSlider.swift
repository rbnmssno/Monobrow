import AppKit
import SwiftUI

/// What a slider should show. `rate` lets the progress bar advance on its own between updates.
struct GlideSliderState: Equatable {
    var fraction: Double
    /// `CACurrentMediaTime()` at which `fraction` was true.
    var stamp: CFTimeInterval = 0
    /// Fraction per second; zero when the value does not move by itself.
    var rate: Double = 0
    /// A change of this number means: glide to the new value instead of jumping.
    var glideToken: Int = 0
}

private final class AnimationEnd: NSObject, CAAnimationDelegate {
    private let handler: (Bool) -> Void

    init(_ handler: @escaping (Bool) -> Void) {
        self.handler = handler
    }

    func animationDidStop(_ animation: CAAnimation, finished: Bool) {
        handler(finished)
    }
}

/// Progress and volume slider. A click glides the fill to the pointer, a drag follows it, and
/// dragging past an end stretches the track like a rubber band. All motion is Core Animation,
/// including the steady advance during playback, so nothing is redrawn by the app per frame.
final class GlideSliderView: NSView {
    static let glideDuration: CFTimeInterval = 0.45
    private static let glideCurve = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)

    var onBegan: ((Double) -> Void)?
    var onChanged: ((Double) -> Void)?
    /// Final value and whether the pointer was dragged (as opposed to a plain click).
    var onEnded: ((Double, Bool) -> Void)?
    var isEnabled = true
    var reduceMotion = false

    private let track = CALayer()
    private let fill = CALayer()
    private var state: GlideSliderState?
    private var tracking = false
    private var dragging = false
    private var hovered = false
    private var thick = false
    private var stretched = false
    private var downX: CGFloat = 0
    private var localFraction = 0.0
    private var glideEnd: CFTimeInterval = 0
    private var awaitingState = false
    private var hoverArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        track.backgroundColor = NSColor(white: 1, alpha: 0.17).cgColor
        track.masksToBounds = true
        fill.backgroundColor = NSColor(white: 1, alpha: 0.92).cgColor
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        fill.setValue(0.0, forKeyPath: "transform.scale.x")
        track.addSublayer(fill)
        layer?.addSublayer(track)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Layout

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutTrack()
        CATransaction.commit()
    }

    private func layoutTrack() {
        let height: CGFloat = thick ? 6 : 4
        if !stretched, track.animation(forKey: "stretch") == nil {
            track.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            track.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        track.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        track.cornerRadius = height / 2
        fill.bounds = track.bounds
        fill.position = CGPoint(x: 0, y: height / 2)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { render(glide: false) } else { cancelTracking() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    // MARK: State from the owner

    func apply(_ newState: GlideSliderState) {
        let old = state
        guard newState != old else { return }
        state = newState
        awaitingState = false
        guard !tracking else { return }
        render(glide: old != nil && old?.glideToken != newState.glideToken)
    }

    private func targetFraction(at time: CFTimeInterval) -> Double {
        guard let state else { return 0 }
        return (state.fraction + state.rate * (time - state.stamp)).clamped(0, 1)
    }

    private func render(glide: Bool) {
        guard state != nil, !tracking else { return }
        let now = CACurrentMediaTime()
        let rate = state?.rate ?? 0
        if glide, !reduceMotion, window != nil {
            glideEnd = now + Self.glideDuration
            setFill(targetFraction(at: glideEnd), duration: Self.glideDuration, timing: Self.glideCurve) { [weak self] in
                self?.continueLinear()
            }
        } else if now < glideEnd, window != nil {
            // An update arrived mid-glide: keep gliding to the corrected value instead of jumping.
            let remaining = max(0.15, glideEnd - now)
            setFill(targetFraction(at: now + remaining), duration: remaining, timing: CAMediaTimingFunction(name: .easeOut)) { [weak self] in
                self?.continueLinear()
            }
        } else {
            setFill(targetFraction(at: now), duration: 0, timing: nil)
            if rate > 0 { continueLinear() }
        }
    }

    /// Lets the render server advance the fill at playback speed until the end of the track.
    private func continueLinear() {
        guard let state, state.rate > 0, !tracking, window != nil else { return }
        let current = targetFraction(at: CACurrentMediaTime())
        guard current < 1 else {
            setFill(1, duration: 0, timing: nil)
            return
        }
        fill.removeAnimation(forKey: "fill")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.setValue(current, forKeyPath: "transform.scale.x")
        CATransaction.commit()
        let animation = CABasicAnimation(keyPath: "transform.scale.x")
        animation.fromValue = current
        animation.toValue = 1.0
        animation.duration = (1 - current) / state.rate
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        // The animation carries the fill to the end of the track and holds it there.
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 20)
        fill.add(animation, forKey: "fill")
    }

    /// What is on screen right now, for tests.
    var visibleFraction: Double { currentFill() }

    private func currentFill() -> Double {
        ((fill.presentation() ?? fill).value(forKeyPath: "transform.scale.x") as? NSNumber)?.doubleValue ?? 0
    }

    private func setFill(_ target: Double, duration: CFTimeInterval, timing: CAMediaTimingFunction?,
                         then completion: (() -> Void)? = nil) {
        let from = currentFill()
        let to = target.clamped(0, 1)
        fill.removeAnimation(forKey: "fill")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.setValue(to, forKeyPath: "transform.scale.x")
        CATransaction.commit()
        guard duration > 0, window != nil, abs(from - to) > 0.0004 else {
            completion?()
            return
        }
        let animation = CABasicAnimation(keyPath: "transform.scale.x")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = timing ?? CAMediaTimingFunction(name: .linear)
        if let completion {
            animation.delegate = AnimationEnd { finished in
                if finished { completion() }
            }
        }
        fill.add(animation, forKey: "fill")
    }

    // MARK: Pointer

    private func fraction(at event: NSEvent) -> (raw: Double, x: CGFloat) {
        let x = convert(event.locationInWindow, from: nil).x
        return (bounds.width > 0 ? Double(x / bounds.width) : 0, x)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        // A previous press whose release never arrived must not block the slider for good.
        if tracking { finishTracking() }
        let point = fraction(at: event)
        let value = point.raw.clamped(0, 1)
        tracking = true
        dragging = false
        downX = point.x
        localFraction = value
        onBegan?(value)
        glideEnd = CACurrentMediaTime() + Self.glideDuration
        setFill(value, duration: reduceMotion ? 0 : Self.glideDuration, timing: Self.glideCurve)
    }

    override func mouseDragged(with event: NSEvent) {
        guard tracking else { return }
        let point = fraction(at: event)
        if !dragging {
            guard abs(point.x - downX) >= 3 else { return }
            dragging = true
            glideEnd = 0
            updateThickness()
        }
        let value = point.raw.clamped(0, 1)
        localFraction = value
        setFill(value, duration: 0.08, timing: CAMediaTimingFunction(name: .easeOut))
        let overshoot = point.raw < 0 ? -point.raw : (point.raw > 1 ? point.raw - 1 : 0)
        if overshoot > 0, !reduceMotion {
            stretch(by: overshoot, pastEnd: point.raw > 1)
        } else if stretched {
            releaseStretch(animated: false)
        }
        onChanged?(value)
    }

    override func mouseUp(with event: NSEvent) {
        finishTracking()
    }

    /// Ends a press whose mouse-up will not arrive, for example because a menu opened meanwhile.
    func cancelTracking() {
        finishTracking()
    }

    private func finishTracking() {
        guard tracking else { return }
        let wasDrag = dragging
        tracking = false
        dragging = false
        releaseStretch(animated: true)
        updateThickness()
        awaitingState = true
        onEnded?(localFraction, wasDrag)
        // The owner normally answers with a new state within the same screen update.
        // If it does not, return to the real value.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.awaitingState, !self.tracking else { return }
            self.awaitingState = false
            self.render(glide: true)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        updateThickness()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        updateThickness()
    }

    private func updateThickness() {
        let wanted = hovered || dragging
        guard wanted != thick else { return }
        thick = wanted
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        layoutTrack()
        CATransaction.commit()
    }

    // MARK: Rubber band

    private func stretch(by overshoot: Double, pastEnd: Bool) {
        let amount = CGFloat(min(0.12, overshoot * 0.3))
        track.removeAnimation(forKey: "stretch")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The far end stays put while the near end follows the pointer.
        track.anchorPoint = CGPoint(x: pastEnd ? 0 : 1, y: 0.5)
        track.position = CGPoint(x: pastEnd ? 0 : bounds.width, y: bounds.midY)
        track.transform = CATransform3DMakeScale(1 + amount, 1 - amount * 2, 1)
        CATransaction.commit()
        stretched = true
    }

    private func releaseStretch(animated: Bool) {
        guard stretched else { return }
        stretched = false
        let from = track.presentation()?.transform ?? track.transform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.transform = CATransform3DIdentity
        CATransaction.commit()
        guard animated, !reduceMotion else { return }
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: from)
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.mass = 1
        spring.stiffness = 320
        spring.damping = 14
        spring.duration = spring.settlingDuration
        track.add(spring, forKey: "stretch")
    }
}

struct GlideSlider: NSViewRepresentable {
    var state: GlideSliderState
    var enabled = true
    var reduceMotion = false
    var onBegan: (Double) -> Void
    var onChanged: (Double) -> Void
    var onEnded: (Double, Bool) -> Void

    func makeNSView(context: Context) -> GlideSliderView {
        GlideSliderView(frame: .zero)
    }

    func updateNSView(_ view: GlideSliderView, context: Context) {
        view.onBegan = onBegan
        view.onChanged = onChanged
        view.onEnded = onEnded
        view.isEnabled = enabled
        view.reduceMotion = reduceMotion
        view.apply(state)
    }
}
