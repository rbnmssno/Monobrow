import Foundation
import QuartzCore
import os

/// Development output and error logging.
enum Log {
    private static let logger = Logger(subsystem: "app.monobrow.Monobrow", category: "app")
    private static var echo = false
    private static var file: FileHandle?
    private static let lock = NSLock()

    static func configure(echo: Bool, filePath: String?) {
        self.echo = echo
        if let filePath {
            FileManager.default.createFile(atPath: filePath, contents: nil)
            file = FileHandle(forWritingAtPath: filePath)
        }
    }

    /// Development output. It never reaches the system log, so it may mention track details.
    static func debug(_ message: @autoclosure () -> String) {
        guard echo || file != nil else { return }
        let line = Data((message() + "\n").utf8)
        lock.lock()
        defer { lock.unlock() }
        if echo { FileHandle.standardOutput.write(line) }
        file?.write(line)
    }

    /// Problems worth keeping in the system log. Callers pass technical text only.
    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        debug("error: " + message)
    }
}

/// Development switches that reach into the interface.
enum DevFlags {
    /// Draws a wallpaper-like backdrop behind the island, for screenshots (`--backdrop`).
    static var backdrop = false
}

/// A cancellable one-shot timer on the main queue.
final class OneShot {
    private var item: DispatchWorkItem?

    var isPending: Bool { item != nil }

    func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) {
        item?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.item = nil
            block()
        }
        item = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func cancel() {
        item?.cancel()
        item = nil
    }

    deinit { item?.cancel() }
}

/// CSS-style cubic-bezier timing function, used to shape hand-driven animations.
struct UnitBezier {
    private let ax, bx, cx, ay, by, cy: Double

    init(_ p1x: Double, _ p1y: Double, _ p2x: Double, _ p2y: Double) {
        cx = 3 * p1x
        bx = 3 * (p2x - p1x) - cx
        ax = 1 - cx - bx
        cy = 3 * p1y
        by = 3 * (p2y - p1y) - cy
        ay = 1 - cy - by
    }

    private func x(_ t: Double) -> Double { ((ax * t + bx) * t + cx) * t }
    private func y(_ t: Double) -> Double { ((ay * t + by) * t + cy) * t }
    private func dx(_ t: Double) -> Double { (3 * ax * t + 2 * bx) * t + cx }

    func callAsFunction(_ progress: Double) -> Double {
        if progress <= 0 { return 0 }
        if progress >= 1 { return 1 }
        var t = progress
        for _ in 0..<8 {
            let error = x(t) - progress
            if abs(error) < 1e-6 { return y(t) }
            let slope = dx(t)
            if abs(slope) < 1e-6 { break }
            t -= error / slope
        }
        var low = 0.0, high = 1.0
        t = progress
        for _ in 0..<40 {
            let value = x(t)
            if abs(value - progress) < 1e-6 { break }
            if progress > value { low = t } else { high = t }
            t = (low + high) / 2
        }
        return y(t)
    }
}

extension Comparable {
    func clamped(_ low: Self, _ high: Self) -> Self { min(max(self, low), high) }
}

/// Timings of the island's behaviour. Tests shorten them.
struct Timing {
    var peek: TimeInterval = 2.6
    var hideAfterPause: TimeInterval = 10
    var hoverIn: TimeInterval = 0.15
    var hoverOut: TimeInterval = 0.4
    /// Tiny pause before asking Spotify about a like, so holding "next" asks once, not per track.
    var likeFetchDelay: TimeInterval = 0.05
    /// How long the heart keeps its previous look on a new track while the answer is on its way.
    var likeHold: TimeInterval = 0.6
    var artworkGrace: TimeInterval = 0.9
    var verifyDelay: TimeInterval = 1.2
    var noteDuration: TimeInterval = 1.9

    static let standard = Timing()
}

func formatTime(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    return "\(total / 60):" + String(format: "%02d", total % 60)
}
