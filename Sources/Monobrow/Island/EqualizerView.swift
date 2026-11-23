import AppKit
import SwiftUI

/// Four bouncing bars. The loop is a Core Animation animation: the system's render server draws
/// it, so the app itself does no per-frame work. The loop is removed whenever it is not visible.
final class EqualizerNSView: NSView {
    private static let durations: [CFTimeInterval] = [0.72, 0.95, 0.6, 0.84]
    private static let phases: [CFTimeInterval] = [0.2, 0.5, 0.1, 0.35]
    private static let restingScales: [CGFloat] = [0.6, 0.9, 0.6, 0.75]
    private static let barWidth: CGFloat = 3
    private static let barStep: CGFloat = 5.5

    private let columns: [CALayer] = (0..<4).map { _ in CALayer() }
    private let bars: [CALayer] = (0..<4).map { _ in CALayer() }

    private var configured = false
    private var playing = false
    private var animated = true
    private var visible = true
    private var amplitude: CGFloat = 1
    private var color: NSColor?
    private(set) var looping = false
    private var everLooped = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        for index in 0..<4 {
            columns[index].addSublayer(bars[index])
            layer?.addSublayer(columns[index])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let height = bounds.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in 0..<4 {
            let size = CGRect(x: 0, y: 0, width: Self.barWidth, height: height)
            columns[index].bounds = size
            columns[index].position = CGPoint(x: CGFloat(index) * Self.barStep + Self.barWidth / 2, y: bounds.midY)
            bars[index].bounds = size
            bars[index].position = CGPoint(x: Self.barWidth / 2, y: height / 2)
            bars[index].cornerRadius = Self.barWidth / 2
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Core Animation drops animations of layers that leave the screen; start over if needed.
        looping = false
        updateLoop()
    }

    func apply(playing: Bool, animated: Bool, visible: Bool, amplitude: CGFloat, color: NSColor) {
        let first = !configured
        configured = true

        if self.color != color {
            self.color = color
            CATransaction.begin()
            CATransaction.setDisableActions(first)
            CATransaction.setAnimationDuration(0.35)
            bars.forEach { $0.backgroundColor = color.cgColor }
            CATransaction.commit()
        }

        let playingChanged = playing != self.playing
        let levelChanged = playingChanged || abs(amplitude - self.amplitude) > 0.004
        self.playing = playing
        self.animated = animated
        self.visible = visible
        self.amplitude = amplitude

        if first || levelChanged {
            let target = amplitude * (playing ? 1 : 0.22)
            for index in 0..<4 {
                // On pause and resume the bars settle one after another.
                setLevel(index, to: target, animated: !first && visible, delay: playingChanged ? Double(index) * 0.05 : 0)
            }
        }
        updateLoop()
    }

    private func setLevel(_ index: Int, to target: CGFloat, animated: Bool, delay: CFTimeInterval) {
        let column = columns[index]
        let current = ((column.presentation() ?? column).value(forKeyPath: "transform.scale.y") as? NSNumber)
            .map { CGFloat($0.doubleValue) } ?? 1
        column.removeAnimation(forKey: "level")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        column.setValue(target, forKeyPath: "transform.scale.y")
        CATransaction.commit()
        guard animated, window != nil, abs(current - target) > 0.01 else { return }
        let spring = CASpringAnimation(keyPath: "transform.scale.y")
        spring.fromValue = current
        spring.toValue = target
        spring.mass = 1
        spring.stiffness = 260
        spring.damping = 19
        spring.duration = spring.settlingDuration
        if delay > 0 {
            spring.beginTime = column.convertTime(CACurrentMediaTime(), from: nil) + delay
            spring.fillMode = .backwards
        }
        column.add(spring, forKey: "level")
    }

    private func updateLoop() {
        let shouldLoop = playing && animated && visible && window != nil
        if shouldLoop, !looping {
            startLoop()
        } else if !shouldLoop, looping {
            stopLoop(freeze: !playing && animated)
        } else if !shouldLoop, !(everLooped && !playing && animated) {
            setRestingBars()
        }
    }

    private func startLoop() {
        looping = true
        everLooped = true
        for index in 0..<4 {
            let animation = CAKeyframeAnimation(keyPath: "transform.scale.y")
            animation.values = [0.28, 1.0, 0.45]
            animation.keyTimes = [0, 0.5, 1]
            let ease = CAMediaTimingFunction(name: .easeInEaseOut)
            animation.timingFunctions = [ease, ease]
            animation.duration = Self.durations[index]
            animation.timeOffset = Self.phases[index]
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
            bars[index].add(animation, forKey: "loop")
        }
    }

    /// Stops the loop. On pause the bars freeze where they are, like a paused animation.
    private func stopLoop(freeze: Bool) {
        looping = false
        for (index, bar) in bars.enumerated() {
            let current = ((bar.presentation() ?? bar).value(forKeyPath: "transform.scale.y") as? NSNumber)
                .map { CGFloat($0.doubleValue) } ?? Self.restingScales[index]
            bar.removeAnimation(forKey: "loop")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bar.setValue(freeze ? current : Self.restingScales[index], forKeyPath: "transform.scale.y")
            CATransaction.commit()
        }
    }

    private func setRestingBars() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            bar.setValue(Self.restingScales[index], forKeyPath: "transform.scale.y")
        }
        CATransaction.commit()
    }
}

struct EqualizerView: NSViewRepresentable {
    var playing: Bool
    var animated: Bool
    var visible: Bool
    var amplitude: CGFloat
    var color: NSColor

    func makeNSView(context: Context) -> EqualizerNSView {
        EqualizerNSView(frame: .zero)
    }

    func updateNSView(_ view: EqualizerNSView, context: Context) {
        view.apply(playing: playing, animated: animated, visible: visible, amplitude: amplitude, color: color)
    }
}
