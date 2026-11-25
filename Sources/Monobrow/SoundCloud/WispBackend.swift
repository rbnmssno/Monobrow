import AppKit

/// SoundCloud, played in Wisp (a desktop window for soundcloud.com). Wisp posts every change as a
/// distributed notification with Spotify's own keys, so the same parser reads it; commands go back the
/// same way. Nothing here polls, and no permission is needed.
final class WispBackend: NSObject, PlayerBackend {
    static let bundleID = "app.wisp.Wisp"
    static let stateName = Notification.Name("app.wisp.Wisp.PlaybackStateChanged")
    static let commandName = Notification.Name("app.wisp.Wisp.Command")

    var events: ((BackendEvent) -> Void)?
    private var observing = false
    private var artworkTrackID: String?
    private var artworkAddress: String?
    /// The like state Wisp last reported, by track.
    private(set) var liked: [String: Bool] = [:]
    private(set) var currentTrackID: String?
    /// A like sent from the island and not yet confirmed: reports from before the page took the click
    /// still carry the old state and must not flip the heart back.
    private var pendingLike: (id: String, value: Bool, until: CFTimeInterval)?

    func start() {
        artworkTrackID = nil
        artworkAddress = nil
        if !observing {
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(changed(_:)), name: Self.stateName,
                                                                object: nil, suspensionBehavior: .deliverImmediately)
            observing = true
        }
        events?(.permission(.granted))
        post("refresh")
    }

    func stop() {
        if observing {
            DistributedNotificationCenter.default().removeObserver(self, name: Self.stateName, object: nil)
            observing = false
        }
    }

    func send(_ command: PlayerCommand) {
        switch command {
        case .play: post("play")
        case .pause: post("pause")
        case .next: post("next")
        case .previous: post("previous")
        case .seek(let seconds): post("seek", seconds)
        case .setVolume(let value): post("volume", Double(value))
        }
    }

    func refresh() { post("refresh") }

    func recheckPermission() { events?(.permission(.granted)) }

    /// Wisp's like button toggles, so it is pressed only when the state differs.
    func setLiked(_ target: Bool, trackID: String) {
        guard trackID == currentTrackID, liked[trackID] != target else { return }
        liked[trackID] = target
        pendingLike = (trackID, target, CACurrentMediaTime() + 3)
        post("like")
    }

    private func post(_ command: String, _ value: Double? = nil) {
        var info: [String: Any] = ["Command": command]
        if let value { info["Value"] = value }
        DistributedNotificationCenter.default().postNotificationName(Self.commandName, object: nil, userInfo: info, deliverImmediately: true)
    }

    @objc private func changed(_ note: Notification) {
        let info = note.userInfo ?? [:]
        let stamp = CACurrentMediaTime()
        DispatchQueue.main.async { [weak self] in self?.apply(info, stamp: stamp) }
    }

    private func apply(_ info: [AnyHashable: Any], stamp: CFTimeInterval) {
        guard observing, let snapshot = SpotifyNotification.snapshot(from: info, stamp: stamp) else { return }
        currentTrackID = snapshot.track?.id
        Log.debug("wisp: \(snapshot.state) \(snapshot.track?.artist ?? "") — \(snapshot.track?.title ?? "") at \(Int(snapshot.position)) s")
        events?(.snapshot(snapshot))
        if let volume = info["Volume"] as? NSNumber { events?(.volume(volume.intValue)) }
        guard let track = snapshot.track else { return }
        let address = info["Artwork URL"] as? String ?? ""
        if track.id != artworkTrackID || address != artworkAddress {
            artworkTrackID = track.id
            artworkAddress = address
            events?(.artworkURL(trackID: track.id, url: address.isEmpty ? nil : URL(string: address)))
        }
        if let value = info["Liked"] as? Bool {
            if let p = pendingLike, p.id == track.id {
                if value == p.value || stamp > p.until { pendingLike = nil } else { return }
            }
            liked[track.id] = value
            events?(.liked(trackID: track.id, liked: value))
        }
    }
}

/// Likes go where the track came from: SoundCloud tracks to Wisp, Spotify tracks to the Spotify account.
final class RoutingLikeService: LikeService {
    private let spotify: LikeService
    private let soundcloud: WispBackend

    init(spotify: LikeService, soundcloud: WispBackend) {
        self.spotify = spotify
        self.soundcloud = soundcloud
    }

    /// The Spotify account; SoundCloud likes need no account here (Wisp is signed in itself).
    var isConnected: Bool { spotify.isConnected }

    func isLiked(trackURI: String) async throws -> Bool {
        guard trackURI.hasPrefix("soundcloud:") else { return try await spotify.isLiked(trackURI: trackURI) }
        return await MainActor.run { soundcloud.liked[trackURI] ?? false }
    }

    func setLiked(_ liked: Bool, trackURI: String) async throws {
        guard trackURI.hasPrefix("soundcloud:") else { return try await spotify.setLiked(liked, trackURI: trackURI) }
        await MainActor.run { soundcloud.setLiked(liked, trackID: trackURI) }
    }
}
