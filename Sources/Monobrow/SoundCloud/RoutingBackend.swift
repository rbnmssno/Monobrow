import AppKit

/// One island, two players. Spotify and SoundCloud (in Wisp) each run their own backend; the island
/// shows the one that played last, and its buttons control that one. Whichever starts playing takes the
/// island; when the shown one quits, the other one (if running) takes over.
final class RoutingBackend: PlayerBackend {
    enum Source: CustomStringConvertible {
        case spotify, soundcloud
        var description: String { self == .spotify ? "Spotify" : "SoundCloud" }
    }

    var events: ((BackendEvent) -> Void)?
    private let spotify: PlayerBackend
    private let soundcloud: WispBackend
    private var running: [Source: Bool] = [.spotify: false, .soundcloud: false]
    private var started = false
    private var live: Set<Source> = []
    private(set) var active: Source = .spotify

    /// What each player last said, so switching shows the full picture at once.
    private struct Memory {
        var snapshot: PlaybackSnapshot?
        var volume: Int?
        var artworkURL: (id: String, url: URL?)?
        var artwork: (id: String, artwork: Artwork?)?
        var permission: AutomationPermission?
    }
    private var memory: [Source: Memory] = [:]

    init(spotify: PlayerBackend, soundcloud: WispBackend) {
        self.spotify = spotify
        self.soundcloud = soundcloud
        spotify.events = { [weak self] event in self?.handle(.spotify, event) }
        soundcloud.events = { [weak self] event in self?.handle(.soundcloud, event) }
    }

    var anyRunning: Bool { running.values.contains(true) }

    /// From the app watchers. A backend runs only while its app does: an Apple Event to a Spotify that
    /// is not running would start it.
    func setRunning(_ source: Source, _ value: Bool) {
        guard running[source] != value else { return }
        running[source] = value
        if !value { memory[source] = nil }
        syncBackends()
        if !value, active == source, let other = otherRunning(than: source) {
            switchTo(other)
        } else if value, running[active] != true {
            switchTo(source)
        }
    }

    func start() {
        started = true
        if running[active] != true, let other = otherRunning(than: active) { active = other }
        syncBackends()
        events?(.permission(active == .soundcloud ? .granted : (memory[.spotify]?.permission ?? .unknown)))
    }

    func stop() {
        started = false
        syncBackends()
    }

    func send(_ command: PlayerCommand) { backend(active).send(command) }
    func refresh() { backend(active).refresh() }
    func recheckPermission() { spotify.recheckPermission() }

    // MARK: Private

    private func backend(_ source: Source) -> PlayerBackend { source == .spotify ? spotify : soundcloud }

    private func otherRunning(than source: Source) -> Source? {
        let other: Source = source == .spotify ? .soundcloud : .spotify
        return running[other] == true ? other : nil
    }

    private func syncBackends() {
        for source in [Source.spotify, .soundcloud] {
            let wanted = started && running[source] == true
            if wanted, !live.contains(source) {
                live.insert(source)
                backend(source).start()
            } else if !wanted, live.contains(source) {
                live.remove(source)
                backend(source).stop()
            }
        }
    }

    private func handle(_ source: Source, _ event: BackendEvent) {
        guard live.contains(source) else { return }
        var m = memory[source] ?? Memory()
        switch event {
        case .snapshot(let s): m.snapshot = s
        case .volume(let v): m.volume = v
        case .artworkURL(let id, let url): m.artworkURL = (id, url); m.artwork = nil
        case .artwork(let id, let artwork): m.artwork = (id, artwork)
        case .permission(let p): m.permission = p
        case .commandFailed, .liked: break
        }
        memory[source] = m
        // Whoever starts playing takes the island.
        if case .snapshot(let s) = event, s.state == .playing, source != active {
            switchTo(source)
            return
        }
        guard source == active else { return }
        // Spotify's permission says nothing about SoundCloud, which needs none.
        if case .permission = event, source == .soundcloud { events?(.permission(.granted)); return }
        events?(event)
    }

    private func switchTo(_ source: Source) {
        guard source != active else { return }
        active = source
        Log.debug("island shows \(source)")
        let m = memory[source] ?? Memory()
        events?(.permission(source == .soundcloud ? .granted : (m.permission ?? .unknown)))
        if let s = m.snapshot {
            events?(.snapshot(s))
        } else {
            events?(.snapshot(PlaybackSnapshot(track: nil, state: .stopped, position: 0, stamp: CACurrentMediaTime())))
            if live.contains(source) { backend(source).refresh() }
        }
        if let v = m.volume { events?(.volume(v)) }
        if let a = m.artworkURL { events?(.artworkURL(trackID: a.id, url: a.url)) }
        if let a = m.artwork { events?(.artwork(trackID: a.id, artwork: a.artwork)) }
        if source == .soundcloud, let id = m.snapshot?.track?.id, let liked = soundcloud.liked[id] {
            events?(.liked(trackID: id, liked: liked))
        }
    }
}
