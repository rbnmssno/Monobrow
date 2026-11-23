import AppKit
import Combine
import SwiftUI

/// The island window. It floats above the menu bar, never takes keyboard focus and never
/// activates the app. It has a fixed size; areas it does not draw let clicks through.
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        // `ignoresMouseEvents` is deliberately left untouched: only then does the system pass
        // clicks through the transparent parts of the window.
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Hosts the SwiftUI island and feeds pointer movement to the hover logic.
final class IslandHostingView: NSHostingView<IslandRootView> {
    weak var island: IslandState?
    var menuProvider: (() -> NSMenu)?
    private var area: NSTrackingArea?

    required init(rootView: IslandRootView) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Only the island itself is tracked, not the whole transparent window, so the app is not
    /// woken when the pointer merely moves near the notch.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area {
            removeTrackingArea(area)
            self.area = nil
        }
        guard let hot = island?.trackingRect, !hot.isNull, !hot.isEmpty else { return }
        let rect = isFlipped ? hot : NSRect(x: hot.minX, y: bounds.height - hot.maxY, width: hot.width, height: hot.height)
        let newArea = NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways], owner: self)
        addTrackingArea(newArea)
        area = newArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        island?.pointerMoved()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        island?.pointerMoved()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        island?.pointerMoved()
    }

    override func mouseDown(with event: NSEvent) {
        island?.pointerPressed()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let island, let window, let menu = menuProvider?() else {
            super.rightMouseDown(with: event)
            return
        }
        let location = event.locationInWindow
        let point = CGPoint(x: location.x, y: window.frame.height - location.y)
        guard island.contains(point) else {
            super.rightMouseDown(with: event)
            return
        }
        // The menu swallows the next mouse-up, so a slider being dragged is released first.
        Self.sliders(in: self).forEach { $0.cancelTracking() }
        island.lock()
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        island.unlock()
    }

    private static func sliders(in view: NSView) -> [GlideSliderView] {
        var found: [GlideSliderView] = []
        if let slider = view as? GlideSliderView { found.append(slider) }
        for child in view.subviews { found.append(contentsOf: sliders(in: child)) }
        return found
    }
}

/// One island on one screen.
final class IslandPanelController {
    let displayID: CGDirectDisplayID
    let state: IslandState
    let panel: IslandPanel
    let host: IslandHostingView

    init(screen: NSScreen, displayID: CGDirectDisplayID, model: PlayerModel, prefs: Preferences,
         timing: Timing, menu: @escaping () -> NSMenu) {
        self.displayID = displayID
        let layout = IslandLayout(screen: screen)
        state = IslandState(metrics: layout.metrics, model: model, timing: timing)
        panel = IslandPanel(frame: layout.windowFrame)
        host = IslandHostingView(rootView: IslandRootView(model: model, island: state, prefs: prefs))
        host.island = state
        host.menuProvider = menu
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.frame = NSRect(origin: .zero, size: layout.windowFrame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        state.windowFrame = { [weak panel] in panel?.frame ?? .zero }
        state.onHotRectChange = { [weak host] in host?.updateTrackingAreas() }
        apply(layout)
    }

    func update(screen: NSScreen) {
        apply(IslandLayout(screen: screen))
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func close() {
        state.invalidate()
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
    }

    private func apply(_ layout: IslandLayout) {
        if state.metrics != layout.metrics { state.metrics = layout.metrics }
        // On a notch screen the collapsed island sits inside the black strip, so it may stay
        // visible over full-screen apps. Without a notch it would cover their content.
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if layout.metrics.hasNotch { behavior.insert(.fullScreenAuxiliary) }
        if panel.collectionBehavior != behavior { panel.collectionBehavior = behavior }
        if panel.frame != layout.windowFrame { panel.setFrame(layout.windowFrame, display: true) }
    }
}

/// Creates the islands when Spotify starts, removes them when it quits and keeps them on the right screens.
final class IslandManager {
    private let model: PlayerModel
    private let prefs: Preferences
    private let timing: Timing
    private let menu: () -> NSMenu
    private(set) var controllers: [CGDirectDisplayID: IslandPanelController] = [:]
    private var active = false
    private let teardown = OneShot()
    private let relayout = OneShot()
    private var observers: [NSObjectProtocol] = []
    private var modeSubscription: AnyObject?

    init(model: PlayerModel, prefs: Preferences, timing: Timing, menu: @escaping () -> NSMenu) {
        self.model = model
        self.prefs = prefs
        self.timing = timing
        self.menu = menu
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleRelayout()
        })
        modeSubscription = prefs.$screenMode.dropFirst().sink { [weak self] _ in
            self?.scheduleRelayout(after: 0.05)
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func setActive(_ value: Bool) {
        guard value != active else { return }
        active = value
        if value {
            teardown.cancel()
            sync()
        } else {
            // Let the island fold into the notch before its windows go away.
            teardown.schedule(after: 0.8) { [weak self] in
                guard let self, !self.active else { return }
                self.closeAll()
            }
        }
    }

    func scheduleRelayout(after delay: TimeInterval = 0.3) {
        relayout.schedule(after: delay) { [weak self] in self?.sync() }
    }

    private func targetScreens() -> [NSScreen] {
        let screens = NSScreen.screens
        switch prefs.screenMode {
        case .all:
            return screens
        case .builtIn:
            if let builtIn = screens.first(where: { $0.isBuiltIn }) { return [builtIn] }
            return Array(screens.prefix(1))
        }
    }

    private func sync() {
        guard active else { return }
        var wanted = Set<CGDirectDisplayID>()
        for screen in targetScreens() {
            guard let id = screen.displayID else { continue }
            wanted.insert(id)
            if let controller = controllers[id] {
                controller.update(screen: screen)
            } else {
                let controller = IslandPanelController(
                    screen: screen, displayID: id, model: model, prefs: prefs, timing: timing, menu: menu
                )
                controllers[id] = controller
                controller.show()
            }
        }
        for id in controllers.keys.filter({ !wanted.contains($0) }) {
            controllers[id]?.close()
            controllers[id] = nil
        }
    }

    private func closeAll() {
        controllers.values.forEach { $0.close() }
        controllers.removeAll()
    }
}
