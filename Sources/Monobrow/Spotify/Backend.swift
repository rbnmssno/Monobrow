import AppKit

enum PlayState: Equatable {
    case playing
    case paused
    case stopped
}

struct Track: Equatable {
    /// Spotify URI, for example `spotify:track:3BKbv6EpaveHeaRknr6H7U`.
    let id: String
    let title: String
    let artist: String
    let album: String
    /// Seconds.
    let duration: Double

    /// Only regular tracks can be saved to Liked Songs; episodes and local files cannot.
    var isLikeable: Bool { id.hasPrefix("spotify:track:") }
}

struct PlaybackSnapshot: Equatable {
    var track: Track?
    var state: PlayState
    /// Playback position in seconds at the moment `stamp`.
    var position: Double
    /// `CACurrentMediaTime()` when the position was read.
    var stamp: CFTimeInterval
}

enum AutomationPermission: Equatable {
    case unknown
    case granted
    case denied
}

enum PlayerCommand: Equatable {
    case play
    case pause
    case next
    case previous
    case seek(Double)
    case setVolume(Int)
}

enum BackendEvent {
    case snapshot(PlaybackSnapshot)
    case volume(Int)
    case artworkURL(trackID: String, url: URL?)
    case artwork(trackID: String, artwork: Artwork?)
    case permission(AutomationPermission)
    case commandFailed
}

/// Source of playback state and sink for playback commands. `events` is always called on the main thread.
protocol PlayerBackend: AnyObject {
    var events: ((BackendEvent) -> Void)? { get set }
    func start()
    func stop()
    func send(_ command: PlayerCommand)
    /// Re-reads state, position and volume from the player.
    func refresh()
    /// Checks again whether the app may control the player, without asking the user.
    func recheckPermission()
}

/// The notification Spotify posts on every play, pause, seek and track change.
enum SpotifyNotification {
    static let name = Notification.Name("com.spotify.client.PlaybackStateChanged")

    static func snapshot(from info: [AnyHashable: Any], stamp: CFTimeInterval) -> PlaybackSnapshot? {
        guard let stateText = info["Player State"] as? String else { return nil }
        let state: PlayState
        switch stateText {
        case "Playing": state = .playing
        case "Paused": state = .paused
        default: state = .stopped
        }
        var track: Track?
        if let id = info["Track ID"] as? String, !id.isEmpty {
            let milliseconds = (info["Duration"] as? NSNumber)?.doubleValue ?? 0
            track = Track(
                id: id,
                title: (info["Name"] as? String) ?? "",
                artist: (info["Artist"] as? String) ?? "",
                album: (info["Album"] as? String) ?? "",
                duration: max(0, milliseconds / 1000)
            )
        }
        let position = (info["Playback Position"] as? NSNumber)?.doubleValue ?? 0
        return PlaybackSnapshot(track: track, state: state, position: max(0, position), stamp: stamp)
    }
}
