import AppKit

/// The real player: Spotify pushes state changes as distributed notifications, and commands go out
/// as Apple Events on a background queue. Nothing here polls.
final class SpotifyBackend: NSObject, PlayerBackend {
    var events: ((BackendEvent) -> Void)?

    private let appleEvents = SpotifyAppleEvents()
    private let queue = DispatchQueue(label: "app.monobrow.Monobrow.apple-events", qos: .userInitiated)

    // Main-thread state.
    private var generation = 0
    private var observing = false
    private var bootstrapped = false
    private var refreshing = false
    private var permission = AutomationPermission.unknown
    private var artworkTrackID: String?
    /// When the last notification arrived (`CACurrentMediaTime()`); reads that started earlier are stale.
    private var lastNotification: CFTimeInterval = 0

    private static let bootstrapDelays: [TimeInterval] = [0.3, 1.2, 2.5, 5, 8, 12, 20]

    func start() {
        generation += 1
        bootstrapped = false
        refreshing = false
        artworkTrackID = nil
        lastNotification = 0
        if !observing {
            DistributedNotificationCenter.default().addObserver(
                self,
                selector: #selector(playbackChanged(_:)),
                name: SpotifyNotification.name,
                object: nil,
                suspensionBehavior: .deliverImmediately
            )
            observing = true
        }
        bootstrap(attempt: 0, generation: generation)
    }

    func stop() {
        generation += 1
        refreshing = false
        if observing {
            DistributedNotificationCenter.default().removeObserver(self, name: SpotifyNotification.name, object: nil)
            observing = false
        }
    }

    func send(_ command: PlayerCommand) {
        let current = generation
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.appleEvents.perform(command)
                Log.debug("command sent: \(command)")
            } catch {
                DispatchQueue.main.async {
                    guard current == self.generation else { return }
                    self.handle(error)
                    self.events?(.commandFailed)
                }
            }
        }
    }

    func refresh() {
        read(retriesLeft: 1)
    }

    private func read(retriesLeft: Int) {
        guard !refreshing else { return }
        refreshing = true
        let current = generation
        queue.async { [weak self] in
            guard let self else { return }
            let started = CACurrentMediaTime()
            let result = Result { try self.appleEvents.fullState() }
            DispatchQueue.main.async {
                guard current == self.generation else { return }
                self.refreshing = false
                switch result {
                case .success(let state):
                    // A notification that arrived while Spotify was being read is newer than
                    // this answer: drop the answer and read once more.
                    if self.lastNotification >= started {
                        Log.debug("refresh: overtaken by a notification")
                        if retriesLeft > 0 { self.read(retriesLeft: retriesLeft - 1) }
                        return
                    }
                    Log.debug("refresh: \(Self.describe(state))")
                    self.deliver(state)
                case .failure(let error):
                    self.handle(error)
                }
            }
        }
    }

    func recheckPermission() {
        let current = generation
        queue.async { [weak self] in
            guard let self else { return }
            let check = self.appleEvents.permission(askUser: false)
            DispatchQueue.main.async {
                guard current == self.generation else { return }
                switch check {
                case .granted:
                    self.setPermission(.granted)
                    if !self.bootstrapped { self.bootstrap(attempt: 0, generation: current) }
                case .denied:
                    self.setPermission(.denied)
                case .undetermined, .notRunning:
                    break
                }
            }
        }
    }

    // MARK: Start-up

    /// Asks for permission once and reads the initial state. Spotify needs a moment after launch
    /// before it answers Apple Events, so failures are retried a few times.
    private func bootstrap(attempt: Int, generation current: Int) {
        guard attempt < Self.bootstrapDelays.count else { return }
        queue.asyncAfter(deadline: .now() + Self.bootstrapDelays[attempt]) { [weak self] in
            guard let self else { return }
            let check = self.appleEvents.permission(askUser: true)
            var state: SpotifyAppleEvents.FullState?
            var failure: Error?
            let started = CACurrentMediaTime()
            if check == .granted {
                do { state = try self.appleEvents.fullState() } catch { failure = error }
            }
            Log.debug("bootstrap attempt \(attempt + 1): permission=\(check) state=\(state.map { Self.describe($0) } ?? "-") failure=\(failure.map { "\($0)" } ?? "-")")
            DispatchQueue.main.async {
                guard current == self.generation else { return }
                if check == .denied {
                    self.setPermission(.denied)
                    return
                }
                if let state {
                    self.bootstrapped = true
                    if self.lastNotification >= started {
                        self.setPermission(.granted)
                        self.read(retriesLeft: 1)
                    } else {
                        self.deliver(state)
                    }
                    return
                }
                if let failure, (failure as? SpotifyAEError) == .notPermitted {
                    self.setPermission(.denied)
                    return
                }
                self.bootstrap(attempt: attempt + 1, generation: current)
            }
        }
    }

    // MARK: Incoming state

    @objc private func playbackChanged(_ note: Notification) {
        guard let info = note.userInfo,
              let snapshot = SpotifyNotification.snapshot(from: info, stamp: CACurrentMediaTime()) else { return }
        Log.debug("notification: state=\(snapshot.state) track=\(snapshot.track?.id ?? "-") position=\(snapshot.position)")
        lastNotification = snapshot.stamp
        events?(.snapshot(snapshot))

        guard let id = snapshot.track?.id else {
            artworkTrackID = nil // if this track comes back, its cover is asked for again
            return
        }
        guard id != artworkTrackID else { return }
        artworkTrackID = id
        let current = generation
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.appleEvents.artworkURL(expectedTrackID: id) }
            DispatchQueue.main.async {
                guard current == self.generation, self.artworkTrackID == id else { return }
                switch result {
                case .success(let url):
                    Log.debug("cover address: \(url?.host ?? "none")")
                    self.events?(.artworkURL(trackID: id, url: url))
                case .failure(let error):
                    self.handle(error)
                    // Forget the attempt, so the next state read (for example on opening the
                    // player) asks for the cover again.
                    self.artworkTrackID = nil
                    self.events?(.artworkURL(trackID: id, url: nil))
                }
            }
        }
    }

    private func deliver(_ state: SpotifyAppleEvents.FullState) {
        setPermission(.granted)
        events?(.snapshot(state.snapshot))
        if let volume = state.volume { events?(.volume(volume)) }
        guard let id = state.snapshot.track?.id else {
            artworkTrackID = nil
            return
        }
        if id != artworkTrackID {
            artworkTrackID = id
            events?(.artworkURL(trackID: id, url: state.artworkURL))
        }
    }

    private func handle(_ error: Error) {
        guard let error = error as? SpotifyAEError else { return }
        if error == .notPermitted { setPermission(.denied) }
        Log.debug("apple event failed: \(error)")
    }

    /// Technical summary for the development log; it leaves out titles and artists.
    private static func describe(_ state: SpotifyAppleEvents.FullState) -> String {
        let snapshot = state.snapshot
        let position = String(format: "%.1f", snapshot.position)
        let duration = String(format: "%.1f", snapshot.track?.duration ?? 0)
        return "\(snapshot.state) track=\(snapshot.track?.id ?? "-") titleLength=\(snapshot.track?.title.count ?? 0) "
            + "position=\(position)/\(duration) volume=\(state.volume.map(String.init) ?? "-") cover=\(state.artworkURL?.host ?? "none")"
    }

    private func setPermission(_ value: AutomationPermission) {
        guard permission != value else { return }
        permission = value
        events?(.permission(value))
    }
}
