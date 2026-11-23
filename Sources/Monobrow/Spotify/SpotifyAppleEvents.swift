import AppKit
import Carbon

enum SpotifyAEError: Error, Equatable {
    case notRunning
    case notPermitted
    case timeout
    case noSuchObject
    case other(Int)

    init(status: Int) {
        switch status {
        case -600, -609, -903, -906: self = .notRunning
        case -1743, -1744: self = .notPermitted
        case -1712: self = .timeout
        case -1728: self = .noSuchObject
        default: self = .other(status)
        }
    }
}

enum AutomationCheck: Equatable {
    case granted
    case denied
    case undetermined
    case notRunning
}

private func fourCC(_ text: String) -> FourCharCode {
    var code: FourCharCode = 0
    for byte in text.utf8 { code = (code << 8) | FourCharCode(byte) }
    return code
}

/// Talks to the Spotify desktop app with raw Apple Events, using the codes from Spotify's scripting
/// dictionary. Unlike AppleScript, this never launches Spotify and needs no script compiler.
/// Every call blocks until Spotify answers, so call it off the main thread.
final class SpotifyAppleEvents {
    static let bundleID = "com.spotify.client"

    struct FullState {
        var snapshot: PlaybackSnapshot
        var volume: Int?
        var artworkURL: URL?
    }

    private let target = NSAppleEventDescriptor(bundleIdentifier: SpotifyAppleEvents.bundleID)
    private let timeout: TimeInterval = 3

    // MARK: Permission

    func permission(askUser: Bool) -> AutomationCheck {
        guard let address = target.aeDesc else { return .undetermined }
        let status = AEDeterminePermissionToAutomateTarget(address, fourCC("****"), fourCC("****"), askUser)
        switch Int(status) {
        case 0: return .granted
        case -1743: return .denied
        case -600: return .notRunning
        default: return .undetermined
        }
    }

    // MARK: Commands

    func perform(_ command: PlayerCommand) throws {
        switch command {
        case .play: try send(event("spfy", "Play"))
        case .pause: try send(event("spfy", "Paus"))
        case .next: try send(event("spfy", "Next"))
        case .previous: try send(event("spfy", "Prev"))
        case .seek(let seconds):
            try set(property("pPos"), to: NSAppleEventDescriptor(double: max(0, seconds)))
        case .setVolume(let volume):
            try set(property("pVol"), to: NSAppleEventDescriptor(int32: Int32(volume.clamped(0, 100))))
        }
    }

    // MARK: Queries

    /// State, track, position and volume. The values are read one by one, so the track can change
    /// in between; the read is repeated until all of them describe the same track.
    func fullState() throws -> FullState {
        var state = try readState()
        for _ in 0..<2 {
            let idNow = (try? text("ID  ", of: property("pTrk"))) ?? ""
            if idNow == (state.snapshot.track?.id ?? "") { break }
            state = try readState()
        }
        return state
    }

    private func readState() throws -> FullState {
        let stateCode = try get(property("pPlS")).enumCodeValue
        let volume = try? Int(get(property("pVol")).int32Value)

        let trackSpecifier = property("pTrk")
        var track: Track?
        var artworkURL: URL?
        do {
            let id = try text("ID  ", of: trackSpecifier)
            if !id.isEmpty {
                let milliseconds = Double(try get(property("pDur", of: trackSpecifier)).int32Value)
                track = Track(
                    id: id,
                    title: try text("pnam", of: trackSpecifier),
                    artist: try text("pArt", of: trackSpecifier),
                    album: try text("pAlb", of: trackSpecifier),
                    duration: max(0, milliseconds / 1000)
                )
                artworkURL = Self.webURL(try? text("aUrl", of: trackSpecifier))
            }
        } catch let error as SpotifyAEError where error == .notPermitted || error == .notRunning || error == .timeout {
            throw error
        } catch {
            track = nil // nothing is loaded in the player
        }

        var position = 0.0
        if track != nil { position = (try? get(property("pPos")).doubleValue) ?? 0 }
        let stamp = CACurrentMediaTime()

        let state: PlayState
        switch stateCode {
        case fourCC("kPSP"): state = .playing
        case fourCC("kPSp"): state = .paused
        default: state = .stopped
        }
        let snapshot = PlaybackSnapshot(track: track, state: state, position: max(0, position), stamp: stamp)
        return FullState(snapshot: snapshot, volume: volume, artworkURL: artworkURL)
    }

    /// Cover address of the current track, or nil when another track is already playing.
    func artworkURL(expectedTrackID: String) throws -> URL? {
        let trackSpecifier = property("pTrk")
        guard try text("ID  ", of: trackSpecifier) == expectedTrackID else { return nil }
        return Self.webURL(try text("aUrl", of: trackSpecifier))
    }

    private static func webURL(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return url
    }

    // MARK: Apple Event plumbing

    private func text(_ code: String, of container: NSAppleEventDescriptor) throws -> String {
        try get(property(code, of: container)).stringValue ?? ""
    }

    private func event(_ eventClass: String, _ eventID: String) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(
            eventClass: fourCC(eventClass),
            eventID: fourCC(eventID),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
    }

    /// Object specifier "property <code> of <container>"; the container defaults to the application.
    private func property(_ code: String, of container: NSAppleEventDescriptor? = nil) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: fourCC("prop")), forKeyword: fourCC("want"))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: fourCC("prop")), forKeyword: fourCC("form"))
        record.setDescriptor(NSAppleEventDescriptor(typeCode: fourCC(code)), forKeyword: fourCC("seld"))
        record.setDescriptor(container ?? NSAppleEventDescriptor.null(), forKeyword: fourCC("from"))
        return record.coerce(toDescriptorType: fourCC("obj ")) ?? record
    }

    private func get(_ specifier: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let request = event("core", "getd")
        request.setParam(specifier, forKeyword: fourCC("----"))
        let reply = try send(request)
        guard let value = reply.paramDescriptor(forKeyword: fourCC("----")) else {
            throw SpotifyAEError.noSuchObject
        }
        return value
    }

    private func set(_ specifier: NSAppleEventDescriptor, to value: NSAppleEventDescriptor) throws {
        let request = event("core", "setd")
        request.setParam(specifier, forKeyword: fourCC("----"))
        request.setParam(value, forKeyword: fourCC("data"))
        try send(request)
    }

    @discardableResult
    private func send(_ request: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let reply: NSAppleEventDescriptor
        do {
            reply = try request.sendEvent(options: [.waitForReply, .neverInteract], timeout: timeout)
        } catch {
            throw SpotifyAEError(status: (error as NSError).code)
        }
        if let errorNumber = reply.paramDescriptor(forKeyword: fourCC("errn"))?.int32Value, errorNumber != 0 {
            throw SpotifyAEError(status: Int(errorNumber))
        }
        return reply
    }
}
