import AppKit
import Combine
import QuartzCore

enum IslandMode: Int, Equatable {
    case hidden = 0
    case compact = 1
    case peek = 2
    case expanded = 3
}

enum LikeStatus: Equatable {
    case unknown
    case notLiked
    case liked
}

/// Where playback was at a known moment; the current position is extrapolated from it.
struct PositionAnchor: Equatable {
    var position = 0.0
    var stamp: CFTimeInterval = 0
    var playing = false
    /// Seconds of the track per second of real time. Music is always 1; podcasts can differ.
    var rate = 1.0

    func position(at time: CFTimeInterval, duration: Double) -> Double {
        let value = playing ? position + (time - stamp) * rate : position
        return value.clamped(0, max(0, duration))
    }
}

struct TrackTransition: Equatable {
    var serial = 0
    /// +1 when moving forward through the queue, -1 when going back.
    var direction = 1
}

struct LikeEffect: Equatable {
    enum Kind {
        case liked
        case unliked
        case denied
    }

    var serial = 0
    var kind = Kind.liked
}

struct PlayerNote: Equatable {
    enum Tone {
        case positive
        case neutral
    }

    var text: String
    var tone: Tone
    var serial: Int
}

/// Everything the island shows and every action it can take. Lives on the main thread.
/// It reacts to events pushed by the backend; the only timers are short one-shots
/// and a once-a-second clock that runs while the player is open.
final class PlayerModel: ObservableObject {
    static let defaultAccent = NSColor(calibratedRed: 0.557, green: 0.847, blue: 1, alpha: 1)

    // MARK: Published state

    @Published private(set) var spotifyRunning = false
    @Published private(set) var track: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var anchor = PositionAnchor()
    /// Position shown by the time labels. Updated once a second while the player is open.
    @Published private(set) var clock = 0.0
    /// Bumped when the progress bar and the time labels should glide to the current position.
    @Published private(set) var seekGlide = 0
    @Published private(set) var isScrubbing = false
    @Published private(set) var volume = 50
    @Published private(set) var volumeGlide = 0
    @Published private(set) var artwork: NSImage?
    @Published private(set) var artworkKey = "none"
    @Published private(set) var accent = PlayerModel.defaultAccent
    @Published private(set) var transition = TrackTransition()
    @Published private(set) var likeStatus = LikeStatus.unknown
    /// What the heart shows. It equals `likeStatus` once that is known; before that it may
    /// still show the look of the previous track for a moment.
    @Published private(set) var likeShown = false
    @Published private(set) var likeEffect = LikeEffect()
    @Published private(set) var loveBurst = 0
    @Published private(set) var note: PlayerNote?
    @Published private(set) var peekActive = false
    @Published private(set) var hiddenByPause = false
    @Published private(set) var permission = AutomationPermission.unknown
    @Published private(set) var accountConnected = false
    @Published private(set) var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    /// Called when a control was used but macOS does not let the app control Spotify.
    var onPermissionProblem: (() -> Void)?

    var likeAvailable: Bool { accountConnected && (track?.isLikeable ?? false) }
    var duration: Double { track?.duration ?? 0 }

    // MARK: Private state

    private let prefs: Preferences
    private let timing: Timing
    private var backend: PlayerBackend?
    private var likes: LikeService?
    private let artworkLoader = ArtworkLoader()
    private var bag = Set<AnyCancellable>()
    private var powerObserver: NSObjectProtocol?

    private var firstSnapshot = true
    private var pendingDirection: (direction: Int, time: CFTimeInterval)?
    private var expandedIslands = 0

    private let peekTimer = OneShot()
    private let pauseTimer = OneShot()
    private let noteTimer = OneShot()
    private let verifyTimer = OneShot()
    private let cleanupTimer = OneShot()
    private let artworkGrace = OneShot()
    private let likeFetch = OneShot()
    private let likeHold = OneShot()
    private let volumeSender = OneShot()
    private var clockTimer: Timer?
    private var resyncTimer: Timer?

    private var noteSerial = 0
    private var likeCache: [String: Bool] = [:]
    private var likeChain: Task<Void, Never>?
    /// Per track: likes or unlikes made here that Spotify has not confirmed yet.
    private var pendingLikeWrites: [String: Int] = [:]
    /// Per track: grows whenever a like made here starts or finishes. An answer about the like
    /// state that was requested before the latest change is out of date.
    private var likeVersions: [String: Int] = [:]

    /// The last state Spotify itself reported, to fall back on when a command fails.
    private var confirmed: PlaybackSnapshot?
    /// Podcast speed, measured from two position reports of the same episode.
    private var episodeRate: (id: String, rate: Double)?
    private var rateBaseline: (id: String, position: Double, stamp: CFTimeInterval)?
    private static let episodeSpeeds: [Double] = [0.5, 0.8, 1, 1.2, 1.5, 1.8, 2, 2.5, 3, 3.5]

    private var volumeScrubbing = false
    private var volumeKnown = false
    private var volumeDirty = false
    private var sentVolume = -1
    private var volumeBeforeMute = 50
    private var lastLocalVolumeChange: CFTimeInterval = 0

    init(prefs: Preferences, timing: Timing = .standard) {
        self.prefs = prefs
        self.timing = timing
        prefs.$hideWhenPaused.dropFirst().sink { [weak self] enabled in
            self?.hideSettingChanged(enabled)
        }.store(in: &bag)
        prefs.$showPeek.dropFirst().sink { [weak self] enabled in
            if !enabled { self?.endPeek() }
        }.store(in: &bag)
        powerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    deinit {
        if let powerObserver { NotificationCenter.default.removeObserver(powerObserver) }
        clockTimer?.invalidate()
        resyncTimer?.invalidate()
    }

    func attach(backend: PlayerBackend, likes: LikeService?) {
        self.backend = backend
        self.likes = likes
        backend.events = { [weak self] event in self?.handle(event) }
        accountConnected = likes?.isConnected ?? false
    }

    // MARK: Spotify lifecycle

    func spotifyDidLaunch() {
        guard !spotifyRunning else { return }
        cleanupTimer.cancel()
        resetPlayback()
        firstSnapshot = true
        spotifyRunning = true
        backend?.start()
    }

    func spotifyDidQuit() {
        guard spotifyRunning else { return }
        spotifyRunning = false
        backend?.stop()
        cancelTimers()
        // Keep the last track on screen while the island folds away, then forget it.
        cleanupTimer.schedule(after: 1) { [weak self] in
            guard let self, !self.spotifyRunning else { return }
            self.resetPlayback()
            self.artworkLoader.removeAll()
            self.likeCache.removeAll()
        }
    }

    func systemDidWake() {
        guard spotifyRunning else { return }
        backend?.refresh()
    }

    // MARK: Derived state

    func mode(hovering: Bool) -> IslandMode {
        guard spotifyRunning else { return .hidden }
        if hovering { return .expanded }
        guard track != nil else { return .hidden }
        if peekActive { return .peek }
        if !isPlaying && hiddenByPause { return .hidden }
        return .compact
    }

    func currentPosition(at time: CFTimeInterval = CACurrentMediaTime()) -> Double {
        anchor.position(at: time, duration: duration)
    }

    // MARK: Island open / closed

    func islandExpansionChanged(_ expanded: Bool) {
        expandedIslands = max(0, expandedIslands + (expanded ? 1 : -1))
        if expanded {
            if !isScrubbing { clock = currentPosition() }
            if expandedIslands == 1, spotifyRunning {
                if permission == .denied { backend?.recheckPermission() } else { backend?.refresh() }
            }
        }
        updateTimers()
    }

    // MARK: Playback commands

    func togglePlay() {
        guard canControl() else { return }
        guard track != nil else {
            backend?.send(.play)
            scheduleVerify(after: 0.8)
            return
        }
        let now = CACurrentMediaTime()
        let target = !isPlaying
        let position = currentPosition(at: now)
        anchor = PositionAnchor(position: position, stamp: now, playing: target, rate: anchor.rate)
        rateBaseline = nil
        if !isScrubbing { clock = position }
        setPlaying(target)
        backend?.send(target ? .play : .pause)
        scheduleVerify(after: timing.verifyDelay)
        updateTimers()
    }

    /// `direction` is +1 for the next track and -1 for the previous one.
    func skip(_ direction: Int) {
        guard canControl() else { return }
        let now = CACurrentMediaTime()
        pendingDirection = (direction, now)
        rateBaseline = nil
        if direction < 0, track != nil, currentPosition(at: now) > 3 {
            // Spotify restarts the current track in this case; show it right away.
            anchor = PositionAnchor(position: 0, stamp: now, playing: isPlaying, rate: anchor.rate)
            if !isScrubbing {
                clock = 0
                seekGlide += 1
            }
        }
        backend?.send(direction > 0 ? .next : .previous)
        scheduleVerify(after: 0.7)
        updateTimers()
    }

    // MARK: Seeking

    func beginScrub(at fraction: Double) {
        guard let track, track.duration > 0 else { return }
        isScrubbing = true
        clock = fraction.clamped(0, 1) * track.duration
        seekGlide += 1
        updateTimers()
    }

    func scrub(to fraction: Double) {
        guard isScrubbing, let track else { return }
        clock = fraction.clamped(0, 1) * track.duration
    }

    func endScrub(at fraction: Double, glide: Bool) {
        guard isScrubbing else { return }
        isScrubbing = false
        defer { updateTimers() }
        guard let track, track.duration > 0, canControl() else {
            clock = currentPosition()
            seekGlide += 1
            return
        }
        let position = (fraction.clamped(0, 1) * track.duration).clamped(0, max(0, track.duration - 0.5))
        anchor = PositionAnchor(position: position, stamp: CACurrentMediaTime(), playing: isPlaying, rate: anchor.rate)
        rateBaseline = nil
        clock = position
        if glide { seekGlide += 1 }
        backend?.send(.seek(position))
        scheduleVerify(after: 0.8)
    }

    // MARK: Volume

    func beginVolumeScrub(at fraction: Double) {
        guard canControl() else { return }
        volumeScrubbing = true
        setVolume(fraction)
    }

    func scrubVolume(to fraction: Double) {
        guard volumeScrubbing else { return }
        setVolume(fraction)
    }

    func endVolumeScrub(at fraction: Double, glide: Bool) {
        guard volumeScrubbing else {
            volumeGlide += 1 // nothing changed; let the slider settle back
            return
        }
        setVolume(fraction)
        volumeScrubbing = false
        if glide { volumeGlide += 1 }
    }

    func toggleMute() {
        guard canControl() else { return }
        if volume > 0 {
            volumeBeforeMute = volume
            setVolume(value: 0)
        } else {
            setVolume(value: volumeBeforeMute > 0 ? volumeBeforeMute : 50)
        }
        volumeGlide += 1
    }

    private func setVolume(_ fraction: Double) {
        setVolume(value: Int((fraction.clamped(0, 1) * 100).rounded()))
    }

    private func setVolume(value: Int) {
        let clamped = value.clamped(0, 100)
        if clamped != volume { volume = clamped }
        volumeKnown = true
        lastLocalVolumeChange = CACurrentMediaTime()
        pushVolume()
    }

    /// Sends the volume at most about 16 times a second while the slider is dragged.
    private func pushVolume() {
        guard !volumeSender.isPending else {
            volumeDirty = true
            return
        }
        if volume != sentVolume {
            sentVolume = volume
            backend?.send(.setVolume(volume))
        }
        volumeSender.schedule(after: 0.06) { [weak self] in
            guard let self, self.volumeDirty else { return }
            self.volumeDirty = false
            self.pushVolume()
        }
    }

    private func applyVolume(_ external: Int) {
        guard !volumeScrubbing, CACurrentMediaTime() - lastLocalVolumeChange > 1.5 else { return }
        let value = external.clamped(0, 100)
        // Spotify reports one step less than it was asked to set; ignore that rounding.
        if volumeKnown, abs(value - volume) <= 1 { return }
        volumeKnown = true
        sentVolume = value
        guard value != volume else { return }
        volume = value
        volumeGlide += 1
    }

    // MARK: Likes

    func toggleLike(fromCover: Bool = false) {
        guard let likes, likes.isConnected else {
            denyLike(tr("Подключи аккаунт Spotify в настройках", "Connect your Spotify account in Settings"))
            return
        }
        guard let track, track.isLikeable else {
            denyLike(tr("Это нельзя добавить в «Любимые треки»", "This can't be added to Liked Songs"))
            return
        }
        if fromCover {
            loveBurst += 1
            if likeStatus == .liked {
                likeEffect = LikeEffect(serial: likeEffect.serial + 1, kind: .liked)
                return
            }
        }
        // The button flips what the heart shows; a double-click on the cover only ever likes.
        let target = fromCover ? true : !likeShown
        let id = track.id
        likeHold.cancel()
        remember(target, for: id)
        likeStatus = target ? .liked : .notLiked
        setLikeShown(target)
        likeEffect = LikeEffect(serial: likeEffect.serial + 1, kind: target ? .liked : .unliked)
        showNote(target ? tr("Добавлено в «Любимые треки»", "Added to Liked Songs") : tr("Убрано из «Любимых треков»", "Removed from Liked Songs"), tone: target ? .positive : .neutral)

        // Requests run one after another, so a quick like-unlike reaches Spotify in the same order.
        bumpLikeVersion(id)
        pendingLikeWrites[id, default: 0] += 1
        let previous = likeChain
        likeChain = Task { [weak self] in
            await previous?.value
            var failure: Error?
            do {
                try await likes.setLiked(target, trackURI: id)
            } catch {
                failure = error
            }
            let problem = failure
            await MainActor.run { [weak self] in
                guard let self else { return }
                let left = (self.pendingLikeWrites[id] ?? 1) - 1
                self.pendingLikeWrites[id] = left > 0 ? left : nil
                self.bumpLikeVersion(id)
                if let problem { self.likeFailed(problem, trackID: id, attempted: target) }
            }
        }
    }

    func accountDidChange() {
        let connected = likes?.isConnected ?? false
        guard connected != accountConnected else { return }
        accountConnected = connected
        likeCache.removeAll()
        likeHold.cancel()
        likeStatus = .unknown
        setLikeShown(false)
        if connected { scheduleLikeFetch(after: 0.1) }
    }

    private func denyLike(_ text: String) {
        likeEffect = LikeEffect(serial: likeEffect.serial + 1, kind: .denied)
        showNote(text, tone: .neutral)
    }

    private func likeFailed(_ error: Error, trackID: String, attempted: Bool) {
        guard pendingLikeWrites[trackID] == nil else { return } // a newer request for this track decides
        likeCache.removeValue(forKey: trackID)
        guard track?.id == trackID else { return }
        likeStatus = .unknown
        setLikeShown(!attempted)
        likeEffect = LikeEffect(serial: likeEffect.serial + 1, kind: .denied)
        let text: String
        switch error as? SpotifyError {
        case .network: text = tr("Нет связи со Spotify, лайк не сохранён", "Can't reach Spotify, like not saved")
        case .rateLimited: text = tr("Spotify просит подождать с лайками", "Spotify asks to slow down with likes")
        case .reauthorizationRequired, .notConnected: text = tr("Подключи аккаунт Spotify заново", "Reconnect your Spotify account")
        case .forbidden: text = tr("Spotify отклонил лайк, см. настройки", "Spotify refused the like, see Settings")
        default: text = tr("Не получилось сохранить лайк", "Couldn't save the like")
        }
        showNote(text, tone: .neutral)
        accountDidChange()
        scheduleLikeFetch(after: 1.5)
    }

    /// On a track change the heart shows the remembered state at once. If the state is not
    /// known yet, the heart keeps its previous look for a moment while Spotify is asked, instead
    /// of blinking off and on again: neighbouring tracks are usually alike.
    private func adoptLikeState(for newTrack: Track?) {
        likeHold.cancel()
        if let id = newTrack?.id, let cached = likeCache[id] {
            likeStatus = cached ? .liked : .notLiked
            setLikeShown(cached)
            return
        }
        likeStatus = .unknown
        guard let newTrack, newTrack.isLikeable, accountConnected else {
            setLikeShown(false)
            return
        }
        guard likeShown else { return }
        likeHold.schedule(after: timing.likeHold) { [weak self] in
            guard let self, self.likeStatus == .unknown else { return }
            self.setLikeShown(false)
        }
    }

    private func setLikeShown(_ value: Bool) {
        if likeShown != value { likeShown = value }
    }

    private func remember(_ liked: Bool, for trackID: String) {
        if likeCache.count > 300 { likeCache.removeAll() }
        likeCache[trackID] = liked
    }

    private func bumpLikeVersion(_ trackID: String) {
        if likeVersions.count > 300 {
            likeVersions = likeVersions.filter { pendingLikeWrites[$0.key] != nil || $0.key == track?.id }
        }
        likeVersions[trackID, default: 0] += 1
    }

    private func scheduleLikeFetch(after delay: TimeInterval? = nil) {
        likeFetch.cancel()
        guard let likes, likes.isConnected, let track, track.isLikeable else { return }
        let id = track.id
        likeFetch.schedule(after: delay ?? timing.likeFetchDelay) { [weak self] in
            guard let self else { return }
            let version = self.likeVersions[id] ?? 0
            Task { [weak self] in
                guard let liked = try? await likes.isLiked(trackURI: id) else {
                    await MainActor.run { [weak self] in self?.accountDidChange() }
                    return
                }
                await MainActor.run { [weak self] in
                    // The answer is out of date if the like was changed here after the question
                    // was asked, or if a change is still on its way to Spotify.
                    guard let self, (self.likeVersions[id] ?? 0) == version, self.pendingLikeWrites[id] == nil else { return }
                    self.remember(liked, for: id)
                    if self.track?.id == id {
                        self.likeHold.cancel()
                        self.likeStatus = liked ? .liked : .notLiked
                        self.setLikeShown(liked)
                    }
                }
            }
        }
    }

    // MARK: Backend events

    private func handle(_ event: BackendEvent) {
        guard spotifyRunning else { return }
        switch event {
        case .snapshot(let snapshot):
            apply(snapshot)
        case .volume(let value):
            applyVolume(value)
        case .artworkURL(let trackID, let url):
            loadArtwork(trackID: trackID, url: url)
        case .artwork(let trackID, let artwork):
            setArtwork(artwork, trackID: trackID)
        case .permission(let value):
            if permission != value { permission = value }
        case .commandFailed:
            // The command did not go through: show again what Spotify last reported, then ask it.
            if let confirmed { apply(confirmed) }
            scheduleVerify(after: 0.3)
        }
    }

    private func apply(_ snapshot: PlaybackSnapshot) {
        let now = CACurrentMediaTime()
        let previousPosition = currentPosition(at: now)
        let trackChanged = snapshot.track?.id != track?.id
        let playing = snapshot.state == .playing && snapshot.track != nil
        confirmed = snapshot

        if trackChanged {
            // A drag on the progress bar belonged to the old track; releasing it must not seek the new one.
            if isScrubbing { isScrubbing = false }
            let direction = takeDirection(at: now)
            track = snapshot.track
            transition = TrackTransition(serial: transition.serial + 1, direction: direction)
            noteTimer.cancel()
            note = nil
            adoptLikeState(for: snapshot.track)
            scheduleLikeFetch()
            beginArtworkGrace()
        } else if snapshot.track != track {
            track = snapshot.track // same track, corrected details
        }

        let rate = measuredRate(for: snapshot, playing: playing)
        let newAnchor = PositionAnchor(position: snapshot.position, stamp: snapshot.stamp, playing: playing, rate: rate)
        let newPosition = newAnchor.position(at: now, duration: snapshot.track?.duration ?? 0)
        if newAnchor != anchor { anchor = newAnchor }
        if !isScrubbing {
            if trackChanged || abs(newPosition - previousPosition) > 1.5 { seekGlide += 1 }
            clock = newPosition
        }
        setPlaying(playing)
        if trackChanged, snapshot.track != nil, playing { beginPeek() }
        firstSnapshot = false
        updateTimers()
    }

    /// Spotify does not tell how fast a podcast plays, so the speed is measured from two position
    /// reports of the same episode while it keeps playing. Music always plays at normal speed.
    private func measuredRate(for snapshot: PlaybackSnapshot, playing: Bool) -> Double {
        guard let track = snapshot.track, track.id.hasPrefix("spotify:episode:") else {
            rateBaseline = nil
            episodeRate = nil
            return 1
        }
        var rate = episodeRate?.id == track.id ? (episodeRate?.rate ?? 1) : 1
        if let base = rateBaseline, base.id == track.id, playing {
            let elapsed = snapshot.stamp - base.stamp
            if elapsed < 4 { return rate } // too short to measure; keep waiting from the same start
            let observed = (snapshot.position - base.position) / elapsed
            if let speed = Self.episodeSpeeds.min(by: { abs($0 - observed) < abs($1 - observed) }),
               abs(speed - observed) < 0.06 {
                rate = speed
            }
        }
        rateBaseline = playing ? (track.id, snapshot.position, snapshot.stamp) : nil
        episodeRate = (track.id, rate)
        return rate
    }

    private func takeDirection(at time: CFTimeInterval) -> Int {
        defer { pendingDirection = nil }
        guard let pending = pendingDirection, time - pending.time < 3 else { return 1 }
        return pending.direction
    }

    private func setPlaying(_ playing: Bool) {
        if playing != isPlaying { isPlaying = playing }
        if playing {
            pauseTimer.cancel()
            if hiddenByPause { hiddenByPause = false }
        } else if firstSnapshot {
            // Monobrow started while Spotify was already paused: no reason to show the island for 10 seconds.
            if hiddenByPause != prefs.hideWhenPaused { hiddenByPause = prefs.hideWhenPaused }
        } else if prefs.hideWhenPaused, !hiddenByPause, !pauseTimer.isPending {
            pauseTimer.schedule(after: timing.hideAfterPause) { [weak self] in
                guard let self, !self.isPlaying, self.spotifyRunning else { return }
                self.hiddenByPause = true
            }
        }
    }

    private func hideSettingChanged(_ enabled: Bool) {
        pauseTimer.cancel()
        if !enabled {
            if hiddenByPause { hiddenByPause = false }
        } else if spotifyRunning, !isPlaying, !hiddenByPause {
            pauseTimer.schedule(after: timing.hideAfterPause) { [weak self] in
                guard let self, !self.isPlaying, self.spotifyRunning else { return }
                self.hiddenByPause = true
            }
        }
    }

    private func beginPeek() {
        guard prefs.showPeek else { return }
        if !peekActive { peekActive = true }
        peekTimer.schedule(after: timing.peek) { [weak self] in self?.endPeek() }
    }

    private func endPeek() {
        peekTimer.cancel()
        if peekActive { peekActive = false }
    }

    // MARK: Artwork

    private func beginArtworkGrace() {
        guard let id = track?.id else {
            artworkGrace.cancel()
            artwork = nil
            artworkKey = "none"
            accent = Self.defaultAccent
            return
        }
        // The old cover stays for a moment while the new one loads, then gives way to a placeholder.
        artworkGrace.schedule(after: timing.artworkGrace) { [weak self] in
            guard let self, self.track?.id == id, self.artworkKey != id else { return }
            self.setArtwork(nil, trackID: id)
        }
    }

    private func loadArtwork(trackID: String, url: URL?) {
        guard trackID == track?.id else { return }
        guard let url else {
            setArtwork(nil, trackID: trackID)
            return
        }
        artworkLoader.load(url) { [weak self] artwork in
            self?.setArtwork(artwork, trackID: trackID)
        }
    }

    private func setArtwork(_ value: Artwork?, trackID: String) {
        guard trackID == track?.id else { return }
        artworkGrace.cancel()
        let key = value == nil ? "placeholder:" + trackID : trackID
        guard key != artworkKey else { return }
        artwork = value?.image
        accent = value?.accent ?? ArtworkLoader.neutralAccent
        artworkKey = key
    }

    // MARK: Helpers

    private func canControl() -> Bool {
        guard permission == .denied else { return true }
        showNote(tr("Нет доступа к Spotify, открой настройки", "No access to Spotify, open Settings"), tone: .neutral)
        backend?.recheckPermission()
        onPermissionProblem?()
        return false
    }

    private func showNote(_ text: String, tone: PlayerNote.Tone) {
        noteSerial += 1
        note = PlayerNote(text: text, tone: tone, serial: noteSerial)
        noteTimer.schedule(after: timing.noteDuration) { [weak self] in self?.note = nil }
    }

    /// Asks Spotify for the real state a moment after a command, in case no notification confirmed it.
    private func scheduleVerify(after delay: TimeInterval) {
        verifyTimer.schedule(after: delay) { [weak self] in
            guard let self, self.spotifyRunning else { return }
            self.backend?.refresh()
        }
    }

    private func updateTimers() {
        clockTimer?.invalidate()
        clockTimer = nil
        let open = expandedIslands > 0 && spotifyRunning
        if open, isPlaying, !isScrubbing, let track {
            let position = currentPosition()
            if position < track.duration {
                let untilNextSecond = (1 - (position - position.rounded(.down))) / max(0.25, anchor.rate)
                let timer = Timer(timeInterval: max(0.05, untilNextSecond) + 0.01, repeats: false) { [weak self] _ in
                    guard let self else { return }
                    if !self.isScrubbing { self.clock = self.currentPosition() }
                    self.updateTimers()
                }
                timer.tolerance = 0.03
                RunLoop.main.add(timer, forMode: .common)
                clockTimer = timer
            }
        }
        if open {
            if resyncTimer == nil {
                let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.backend?.refresh() }
                timer.tolerance = 2
                RunLoop.main.add(timer, forMode: .common)
                resyncTimer = timer
            }
        } else {
            resyncTimer?.invalidate()
            resyncTimer = nil
        }
    }

    private func cancelTimers() {
        [peekTimer, pauseTimer, noteTimer, verifyTimer, artworkGrace, likeFetch, likeHold, volumeSender].forEach { $0.cancel() }
        volumeDirty = false
        clockTimer?.invalidate()
        clockTimer = nil
        resyncTimer?.invalidate()
        resyncTimer = nil
    }

    private func resetPlayback() {
        track = nil
        isPlaying = false
        anchor = PositionAnchor()
        clock = 0
        isScrubbing = false
        volumeScrubbing = false
        volumeKnown = false
        sentVolume = -1
        artwork = nil
        artworkKey = "none"
        accent = Self.defaultAccent
        likeStatus = .unknown
        likeShown = false
        note = nil
        peekActive = false
        hiddenByPause = false
        pendingDirection = nil
        confirmed = nil
        episodeRate = nil
        rateBaseline = nil
    }
}
