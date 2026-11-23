import AppKit
import Combine

/// Per-screen state of one island: its size on that screen and whether the pointer keeps it open.
final class IslandState: ObservableObject {
    @Published var metrics: IslandMetrics {
        didSet { if metrics != oldValue { onHotRectChange?() } }
    }
    @Published private(set) var isHovering = false
    /// Keeps the island open regardless of the pointer. Used by the snapshot tool.
    @Published var pinned = false

    /// Frame of the island window in screen coordinates.
    var windowFrame: () -> CGRect = { .zero }
    /// Where the pointer is, in screen coordinates. Tests replace it.
    var pointerLocation: () -> CGPoint = { NSEvent.mouseLocation }
    /// Called when the area that reacts to the pointer changed, so the window can track the new one.
    var onHotRectChange: (() -> Void)?

    /// The area that reacts to the pointer right now: the island itself, in window coordinates
    /// with the origin at the top-left corner. Null when there is nothing to point at.
    var trackingRect: CGRect { hotRect() }

    /// Call when the island was redrawn in another mode.
    func displayedModeChanged() {
        onHotRectChange?()
    }

    private let model: PlayerModel
    private let timing: Timing
    private let enterTimer = OneShot()
    private let leaveTimer = OneShot()
    private var watchdog: Timer?
    private var locks = 0

    init(metrics: IslandMetrics, model: PlayerModel, timing: Timing) {
        self.metrics = metrics
        self.model = model
        self.timing = timing
    }

    deinit { watchdog?.invalidate() }

    // MARK: Pointer input

    /// Call whenever the pointer moved over, into or out of the island window.
    func pointerMoved() {
        evaluate(inside: pointerInside())
    }

    /// A click on the collapsed island opens it at once.
    func pointerPressed() {
        guard !isHovering, pointerInside() else { return }
        enterTimer.cancel()
        setHovering(true)
    }

    /// While locked (a slider is dragged, a menu is open) the island stays open.
    func lock() {
        locks += 1
        leaveTimer.cancel()
    }

    func unlock() {
        locks = max(0, locks - 1)
        if locks == 0 { pointerMoved() }
    }

    /// Call before the island window goes away.
    func invalidate() {
        enterTimer.cancel()
        leaveTimer.cancel()
        locks = 0
        setHovering(false)
    }

    /// True when the pointer is over the island (window coordinates, origin at the top-left corner).
    func contains(_ point: CGPoint) -> Bool {
        hotRect().contains(point)
    }

    // MARK: Hover logic

    private func pointerInside() -> Bool {
        let frame = windowFrame()
        guard frame.width > 0 else { return false }
        let mouse = pointerLocation()
        return contains(CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y))
    }

    private func hotRect() -> CGRect {
        guard model.spotifyRunning else { return .null }
        if isHovering {
            // A little slack around the open island, so brushing its edge does not close it.
            let rect = metrics.shapeRect(.expanded)
            return CGRect(x: rect.minX - 12, y: -4, width: rect.width + 24, height: rect.height + 16)
        }
        let resting = model.mode(hovering: false)
        if resting == .hidden, !metrics.hasNotch {
            return metrics.hotZoneRect.insetBy(dx: 0, dy: -4)
        }
        let rect = metrics.shapeRect(resting)
        return CGRect(x: rect.minX, y: -4, width: rect.width, height: rect.height + 4)
    }

    private func evaluate(inside: Bool) {
        if inside {
            leaveTimer.cancel()
            guard !isHovering, !enterTimer.isPending else { return }
            enterTimer.schedule(after: timing.hoverIn) { [weak self] in
                guard let self, self.pointerInside() else { return }
                self.setHovering(true)
            }
        } else {
            enterTimer.cancel()
            guard isHovering, locks == 0, !leaveTimer.isPending else { return }
            leaveTimer.schedule(after: timing.hoverOut) { [weak self] in
                guard let self, self.locks == 0, !self.pointerInside() else { return }
                self.setHovering(false)
            }
        }
    }

    private func setHovering(_ value: Bool) {
        guard value != isHovering else { return }
        isHovering = value
        onHotRectChange?()
        model.islandExpansionChanged(value)
        watchdog?.invalidate()
        watchdog = nil
        guard value else { return }
        // Safety net: if a mouse-exit event is ever missed, the open island still notices
        // that the pointer left. Runs only while the island is open.
        let timer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in self?.pointerMoved() }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }
}
