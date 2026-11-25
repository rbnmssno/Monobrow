import AppKit

/// A simulated player with five made-up tracks. It lets the island be developed and tested
/// without touching the user's real Spotify (`--demo`).
final class DemoBackend: PlayerBackend {
    var events: ((BackendEvent) -> Void)?

    private struct Item {
        let track: Track
        let artwork: Artwork
    }

    private let items = DemoBackend.makeItems()
    private var index = 0
    private var position = 37.0
    private var stamp = CACurrentMediaTime()
    private var playing = true
    private var volume = 64
    private var running = false
    private let endTimer = OneShot()

    func start() {
        running = true
        stamp = CACurrentMediaTime()
        events?(.permission(.granted))
        events?(.volume(volume))
        emit(trackChanged: true)
    }

    func stop() {
        running = false
        endTimer.cancel()
    }

    func send(_ command: PlayerCommand) {
        guard running else { return }
        let now = CACurrentMediaTime()
        let current = currentPosition(at: now)
        var trackChanged = false
        switch command {
        case .play:
            position = current
            playing = true
        case .pause:
            position = current
            playing = false
        case .next:
            index = (index + 1) % items.count
            position = 0
            playing = true
            trackChanged = true
        case .previous:
            if current > 3 {
                position = 0
            } else {
                index = (index - 1 + items.count) % items.count
                position = 0
                trackChanged = true
            }
        case .seek(let seconds):
            position = seconds.clamped(0, items[index].track.duration)
        case .setVolume(let value):
            volume = value.clamped(0, 100)
            return
        }
        stamp = now
        emit(trackChanged: trackChanged)
    }

    func refresh() {
        guard running else { return }
        emit(trackChanged: false)
        events?(.volume(volume))
    }

    func recheckPermission() {
        events?(.permission(.granted))
    }

    // MARK: Test hooks

    var trackCount: Int { items.count }

    func jump(to newIndex: Int, playing shouldPlay: Bool = true, position newPosition: Double = 0) {
        index = ((newIndex % items.count) + items.count) % items.count
        position = newPosition
        playing = shouldPlay
        stamp = CACurrentMediaTime()
        emit(trackChanged: true)
    }

    // MARK: Internals

    private func currentPosition(at time: CFTimeInterval) -> Double {
        let value = playing ? position + (time - stamp) : position
        return value.clamped(0, items[index].track.duration)
    }

    private func emit(trackChanged: Bool) {
        let item = items[index]
        let state: PlayState = playing ? .playing : .paused
        events?(.snapshot(PlaybackSnapshot(track: item.track, state: state, position: position, stamp: stamp)))
        if trackChanged {
            events?(.artwork(trackID: item.track.id, artwork: item.artwork))
        }
        endTimer.cancel()
        if playing {
            let remaining = max(0.1, item.track.duration - position)
            endTimer.schedule(after: remaining) { [weak self] in
                guard let self, self.running, self.playing else { return }
                self.send(.next)
            }
        }
    }

    private static func makeItems() -> [Item] {
        func color(_ hex: UInt32) -> NSColor {
            NSColor(
                calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }
        func cover(_ colors: [UInt32], angle: CGFloat, dot: UInt32) -> NSImage {
            NSImage(size: NSSize(width: 160, height: 160), flipped: false) { rect in
                NSGradient(colors: colors.map(color))?.draw(in: rect, angle: angle)
                color(dot).withAlphaComponent(0.9).setFill()
                NSBezierPath(ovalIn: NSRect(x: 98, y: 96, width: 30, height: 30)).fill()
                return true
            }
        }
        func item(_ number: Int, _ title: String, _ artist: String, _ duration: Double, accent: UInt32,
                  colors: [UInt32], angle: CGFloat, dot: UInt32) -> Item {
            Item(
                track: Track(id: DevFlags.demoTrackPrefix + "\(number)", title: title, artist: artist, album: tr("Демо", "Demo"), duration: duration),
                artwork: Artwork(image: cover(colors, angle: angle, dot: dot), accent: color(accent))
            )
        }
        // Monochrome covers in graphite and silver, matching the icon; the equalizer is light grey.
        return [
            item(1, tr("Северный ветер", "North Wind"), tr("Полярная ночь", "Polar Night"), 221, accent: 0xF5F6F8,
                 colors: [0x1E1F23, 0x3A3C43, 0x6A6E78], angle: 100, dot: 0xF2F3F5),
            item(2, "Neon Arcade Dreams (Extended Night Drive Mix)", "Kairo Sun", 312, accent: 0xE4E6EA,
                 colors: [0x858B96, 0xC3C7CE, 0xF4F5F7], angle: 100, dot: 0x2A2C31),
            item(3, tr("Амбра", "Amber"), tr("Тёплые сны", "Warm Dreams"), 178, accent: 0xEDEEF1,
                 colors: [0x0E0E10, 0x2B2C30, 0x55585F], angle: 50, dot: 0xD9DBE0),
            item(4, "Glasshouse", "Mira Okoye", 207, accent: 0xEDEFF2,
                 colors: [0x2A2C31, 0x5C6068, 0x9EA3AC], angle: 120, dot: 0xFFFFFF),
            item(5, "Low Tide", "Velvet Harbor", 245, accent: 0xDADCE0,
                 colors: [0x15161A, 0x34363C, 0x4A4D54], angle: 90, dot: 0xC9CCD2),
        ]
    }
}

/// In-memory stand-in for the Spotify account in demo mode.
final class DemoLikeService: LikeService {
    var isConnected = true
    private var liked: Set<String> = [DevFlags.demoTrackPrefix + "2", DevFlags.demoTrackPrefix + "4"]
    private let lock = NSLock()

    func isLiked(trackURI: String) async throws -> Bool {
        lock.withLock { liked.contains(trackURI) }
    }

    func setLiked(_ value: Bool, trackURI: String) async throws {
        lock.withLock {
            if value { liked.insert(trackURI) } else { liked.remove(trackURI) }
        }
    }
}
