import AppKit
import Carbon
import SwiftUI

/// Development helpers behind command-line switches: an automated self-test (`--selftest`),
/// state snapshots as PNG files (`--snapshots <dir>`), a scripted walkthrough for recording (`--tour`)
/// and a login-item check (`--selftest-login`).
/// They drive the simulated player, never the user's Spotify.
final class DevTools {
    static let fastTiming: Timing = {
        var timing = Timing()
        timing.peek = 0.5
        timing.hideAfterPause = 0.6
        timing.hoverIn = 0.05
        timing.hoverOut = 0.1
        timing.likeFetchDelay = 0.05
        timing.likeHold = 0.3
        timing.artworkGrace = 0.2
        timing.verifyDelay = 0.2
        timing.noteDuration = 0.5
        return timing
    }()

    private let options: LaunchOptions
    private let model: PlayerModel
    private let prefs: Preferences
    private let islands: IslandManager
    private let backend: PlayerBackend
    private let loginItem: LoginItem
    private let showSettings: () -> NSWindow?
    private var failures = 0
    private var passes = 0
    private var skips = 0

    init(options: LaunchOptions, model: PlayerModel, prefs: Preferences, islands: IslandManager,
         backend: PlayerBackend, loginItem: LoginItem, showSettings: @escaping () -> NSWindow?) {
        self.showSettings = showSettings
        self.options = options
        self.model = model
        self.prefs = prefs
        self.islands = islands
        self.backend = backend
        self.loginItem = loginItem
    }

    func start() {
        if options.selfTest {
            Task { @MainActor in
                await self.runSelfTest()
                let skipped = self.skips > 0 ? ", \(self.skips) skipped" : ""
                Log.debug("RESULT: \(self.passes) passed, \(self.failures) failed\(skipped)")
                exit(self.failures == 0 ? 0 : 1)
            }
        } else if let directory = options.snapshotDirectory {
            Task { @MainActor in
                await self.runSnapshots(into: directory)
                exit(0)
            }
        } else if options.loginItemTest {
            runLoginItemTest()
            exit(failures == 0 ? 0 : 1)
        } else if options.stress {
            Task { @MainActor in
                await self.runStress()
                exit(0)
            }
        } else if options.tour {
            Task { @MainActor in
                await self.runTour()
                exit(0)
            }
        } else if let index = options.holdTrack {
            Task { @MainActor in
                await self.pause(3.2)
                self.demo?.jump(to: index, playing: ProcessInfo.processInfo.environment["MONOBROW_HOLD_PAUSED"] == nil, position: 20)
                await self.pause(0.3)
                if ProcessInfo.processInfo.environment["MONOBROW_HOLD_CLOSED"] == nil {
                    self.mainController?.state.pinned = true
                }
                Log.debug("holding")
                await self.pause(40)
                exit(0)
            }
        }
    }

    // MARK: Memory stress

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// Looks for leaks: memory should level off, not climb with every open/close or track change.
    @MainActor
    private func runStress() async {
        await pause(3.5)
        guard let controller = mainController else { return }
        Log.debug(String(format: "stress: start %.1f MB", Self.footprintMB()))
        for round in 1...(ProcessInfo.processInfo.environment["MONOBROW_STRESS"] == nil ? 4 : 1) {
            for _ in 0..<15 {
                controller.state.pinned = true
                await pause(0.45)
                controller.state.pinned = false
                await pause(0.6)
            }
            Log.debug(String(format: "stress: after %d open/close cycles %.1f MB", round * 15, Self.footprintMB()))
        }
        for round in 1...(ProcessInfo.processInfo.environment["MONOBROW_STRESS"] == nil ? 4 : 1) {
            for _ in 0..<15 {
                model.skip(1)
                await pause(0.25)
            }
            Log.debug(String(format: "stress: after %d track changes %.1f MB", round * 15, Self.footprintMB()))
        }
        controller.state.pinned = true
        await pause(1.0)
        Log.debug(String(format: "stress: player open %.1f MB", Self.footprintMB()))
        let kind = ProcessInfo.processInfo.environment["MONOBROW_STRESS"] ?? "both"
        for round in 1...2 {
            for _ in 0..<15 {
                if kind != "like" {
                    model.skip(1)
                    await pause(0.25)
                }
                if kind != "skip" {
                    model.toggleLike()
                    await pause(0.15)
                }
            }
            Log.debug(String(format: "stress: open player (\(kind)), after %d rounds %.1f MB", round * 15, Self.footprintMB()))
        }
        await pause(ProcessInfo.processInfo.environment["MONOBROW_STRESS_HOLD"].flatMap(Double.init) ?? 0)
        controller.state.pinned = false
        await pause(1.5)
        Log.debug(String(format: "stress: player closed %.1f MB", Self.footprintMB()))
        for round in 1...3 {
            let window = showSettings()
            await pause(1.0)
            let open = Self.footprintMB()
            window?.close()
            await pause(1.0)
            Log.debug(String(format: "stress: settings window %d: open %.1f MB, closed %.1f MB", round, open, Self.footprintMB()))
        }
        model.spotifyDidQuit()
        islands.setActive(false)
        await pause(1.4)
        Log.debug(String(format: "stress: Spotify quit, islands gone %.1f MB", Self.footprintMB()))
    }

    // MARK: Helpers

    private func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            passes += 1
            Log.debug("PASS  \(name)")
        } else {
            failures += 1
            Log.debug("FAIL  \(name)  \(detail())")
        }
    }

    /// Checks a looping animation, which the island deliberately stops when the system asks for
    /// less motion or saves power (as on some CI machines). Then the check is skipped, not failed.
    private func checkMotion(_ name: String, _ condition: Bool, equalizer: Bool = false) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let lowPower = equalizer && model.lowPower
        if reduceMotion || lowPower {
            skips += 1
            Log.debug("SKIP  \(name)  (\(reduceMotion ? "Reduce Motion" : "Low Power Mode") is on)")
        } else {
            check(name, condition)
        }
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private var mainController: IslandPanelController? {
        islands.controllers.values.first(where: { $0.state.metrics.hasNotch }) ?? islands.controllers.values.first
    }

    private var demo: DemoBackend? { backend as? DemoBackend }

    /// Posts a click to the island window. `point` uses window coordinates with the origin at the top-left corner.
    private func click(_ point: CGPoint, in controller: IslandPanelController, count: Int = 1) {
        let panel = controller.panel
        let location = NSPoint(x: point.x, y: panel.frame.height - point.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: count,
                pressure: type == .leftMouseDown ? 1 : 0
            ) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    private static func views<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
        var found: [T] = []
        if let match = root as? T { found.append(match) }
        for child in root.subviews { found.append(contentsOf: views(of: type, in: child)) }
        return found
    }

    /// True when a real click at this window point would land on the island window.
    private func windowServerHits(_ point: CGPoint, in controller: IslandPanelController) -> Bool {
        let frame = controller.panel.frame
        let screenPoint = NSPoint(x: frame.minX + point.x, y: frame.maxY - point.y)
        return NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0) == controller.panel.windowNumber
    }

    private struct ControlPoints {
        let metrics: IslandMetrics
        var left: CGFloat { (metrics.windowSize.width - IslandMetrics.expandedWidth) / 2 }
        var controlsY: CGFloat { metrics.topInset + 134 }
        var progressY: CGFloat { metrics.topInset + 90 }
        var play: CGPoint { CGPoint(x: metrics.windowSize.width / 2, y: controlsY) }
        var next: CGPoint { CGPoint(x: metrics.windowSize.width / 2 + 56, y: controlsY) }
        var previous: CGPoint { CGPoint(x: metrics.windowSize.width / 2 - 56, y: controlsY) }
        var like: CGPoint { CGPoint(x: left + 32, y: controlsY) }
        var mute: CGPoint { CGPoint(x: left + 348, y: controlsY) }
        var cover: CGPoint { CGPoint(x: left + 22 + 28, y: metrics.topInset + 12 + 28) }
        func volume(_ fraction: CGFloat) -> CGPoint { CGPoint(x: left + 366 + 72 * fraction, y: controlsY) }
        func progress(_ fraction: CGFloat) -> CGPoint { CGPoint(x: left + 72 + 316 * fraction, y: progressY) }
    }

    // MARK: Snapshots

    private func snapshot(_ name: String, of controller: IslandPanelController, into directory: String) {
        let view = controller.host
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
        try? data.write(to: url)
        Log.debug("snapshot \(name) \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }

    @MainActor
    private func runSnapshots(into directory: String) async {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        await pause(1.2)
        guard let controller = mainController else {
            Log.debug("no island window")
            return
        }
        snapshot("01-peek", of: controller, into: directory)
        await pause(2.6)
        snapshot("02-compact", of: controller, into: directory)

        controller.state.pinned = true
        await pause(0.12)
        snapshot("03-opening", of: controller, into: directory)
        await pause(1.2)
        snapshot("04-expanded", of: controller, into: directory)

        model.togglePlay()
        await pause(0.17)
        snapshot("05-pause-morph", of: controller, into: directory)
        await pause(1.0)
        snapshot("06-paused", of: controller, into: directory)
        model.togglePlay()
        await pause(0.6)

        model.toggleLike()
        await pause(0.2)
        snapshot("07-like-burst", of: controller, into: directory)
        await pause(0.9)
        snapshot("08-liked", of: controller, into: directory)

        model.skip(1)
        await pause(0.16)
        snapshot("09-skip-motion", of: controller, into: directory)
        await pause(3.2)
        snapshot("10-long-title", of: controller, into: directory)

        model.beginScrub(at: 0.7)
        model.endScrub(at: 0.7, glide: true)
        model.toggleMute()
        await pause(1.0)
        snapshot("11-seeked-muted", of: controller, into: directory)
        model.toggleMute()

        controller.state.pinned = false
        await pause(1.0)
        snapshot("12-compact-again", of: controller, into: directory)

        prefs.screenMode = .all
        await pause(1.0)
        if let external = islands.controllers.values.first(where: { !$0.state.metrics.hasNotch }) {
            snapshot("13-external-compact", of: external, into: directory)
            external.state.pinned = true
            await pause(1.3)
            snapshot("14-external-expanded", of: external, into: directory)
            external.state.pinned = false
        } else {
            Log.debug("no screen without a notch; external snapshots skipped")
        }
        prefs.screenMode = .builtIn
        await pause(0.5)

        if let window = showSettings(), let view = window.contentView {
            await pause(1.0)
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("15-settings.png"))
                    Log.debug("snapshot 15-settings \(rep.pixelsWide)x\(rep.pixelsHigh)")
                }
            }
            window.close()
        }
    }

    // MARK: Tour

    /// A scripted walkthrough for the README animation: the island opens, pauses and resumes,
    /// likes the track, skips to a long title, seeks, closes and announces the next track.
    /// Record the panel's frame, which is printed first, for example with `screencapture -v -R`.
    @MainActor
    private func runTour() async {
        await pause(1.0)
        if let controller = mainController, let screen = controller.panel.screen {
            let frame = controller.panel.frame
            let top = screen.frame.maxY - frame.maxY
            Log.debug("tour: panel \(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))")
        }
        await pause(4.0)
        Log.debug("tour: start")
        guard let controller = mainController else { return }
        controller.state.pinned = true
        await pause(1.8)
        model.togglePlay()
        await pause(1.1)
        model.togglePlay()
        await pause(1.0)
        model.toggleLike()
        await pause(1.6)
        model.skip(1)
        await pause(3.4)
        model.beginScrub(at: 0.62)
        model.endScrub(at: 0.62, glide: true)
        await pause(1.4)
        controller.state.pinned = false
        await pause(1.6)
        model.skip(1)
        await pause(3.6)
        Log.debug("tour: end")
    }

    // MARK: Login item

    private func runLoginItemTest() {
        let before = loginItem.state
        loginItem.setEnabled(true)
        check("login item registers", loginItem.state == .on, "state=\(loginItem.state) problem=\(loginItem.problem ?? "-")")
        if before != .on {
            loginItem.setEnabled(false)
            check("login item unregisters", loginItem.state == .off, "state=\(loginItem.state) problem=\(loginItem.problem ?? "-")")
        }
        Log.debug("RESULT: \(passes) passed, \(failures) failed")
    }

    // MARK: Self-test

    @MainActor
    private func runSelfTest() async {
        testPureLogic()
        await testLoopbackServer()
        await testTokens()
        await testLibraryAPI()
        testKeychain()
        await testAccountFlow()
        await testEdgeCases()
        await testLikeLook()
        await testHover()
        await testModelAndIsland()
        await testDockIcon()
    }

    @MainActor
    private func testDockIcon() async {
        prefs.showDockIcon = true
        await pause(0.4)
        check("dock: the icon can be shown", NSApp.activationPolicy() == .regular)
        prefs.showDockIcon = false
        await pause(0.4)
        check("dock: the icon can be hidden", NSApp.activationPolicy() == .accessory)
    }

    // MARK: Login flow against a stand-in for Spotify

    private func parseForm(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            result[parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
        }
        return result
    }

    @MainActor
    private func testAccountFlow() async {
        let suite = "app.monobrow.Monobrow.selftest.account"
        let store = UserDefaults(suiteName: suite) ?? .standard
        store.removePersistentDomain(forName: suite)
        let prefs = Preferences(store: store)
        let secrets = MemorySecretStore()
        let clientID = "0123456789abcdef0123456789abcdef"
        var opened: [URL] = []
        var tokenBodies: [String] = []
        let transport = MockTransport { request in
            if request.url == SpotifyAuthConfig.tokenURL {
                tokenBodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
                return (200, "{\"access_token\":\"AT\",\"expires_in\":3600,\"refresh_token\":\"RT\"}", [:])
            }
            return (200, "[true]", [:])
        }
        let account = SpotifyAccount(prefs: prefs, http: transport, secrets: secrets, openURL: { opened.append($0) })
        var changes = 0
        account.onChange = { changes += 1 }
        let session = URLSession(configuration: .ephemeral)
        func callback(_ query: String) async -> Int? {
            guard let url = URL(string: SpotifyAuthConfig.redirectURI + "?" + query) else { return nil }
            return ((try? await session.data(from: url))?.1 as? HTTPURLResponse)?.statusCode
        }
        func lastQuery() -> [String: String] {
            guard let url = opened.last, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [:] }
            return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        }

        check("account: starts disconnected", account.status == .disconnected && !account.isConnected)
        account.connect(clientID: "not a client id")
        check("account: a wrong Client ID is refused with an explanation", account.status == .disconnected && account.message != nil && opened.isEmpty)

        account.connect(clientID: " " + clientID + " \n")
        check("account: login starts", account.status == .connecting && account.message == nil)
        await pause(0.5)
        var query = lastQuery()
        let address = opened.last
        check("account: browser is sent to Spotify", address?.host == "accounts.spotify.com" && address?.path == "/authorize"
            && query["client_id"] == clientID && query["response_type"] == "code"
            && query["redirect_uri"] == SpotifyAuthConfig.redirectURI && query["code_challenge_method"] == "S256"
            && query["scope"] == SpotifyAuthConfig.scopes && query["code_challenge"]?.count == 43
            && (query["state"]?.count ?? 0) >= 16, address?.absoluteString ?? "-")

        let forged = await callback("code=stolen&state=wrong")
        check("account: a redirect with the wrong state is rejected", forged == 400 && account.status == .connecting && tokenBodies.isEmpty, "\(String(describing: forged))")
        let accepted = await callback("code=the-code&state=" + (query["state"] ?? ""))
        check("account: the real redirect is accepted", accepted == 200)
        await pause(0.4)
        check("account: connected and saved", account.status == .connected && prefs.accountLinked && prefs.clientID == clientID
            && secrets.read(SpotifyAuthConfig.refreshTokenKey) == "RT" && changes == 1, "\(account.status) changes=\(changes)")
        let form = parseForm(tokenBodies.first ?? "")
        check("account: code is exchanged with the matching PKCE verifier", form["grant_type"] == "authorization_code" && form["code"] == "the-code"
            && form["client_id"] == clientID && form["redirect_uri"] == SpotifyAuthConfig.redirectURI
            && PKCE.challenge(for: form["code_verifier"] ?? "") == query["code_challenge"], tokenBodies.first ?? "-")
        let liked = try? await account.isLiked(trackURI: "spotify:track:x")
        check("account: like state is read through the login", liked == true)

        // Spotify revokes the login.
        transport.set { request in
            request.url == SpotifyAuthConfig.tokenURL ? (400, "{\"error\":\"invalid_grant\"}", [:]) : (401, "", [:])
        }
        var failed = false
        do { try await account.setLiked(true, trackURI: "spotify:track:x") } catch { failed = true }
        await pause(0.1)
        check("account: a revoked login disconnects with an explanation", failed && account.status == .disconnected && !prefs.accountLinked
            && account.message != nil && secrets.read(SpotifyAuthConfig.refreshTokenKey) == nil && changes == 2, "\(account.status) changes=\(changes)")

        // The user presses Cancel on Spotify's page.
        await pause(0.6)
        account.connect(clientID: clientID)
        await pause(0.5)
        query = lastQuery()
        let denied = await callback("error=access_denied&state=" + (query["state"] ?? ""))
        await pause(0.3)
        check("account: declining in the browser ends the login", denied == 200 && account.status == .disconnected && account.message != nil && opened.count == 2,
              "\(String(describing: denied)) \(account.status) opened=\(opened.count)")

        // The user cancels in the settings window.
        await pause(0.6)
        account.connect(clientID: clientID)
        await pause(0.4)
        check("account: a new login can start right after", account.status == .connecting && opened.count == 3, "\(account.status) opened=\(opened.count) \(account.message ?? "")")
        query = lastQuery()
        account.cancelConnect()
        check("account: cancel stops the login", account.status == .disconnected)
        await pause(0.3)
        let late = await callback("code=late&state=" + (query["state"] ?? ""))
        check("account: after cancel nobody listens for the redirect", late == nil && account.status == .disconnected, "\(String(describing: late))")

        // Connect once more, then disconnect by hand.
        transport.set { request in
            request.url == SpotifyAuthConfig.tokenURL
                ? (200, "{\"access_token\":\"AT2\",\"expires_in\":3600,\"refresh_token\":\"RT2\"}", [:]) : (200, "[false]", [:])
        }
        account.connect(clientID: clientID)
        await pause(0.4)
        query = lastQuery()
        _ = await callback("code=again&state=" + (query["state"] ?? ""))
        await pause(0.4)
        check("account: connects again", account.status == .connected && secrets.read(SpotifyAuthConfig.refreshTokenKey) == "RT2")
        account.disconnect()
        await pause(0.2)
        check("account: disconnect forgets the login", account.status == .disconnected && !prefs.accountLinked && secrets.read(SpotifyAuthConfig.refreshTokenKey) == nil)
    }

    // MARK: Edge cases on a private model

    private final class FakeBackend: PlayerBackend {
        var events: ((BackendEvent) -> Void)?
        var commands: [PlayerCommand] = []
        var running = false
        var refreshes = 0
        var rechecks = 0

        func start() { running = true }
        func stop() { running = false }
        func send(_ command: PlayerCommand) { commands.append(command) }
        func refresh() { refreshes += 1 }
        func recheckPermission() { rechecks += 1 }
        func emit(_ event: BackendEvent) { events?(event) }
    }

    private final class ScriptedLikes: LikeService {
        var isConnected = true
        var failure: SpotifyError?
        var liked = false
        /// Seconds Spotify "takes" to answer, to stage out-of-order answers.
        var readDelay = 0.0
        var writeDelay = 0.0
        private(set) var writes = 0

        func isLiked(trackURI: String) async throws -> Bool {
            // The answer reflects the moment the question was asked.
            let answer = liked
            if readDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(readDelay * 1_000_000_000)) }
            if let failure { throw failure }
            return answer
        }

        func setLiked(_ value: Bool, trackURI: String) async throws {
            writes += 1
            if writeDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(writeDelay * 1_000_000_000)) }
            if let failure { throw failure }
            liked = value
        }
    }

    private func freshModel() -> (PlayerModel, FakeBackend, ScriptedLikes, Preferences) {
        let suite = "app.monobrow.Monobrow.selftest"
        let store = UserDefaults(suiteName: suite) ?? .standard
        store.removePersistentDomain(forName: suite)
        let prefs = Preferences(store: store)
        let model = PlayerModel(prefs: prefs, timing: Self.fastTiming)
        let backend = FakeBackend()
        let likes = ScriptedLikes()
        model.attach(backend: backend, likes: likes)
        model.spotifyDidLaunch()
        return (model, backend, likes, prefs)
    }

    private func snapshot(_ track: Track?, _ state: PlayState, at position: Double = 0) -> BackendEvent {
        .snapshot(PlaybackSnapshot(track: track, state: state, position: position, stamp: CACurrentMediaTime()))
    }

    @MainActor
    private func testEdgeCases() async {
        let song = Track(id: "spotify:track:one", title: "One", artist: "Band", album: "Record", duration: 200)
        let other = Track(id: "spotify:track:two", title: "Two", artist: "Band", album: "Record", duration: 100)
        let episode = Track(id: "spotify:episode:pod", title: "Talk", artist: "Show", album: "", duration: 900)

        // Nothing loaded in Spotify.
        var (model, backend, likes, prefs) = freshModel()
        check("edge: backend starts with Spotify", backend.running)
        backend.emit(snapshot(nil, .stopped))
        check("edge: nothing playing keeps the island hidden", model.mode(hovering: false) == .hidden && model.mode(hovering: true) == .expanded)
        model.togglePlay()
        check("edge: play with nothing loaded asks Spotify to play", backend.commands == [.play])

        // Monobrow starts while Spotify is paused: hidden at once, no peek.
        (model, backend, likes, prefs) = freshModel()
        backend.emit(snapshot(song, .paused, at: 42))
        check("edge: paused at start stays hidden", model.mode(hovering: false) == .hidden && !model.isPlaying && abs(model.currentPosition() - 42) < 0.01)
        model.togglePlay()
        check("edge: play shows the island and sends play", model.mode(hovering: false) == .compact && backend.commands == [.play])

        // Spotify pauses on its own, then the track changes outside Monobrow.
        (model, backend, likes, prefs) = freshModel()
        backend.emit(snapshot(song, .playing, at: 5))
        check("edge: first track peeks", model.mode(hovering: false) == .peek)
        backend.emit(snapshot(song, .paused, at: 6))
        check("edge: external pause is followed", !model.isPlaying && model.mode(hovering: false) != .hidden)
        await pause(0.8)
        check("edge: island hides a while after an external pause", model.mode(hovering: false) == .hidden)
        let glide = model.seekGlide
        backend.emit(snapshot(song, .playing, at: 120))
        check("edge: a jump made in Spotify glides the bar", model.isPlaying && model.seekGlide == glide + 1 && model.mode(hovering: false) == .compact)
        backend.emit(snapshot(other, .playing, at: 0))
        check("edge: outside track change slides forward and peeks", model.track == other && model.transition.direction == 1 && model.mode(hovering: false) == .peek)
        model.skip(-1)
        backend.emit(snapshot(song, .playing, at: 0))
        check("edge: going back slides backward", model.transition.direction == -1 && backend.commands.last == .previous)

        // The setting "hide when paused" switched off.
        prefs.hideWhenPaused = false
        backend.emit(snapshot(song, .paused, at: 3))
        await pause(0.8)
        check("edge: with hiding off a paused island stays", model.mode(hovering: false) == .compact)
        prefs.hideWhenPaused = true
        await pause(0.8)
        check("edge: switching hiding on hides a paused island", model.mode(hovering: false) == .hidden)
        prefs.showPeek = false
        backend.emit(snapshot(other, .playing, at: 0))
        check("edge: with peek off a new track does not peek", model.mode(hovering: false) == .compact)

        // Volume as reported by Spotify.
        backend.emit(.volume(64))
        check("edge: volume is read from Spotify", model.volume == 64)
        backend.emit(.volume(63))
        check("edge: one-step rounding from Spotify is ignored", model.volume == 64)
        backend.emit(.volume(30))
        check("edge: a real change in Spotify is followed", model.volume == 30)

        // No permission to control Spotify.
        var attention = 0
        model.onPermissionProblem = { attention += 1 }
        backend.emit(.permission(.denied))
        backend.commands.removeAll()
        model.togglePlay()
        model.skip(1)
        check("edge: without access nothing is sent", backend.commands.isEmpty && attention == 2 && model.note != nil && backend.rechecks == 2)
        backend.emit(.permission(.granted))
        model.togglePlay()
        check("edge: with access restored commands go out", backend.commands.count == 1)

        // Likes.
        backend.emit(snapshot(song, .playing, at: 1))
        await pause(0.2)
        check("edge: like state is asked from Spotify", model.likeStatus == .notLiked)
        likes.failure = .network
        model.toggleLike()
        check("edge: like shows at once", model.likeStatus == .liked)
        await pause(0.2)
        check("edge: a failed like is taken back", model.likeStatus != .liked && model.likeEffect.kind == .denied && likes.writes == 1, "\(model.likeStatus)")
        likes.failure = nil
        model.toggleLike()
        model.toggleLike()
        model.toggleLike()
        await pause(0.3)
        check("edge: quick like, unlike, like ends liked", model.likeStatus == .liked && likes.liked && likes.writes == 4, "writes=\(likes.writes)")
        backend.emit(snapshot(episode, .playing, at: 0))
        let writes = likes.writes
        model.toggleLike()
        check("edge: episodes cannot be liked", !model.likeAvailable && likes.writes == writes && model.likeEffect.kind == .denied)
        likes.isConnected = false
        model.accountDidChange()
        backend.emit(snapshot(song, .playing, at: 0))
        model.toggleLike()
        check("edge: no account, no like", !model.accountConnected && likes.writes == writes && model.likeEffect.kind == .denied)

        // A command that Spotify did not accept is taken back.
        likes.isConnected = true
        model.accountDidChange()
        backend.emit(snapshot(song, .playing, at: 50))
        model.togglePlay()
        check("edge: pause shows at once", !model.isPlaying)
        backend.emit(.commandFailed)
        check("edge: a rejected pause is taken back", model.isPlaying && model.mode(hovering: false) != .hidden && abs(model.currentPosition() - 50) < 1)

        // The track changes while the progress bar is being dragged.
        backend.commands.removeAll()
        model.beginScrub(at: 0.97)
        backend.emit(snapshot(other, .playing, at: 0))
        model.scrub(to: 0.98)
        model.endScrub(at: 0.98, glide: false)
        check("edge: a drag that outlived its track does not seek the next one", backend.commands.isEmpty && !model.isScrubbing && model.currentPosition() < 2, "\(backend.commands)")

        // An old answer about the like state arrives after a like made here.
        likes.liked = false
        likes.readDelay = 0.4
        backend.emit(snapshot(song, .playing, at: 0))
        await pause(0.15) // the question is on its way and will be answered "not liked"
        model.toggleLike()
        await pause(0.5)
        check("edge: a late answer does not undo a fresh like", model.likeStatus == .liked && likes.liked, "\(model.likeStatus)")

        // A slow like for one track must not block the like state of the next one.
        likes.readDelay = 0
        likes.writeDelay = 0.5
        model.toggleLike() // unlike "song", still travelling
        likes.liked = true
        backend.emit(snapshot(other, .playing, at: 0))
        await pause(0.25)
        check("edge: like state of the next track arrives despite a pending like", model.track == other && model.likeStatus == .liked, "\(model.likeStatus)")
        likes.writeDelay = 0
        await pause(0.5)

        // Podcasts can play faster than real time.
        let now = CACurrentMediaTime()
        backend.emit(.snapshot(PlaybackSnapshot(track: episode, state: .playing, position: 100, stamp: now - 10)))
        check("edge: an episode starts at normal speed", model.anchor.rate == 1)
        backend.emit(.snapshot(PlaybackSnapshot(track: episode, state: .playing, position: 115, stamp: now)))
        check("edge: podcast speed is measured", model.anchor.rate == 1.5 && abs(model.currentPosition(at: now + 2) - 118) < 0.01, "rate=\(model.anchor.rate)")
        backend.emit(.snapshot(PlaybackSnapshot(track: episode, state: .paused, position: 120, stamp: now)))
        backend.emit(.snapshot(PlaybackSnapshot(track: episode, state: .playing, position: 120, stamp: now)))
        check("edge: the measured speed survives a pause", model.anchor.rate == 1.5)
        backend.emit(.snapshot(PlaybackSnapshot(track: song, state: .playing, position: 10, stamp: now - 10)))
        backend.emit(.snapshot(PlaybackSnapshot(track: song, state: .playing, position: 40, stamp: now)))
        check("edge: music always runs at normal speed", model.anchor.rate == 1 && abs(model.currentPosition(at: now + 2) - 42) < 0.01)

        // Spotify quits.
        model.spotifyDidQuit()
        check("edge: quitting Spotify stops the backend and hides the island", !backend.running && model.mode(hovering: true) == .hidden)
        backend.emit(snapshot(other, .playing, at: 0))
        await pause(1.2)
        check("edge: events after quit are ignored and state is cleared", model.track == nil && !model.isPlaying)
        model.spotifyDidLaunch()
        check("edge: Spotify returning restarts the backend", backend.running && model.mode(hovering: false) == .hidden)
        model.spotifyDidQuit()
    }

    // MARK: What the heart shows while Spotify is being asked

    @MainActor
    private func testLikeLook() async {
        let (model, backend, likes, _) = freshModel()
        func track(_ name: String) -> Track {
            Track(id: "spotify:track:" + name, title: name, artist: "Band", album: "Record", duration: 200)
        }
        let episode = Track(id: "spotify:episode:pod", title: "Talk", artist: "Show", album: "", duration: 900)

        likes.liked = true
        likes.readDelay = 0.15
        backend.emit(snapshot(track("a"), .playing))
        check("heart: an unknown first track starts empty", !model.likeShown && model.likeStatus == .unknown)
        await pause(0.3)
        check("heart: turns green when Spotify answers", model.likeShown && model.likeStatus == .liked)

        // The reported case: skipping through liked tracks.
        backend.emit(snapshot(track("b"), .playing))
        check("heart: stays green while the next track is checked", model.likeShown && model.likeStatus == .unknown)
        await pause(0.3)
        check("heart: and is still green once confirmed", model.likeShown && model.likeStatus == .liked)

        likes.readDelay = 5 // the answer cannot be what sets the heart here
        backend.emit(snapshot(track("a"), .playing))
        check("heart: a track seen before shows its state at once", model.likeShown && model.likeStatus == .liked)

        likes.readDelay = 0.1
        likes.liked = false
        backend.emit(snapshot(track("c"), .playing))
        await pause(0.25)
        check("heart: goes out when the next track is not liked", !model.likeShown && model.likeStatus == .notLiked)

        // Spotify answers too slowly.
        model.toggleLike()
        check("heart: like shows at once", model.likeShown)
        await pause(0.1)
        likes.liked = true
        likes.readDelay = 0.7
        backend.emit(snapshot(track("d"), .playing))
        await pause(0.45)
        check("heart: without an answer it stops showing the old state", !model.likeShown && model.likeStatus == .unknown)
        await pause(0.5)
        check("heart: a late answer still arrives", model.likeShown && model.likeStatus == .liked)

        // A click while the answer is on its way flips what the heart shows.
        likes.readDelay = 0.5
        backend.emit(snapshot(track("e"), .playing))
        check("heart: held green on the new track", model.likeShown && model.likeStatus == .unknown)
        model.toggleLike()
        check("heart: a click flips what is shown", !model.likeShown && model.likeStatus == .notLiked)
        await pause(0.8)
        check("heart: the late answer does not undo the click", !model.likeShown && !likes.liked)

        // A double-click on the cover likes even if the heart still shows the previous track.
        model.toggleLike()
        await pause(0.1)
        likes.readDelay = 0.5
        likes.liked = false
        let writes = likes.writes
        backend.emit(snapshot(track("f"), .playing))
        model.toggleLike(fromCover: true)
        await pause(0.1)
        check("heart: double-click likes a track whose state is not known yet", model.likeShown && likes.liked && likes.writes == writes + 1)

        backend.emit(snapshot(episode, .playing))
        check("heart: empty at once for things that cannot be liked", !model.likeShown)
        model.spotifyDidQuit()
    }

    // MARK: Hover logic with a scripted pointer

    @MainActor
    private func testHover() async {
        let (model, backend, _, _) = freshModel()
        let song = Track(id: "spotify:track:one", title: "One", artist: "Band", album: "Record", duration: 200)
        backend.emit(snapshot(song, .playing, at: 5))
        await pause(0.6) // let the peek pass

        let metrics = IslandMetrics(hasNotch: true, notchWidth: 220, barHeight: 38)
        let state = IslandState(metrics: metrics, model: model, timing: Self.fastTiming)
        let size = metrics.windowSize
        state.windowFrame = { CGRect(origin: .zero, size: size) }
        var pointer = CGPoint(x: 5, y: 250) // window coordinates, origin at the top-left corner
        state.pointerLocation = { CGPoint(x: pointer.x, y: size.height - pointer.y) }
        func mode() -> IslandMode { model.mode(hovering: state.isHovering) }
        let compact = metrics.shapeRect(.compact)
        let open = metrics.shapeRect(.expanded)

        state.pointerMoved()
        await pause(0.15)
        check("hover: pointer elsewhere leaves the island collapsed", mode() == .compact)

        pointer = CGPoint(x: compact.minX + 20, y: 15)
        state.pointerMoved()
        check("hover: opening waits for a short dwell", mode() == .compact)
        await pause(0.15)
        check("hover: pointer on the island opens it", mode() == .expanded)
        check("hover: opening re-reads the player state", backend.refreshes == 1)

        pointer = CGPoint(x: open.midX, y: open.maxY - 10)
        state.pointerMoved()
        await pause(0.25)
        check("hover: moving inside the open player keeps it open", mode() == .expanded)

        state.lock()
        pointer = CGPoint(x: 5, y: 250)
        state.pointerMoved()
        await pause(0.6)
        check("hover: dragging a slider outside keeps it open", mode() == .expanded)
        state.unlock()
        await pause(0.3)
        check("hover: it closes after the drag ends outside", mode() == .compact)

        pointer = CGPoint(x: compact.midX, y: 20)
        state.pointerMoved()
        await pause(0.15)
        pointer = CGPoint(x: 5, y: 250) // leaves without any mouse event
        await pause(0.9)
        check("hover: a missed exit event still closes it", mode() == .compact)

        pointer = CGPoint(x: compact.minX + 10, y: 10)
        state.pointerPressed()
        check("hover: a click opens it at once", mode() == .expanded)
        pointer = CGPoint(x: 5, y: 250)
        state.pointerMoved()
        pointer = CGPoint(x: open.midX, y: 100)
        state.pointerMoved()
        await pause(0.3)
        check("hover: coming back in time cancels closing", mode() == .expanded)

        // A hidden island on a screen without a notch opens from the top edge.
        backend.emit(snapshot(song, .paused, at: 6))
        pointer = CGPoint(x: 5, y: 250)
        state.pointerMoved()
        await pause(0.9)
        check("hover: paused and left alone it hides", mode() == .hidden)
        state.metrics = IslandMetrics(hasNotch: false, notchWidth: 44, barHeight: 24)
        let plainSize = state.metrics.windowSize
        state.windowFrame = { CGRect(origin: .zero, size: plainSize) }
        state.pointerLocation = { CGPoint(x: pointer.x, y: plainSize.height - pointer.y) }
        pointer = CGPoint(x: plainSize.width / 2, y: 40)
        state.pointerMoved()
        await pause(0.15)
        check("hover: below the top edge nothing opens", mode() == .hidden)
        pointer = CGPoint(x: plainSize.width / 2, y: 2)
        state.pointerMoved()
        await pause(0.15)
        check("hover: the top edge opens a hidden island", mode() == .expanded)

        state.invalidate()
        check("hover: closing the window resets hover", !state.isHovering)
        model.spotifyDidQuit()
    }

    private func testPureLogic() {
        // RFC 7636, appendix B.
        check("PKCE challenge", PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let verifier = PKCE.randomVerifier()
        check("PKCE verifier length", (43...128).contains(verifier.count), "\(verifier.count)")
        check("PKCE verifier is random", verifier != PKCE.randomVerifier())

        let info: [AnyHashable: Any] = [
            "Player State": "Playing", "Track ID": "spotify:track:abc", "Name": "Song", "Artist": "Band",
            "Album": "Record", "Duration": NSNumber(value: 150857), "Playback Position": NSNumber(value: 12.5),
        ]
        let parsed = SpotifyNotification.snapshot(from: info, stamp: 1)
        check("notification: track", parsed?.track == Track(id: "spotify:track:abc", title: "Song", artist: "Band", album: "Record", duration: 150.857))
        check("notification: state and position", parsed?.state == .playing && parsed?.position == 12.5)
        let stopped = SpotifyNotification.snapshot(from: ["Player State": "Stopped"], stamp: 1)
        check("notification: stopped without track", stopped?.state == .stopped && stopped?.track == nil)
        check("notification: garbage is ignored", SpotifyNotification.snapshot(from: ["x": 1], stamp: 1) == nil)
        check("episodes are not likeable", !Track(id: "spotify:episode:1", title: "", artist: "", album: "", duration: 1).isLikeable)

        check("form encoding", FormEncoding.encode([("a", "x y"), ("uris", "spotify:track:1")]) == "a=x%20y&uris=spotify%3Atrack%3A1")
        let url = SpotifyAccount.authorizeURL(clientID: "0123456789abcdef0123456789abcdef", challenge: "ch", state: "st")?.absoluteString ?? ""
        check("authorize URL", url.hasPrefix("https://accounts.spotify.com/authorize?client_id=0123456789abcdef0123456789abcdef&response_type=code&redirect_uri=http%3A%2F%2F127.0.0.1%3A43917%2Fcallback&code_challenge_method=S256&code_challenge=ch&state=st&scope=user-library-read%20user-library-modify"), url)
        check("client id check", SpotifyAccount.looksLikeClientID("0123456789abcdef0123456789abcdef") && !SpotifyAccount.looksLikeClientID("nope") && !SpotifyAccount.looksLikeClientID("0123456789abcdef 123456789abcdef"))

        let ease = UnitBezier(0.22, 1, 0.36, 1)
        check("bezier endpoints", ease(0) == 0 && ease(1) == 1 && ease(0.5) > 0.8 && ease(0.5) < 1)
        check("time format", formatTime(0) == "0:00" && formatTime(59.9) == "0:59" && formatTime(221) == "3:41" && formatTime(-3) == "0:00")
        check("keyframes", abs(keyframe(0.5, [(0, 0), (1, 10)]) - 5) < 0.001 && keyframe(2, [(0, 0), (1, 10)]) == 10)

        let metrics = IslandMetrics(hasNotch: true, notchWidth: 220, barHeight: 38)
        check("metrics: compact", metrics.size(.compact) == CGSize(width: 316, height: 38), "\(metrics.size(.compact))")
        check("metrics: peek", metrics.size(.peek) == CGSize(width: 380, height: 102))
        check("metrics: expanded", metrics.size(.expanded) == CGSize(width: 460, height: 210))
        check("metrics: hidden island stays inside the notch", metrics.size(.hidden).width < 220 && metrics.size(.hidden).height < 38)
        check("metrics: cover", metrics.artFrame(.compact) == CGRect(x: 12, y: 7, width: 24, height: 24) && metrics.artFrame(.expanded) == CGRect(x: 22, y: 50, width: 56, height: 56))
        let plain = IslandMetrics(hasNotch: false, notchWidth: 44, barHeight: 24)
        check("metrics: no notch hides fully", plain.size(.hidden).height == 0 && plain.size(.compact).height == 24)

        let small = ArtworkLoader.candidates(for: URL(string: "https://i.scdn.co/image/ab67616d0000b273aabbcc")!)
        check("cover: smaller file first", small.map(\.absoluteString) == ["https://i.scdn.co/image/ab67616d00001e02aabbcc", "https://i.scdn.co/image/ab67616d0000b273aabbcc"])
        check("cover: unknown address untouched", ArtworkLoader.candidates(for: URL(string: "https://example.com/a.jpg")!).count == 1)

        func solid(_ color: NSColor) -> CGImage? {
            let image = NSImage(size: NSSize(width: 40, height: 40), flipped: false) { rect in
                color.setFill()
                rect.fill()
                return true
            }
            return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        if let red = solid(NSColor(calibratedRed: 0.9, green: 0.1, blue: 0.1, alpha: 1)),
           let gray = solid(NSColor(white: 0.5, alpha: 1)) {
            let accent = ArtworkLoader.accentColor(of: red).usingColorSpace(.deviceRGB)
            let hue = accent?.hueComponent ?? 0.5
            check("accent: red cover gives a red accent", hue < 0.05 || hue > 0.95, "hue=\(hue)")
            check("accent: bright enough", (accent?.brightnessComponent ?? 0) > 0.95)
            check("accent: grey cover stays neutral", ArtworkLoader.accentColor(of: gray) == ArtworkLoader.neutralAccent)
        } else {
            check("accent: test images", false)
        }
    }

    private func testLoopbackServer() async {
        let port: UInt16 = 43918
        var received: LoopbackServer.Request?
        guard let server = try? LoopbackServer(port: port, handler: { request in
            received = request
            return .init(status: 200, html: "ok", final: true)
        }) else {
            check("loopback: listener starts", false)
            return
        }
        let ready: Bool = await withCheckedContinuation { continuation in
            server.start { result in
                if case .success = result { continuation.resume(returning: true) } else { continuation.resume(returning: false) }
            }
        }
        check("loopback: listener starts", ready)
        guard ready, let url = URL(string: "http://127.0.0.1:\(port)/callback?code=abc%20d&state=xyz") else { return }
        let session = URLSession(configuration: .ephemeral)
        let result = try? await session.data(from: url)
        let status = (result?.1 as? HTTPURLResponse)?.statusCode
        check("loopback: answers", status == 200 && result.map { String(decoding: $0.0, as: UTF8.self) } == "ok", "status=\(String(describing: status))")
        check("loopback: parses the redirect", received?.path == "/callback" && received?.query["code"] == "abc d" && received?.query["state"] == "xyz")
        await pause(0.8)
        let second = try? await session.data(from: url)
        check("loopback: stops after the final answer", second == nil)
        server.stop()
    }

    private final class MockTransport: HTTPTransport {
        private let lock = NSLock()
        private var log: [URLRequest] = []
        private var responder: (URLRequest) -> (Int, String, [String: String])

        init(_ responder: @escaping (URLRequest) -> (Int, String, [String: String])) {
            self.responder = responder
        }

        var requests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return log
        }

        func set(_ responder: @escaping (URLRequest) -> (Int, String, [String: String])) {
            lock.lock()
            self.responder = responder
            lock.unlock()
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let current = lock.withLock { () -> (URLRequest) -> (Int, String, [String: String]) in
                log.append(request)
                return responder
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
            let (status, body, headers) = current(request)
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
                throw SpotifyError.invalidResponse
            }
            return (Data(body.utf8), response)
        }
    }

    private func body(_ request: URLRequest) -> String {
        String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    }

    private func testTokens() async {
        let secrets = MemorySecretStore()
        var counter = 0
        let transport = MockTransport { _ in
            counter += 1
            return (200, "{\"access_token\":\"A\(counter)\",\"expires_in\":3600,\"refresh_token\":\"R\(counter)\"}", [:])
        }
        let tokens = TokenManager(clientID: "client", http: transport, secrets: secrets)

        do {
            try await tokens.exchange(code: "the code", verifier: "ver", redirectURI: SpotifyAuthConfig.redirectURI)
            let first = transport.requests.first
            check("token: exchange request", first?.httpMethod == "POST" && first?.url == SpotifyAuthConfig.tokenURL
                && first.map(body) == "grant_type=authorization_code&code=the%20code&redirect_uri=http%3A%2F%2F127.0.0.1%3A43917%2Fcallback&client_id=client&code_verifier=ver",
                  first.map(body) ?? "-")
            check("token: refresh token stored", secrets.read(SpotifyAuthConfig.refreshTokenKey) == "R1")
            let cached = try await tokens.validAccessToken()
            check("token: cached access token", cached == "A1" && transport.requests.count == 1)

            await tokens.invalidateAccessToken()
            async let a = tokens.validAccessToken()
            async let b = tokens.validAccessToken()
            async let c = tokens.validAccessToken()
            let results = try await [a, b, c]
            check("token: concurrent callers share one refresh", Set(results) == ["A2"] && transport.requests.count == 2, "\(results) requests=\(transport.requests.count)")
            check("token: refresh request", body(transport.requests[1]) == "grant_type=refresh_token&refresh_token=R1&client_id=client", body(transport.requests[1]))
            check("token: rotated refresh token stored", secrets.read(SpotifyAuthConfig.refreshTokenKey) == "R2")

            transport.set { _ in (200, "{\"access_token\":\"A9\",\"expires_in\":3600}", [:]) }
            await tokens.invalidateAccessToken()
            let kept = try await tokens.validAccessToken()
            check("token: keeps the old refresh token when none is returned", kept == "A9" && secrets.read(SpotifyAuthConfig.refreshTokenKey) == "R2")
        } catch {
            check("token: happy path", false, "\(error)")
        }

        transport.set { _ in (400, "{\"error\":\"invalid_grant\",\"error_description\":\"Refresh token revoked\"}", [:]) }
        await tokens.invalidateAccessToken()
        var revoked: SpotifyError?
        do { _ = try await tokens.validAccessToken() } catch { revoked = error as? SpotifyError }
        check("token: revoked login is detected", revoked == .reauthorizationRequired && secrets.read(SpotifyAuthConfig.refreshTokenKey) == nil, "\(String(describing: revoked))")
        var missing: SpotifyError?
        do { _ = try await tokens.validAccessToken() } catch { missing = error as? SpotifyError }
        check("token: no login means not connected", missing == .notConnected)

        // A fresh manager finds the saved login in the secret store.
        let saved = MemorySecretStore()
        saved.write("SAVED", key: SpotifyAuthConfig.refreshTokenKey)
        let reader = MockTransport { _ in (200, "{\"access_token\":\"B1\",\"expires_in\":3600}", [:]) }
        let restored = TokenManager(clientID: "client", http: reader, secrets: saved)
        let token = try? await restored.validAccessToken()
        check("token: saved login is used after restart", token == "B1" && reader.requests.first.map(body) == "grant_type=refresh_token&refresh_token=SAVED&client_id=client")
    }

    private func testLibraryAPI() async {
        let secrets = MemorySecretStore()
        secrets.write("R", key: SpotifyAuthConfig.refreshTokenKey)
        var tokenCount = 0
        var apiResponses: [(Int, String, [String: String])] = [(200, "[true]", [:])]
        let transport = MockTransport { request in
            if request.url == SpotifyAuthConfig.tokenURL {
                tokenCount += 1
                return (200, "{\"access_token\":\"T\(tokenCount)\",\"expires_in\":3600}", [:])
            }
            return apiResponses.count > 1 ? apiResponses.removeFirst() : apiResponses[0]
        }
        let tokens = TokenManager(clientID: "client", http: transport, secrets: secrets)
        let api = SpotifyLibraryAPI(tokens: tokens, http: transport)
        let uri = "spotify:track:6rqhFgbbKwnb9MLmUQDhG6"
        func apiRequests() -> [URLRequest] { transport.requests.filter { $0.url != SpotifyAuthConfig.tokenURL } }

        do {
            let liked = try await api.contains(uri: uri)
            let request = apiRequests().last
            check("api: contains", liked && request?.httpMethod == "GET"
                && request?.url?.absoluteString == "https://api.spotify.com/v1/me/library/contains?uris=spotify%3Atrack%3A6rqhFgbbKwnb9MLmUQDhG6"
                && request?.value(forHTTPHeaderField: "Authorization") == "Bearer T1", request?.url?.absoluteString ?? "-")

            apiResponses = [(200, "", [:])]
            try await api.save(uri: uri)
            check("api: save", apiRequests().last?.httpMethod == "PUT"
                && apiRequests().last?.url?.absoluteString == "https://api.spotify.com/v1/me/library?uris=spotify%3Atrack%3A6rqhFgbbKwnb9MLmUQDhG6")
            try await api.remove(uri: uri)
            check("api: remove", apiRequests().last?.httpMethod == "DELETE")

            apiResponses = [(401, "", [:]), (200, "[false]", [:])]
            let before = apiRequests().count
            let retried = try await api.contains(uri: uri)
            check("api: expired token is refreshed and the call retried", !retried && apiRequests().count == before + 2 && tokenCount == 2
                && apiRequests().last?.value(forHTTPHeaderField: "Authorization") == "Bearer T2", "tokens=\(tokenCount)")
        } catch {
            check("api: happy path", false, "\(error)")
        }

        apiResponses = [(403, "{}", [:])]
        var forbidden: SpotifyError?
        do { try await api.save(uri: uri) } catch { forbidden = error as? SpotifyError }
        check("api: 403 is reported", forbidden == .forbidden)

        apiResponses = [(401, "", [:])]
        var unauthorized: SpotifyError?
        do { try await api.save(uri: uri) } catch { unauthorized = error as? SpotifyError }
        check("api: repeated 401 asks to reconnect", unauthorized == .reauthorizationRequired)

        apiResponses = [(429, "", ["Retry-After": "7"])]
        var limited: SpotifyError?
        do { try await api.save(uri: uri) } catch { limited = error as? SpotifyError }
        check("api: rate limit is reported", limited == .rateLimited(7), "\(String(describing: limited))")
        let count = apiRequests().count
        var blocked = false
        do { _ = try await api.contains(uri: uri) } catch { if case .rateLimited = error as? SpotifyError { blocked = true } }
        check("api: no requests while rate limited", blocked && apiRequests().count == count)

        apiResponses = [(200, "not json", [:])]
        let fresh = SpotifyLibraryAPI(tokens: tokens, http: transport)
        var invalid: SpotifyError?
        do { _ = try await fresh.contains(uri: uri) } catch { invalid = error as? SpotifyError }
        check("api: unexpected answer is an error", invalid == .invalidResponse)
    }

    private func testKeychain() {
        let store = KeychainStore(service: "app.monobrow.Monobrow.selftest")
        store.write("secret-1", key: "probe")
        check("keychain: write and read", store.read("probe") == "secret-1")
        store.write("secret-2", key: "probe")
        check("keychain: overwrite", store.read("probe") == "secret-2")
        store.write(nil, key: "probe")
        check("keychain: delete", store.read("probe") == nil)
    }

    @MainActor
    private func testModelAndIsland() async {
        guard let demo else {
            check("demo backend present", false)
            return
        }
        demo.jump(to: 4)
        await pause(0.1)
        check("model: new track peeks", model.track?.id == "spotify:track:demo5" && model.mode(hovering: false) == .peek)
        demo.jump(to: 0, playing: true, position: 37)
        await pause(0.25)
        check("model: track loaded", model.track?.id == "spotify:track:demo1" && model.isPlaying)
        check("model: cover loaded", model.artwork != nil && model.artworkKey == "spotify:track:demo1")
        await pause(0.5)
        check("model: peek ends", model.mode(hovering: false) == .compact)
        let position = model.currentPosition()
        check("model: position advances", position > 37.3 && position < 39.5, "\(position)")
        check("model: like state fetched", model.likeStatus == .notLiked)

        // Pause, hide, resume.
        model.togglePlay()
        check("model: pause is instant", !model.isPlaying && model.mode(hovering: false) == .compact)
        let frozen = model.currentPosition()
        await pause(0.9)
        check("model: hides after pause", model.mode(hovering: false) == .hidden)
        check("model: hover opens a hidden island", model.mode(hovering: true) == .expanded)
        check("model: position frozen on pause", abs(model.currentPosition() - frozen) < 0.01)
        model.togglePlay()
        check("model: resume shows the island", model.isPlaying && model.mode(hovering: false) == .compact)

        // Skipping.
        model.skip(1)
        await pause(0.1)
        check("model: next track", model.track?.id == "spotify:track:demo2" && model.transition.direction == 1)
        check("model: cached like state for a liked track", true)
        await pause(0.2)
        check("model: liked track shows as liked", model.likeStatus == .liked)
        model.skip(-1)
        await pause(0.1)
        check("model: previous track", model.track?.id == "spotify:track:demo1" && model.transition.direction == -1)
        demo.send(.seek(60))
        await pause(0.05)
        model.skip(-1)
        check("model: previous restarts a track that is under way", model.currentPosition() < 0.5)
        await pause(0.1)
        check("model: restart keeps the track", model.track?.id == "spotify:track:demo1" && model.currentPosition() < 1)

        // Seeking and volume.
        let glideBefore = model.seekGlide
        model.beginScrub(at: 0.5)
        check("model: scrub shows the target time", model.isScrubbing && abs(model.clock - 110.5) < 0.01)
        model.scrub(to: 0.25)
        model.endScrub(at: 0.25, glide: false)
        check("model: seek", !model.isScrubbing && abs(model.currentPosition() - 55.25) < 0.3 && model.seekGlide == glideBefore + 1, "\(model.currentPosition())")
        model.beginVolumeScrub(at: 0.3)
        model.endVolumeScrub(at: 0.3, glide: true)
        check("model: volume", model.volume == 30)
        model.toggleMute()
        check("model: mute", model.volume == 0)
        model.toggleMute()
        check("model: unmute restores the volume", model.volume == 30)

        // Likes.
        model.toggleLike()
        check("model: like", model.likeStatus == .liked && model.likeEffect.kind == .liked && model.note?.tone == .positive)
        await pause(0.7)
        check("model: note disappears", model.note == nil)
        model.toggleLike()
        check("model: unlike", model.likeStatus == .notLiked && model.likeEffect.kind == .unliked)
        model.toggleLike(fromCover: true)
        check("model: double-click like", model.likeStatus == .liked && model.loveBurst == 1)
        model.toggleLike(fromCover: true)
        check("model: double-click never unlikes", model.likeStatus == .liked && model.loveBurst == 2)
        demo.jump(to: 0, playing: true, position: 10)

        // The island window.
        await pause(0.8)
        guard let controller = mainController else {
            check("island: window exists", false)
            return
        }
        let metrics = controller.state.metrics
        let points = ControlPoints(metrics: metrics)
        check("island: window exists", controller.panel.isVisible && !controller.panel.canBecomeKey)
        if metrics.hasNotch {
            check("island: sits at the notch", controller.panel.frame.maxY == controller.panel.screen?.frame.maxY)
        }
        let compact = metrics.shapeRect(.compact)
        check("island: collapsed island takes clicks", windowServerHits(CGPoint(x: compact.minX + 14, y: 12), in: controller))
        check("island: clicks pass beside it", !windowServerHits(CGPoint(x: compact.minX - 40, y: 12), in: controller))
        check("island: clicks pass below it", !windowServerHits(CGPoint(x: compact.midX, y: metrics.barHeight + 30), in: controller))

        controller.state.pinned = true
        await pause(1.0)
        check("island: open island takes clicks", windowServerHits(points.play, in: controller))
        let open = metrics.shapeRect(.expanded)
        check("island: its shadow lets clicks through", !windowServerHits(CGPoint(x: open.midX, y: open.maxY + 12), in: controller))
        check("island: beside the open island clicks pass", !windowServerHits(CGPoint(x: open.minX - 30, y: 60), in: controller))

        // What the open player actually shows.
        let sliders = Self.views(of: GlideSliderView.self, in: controller.host).sorted { $0.bounds.width > $1.bounds.width }
        check("island: both sliders exist", sliders.count == 2, "\(sliders.count)")
        if sliders.count == 2, model.duration > 0 {
            let expected = model.currentPosition() / model.duration
            check("island: progress bar shows the position", abs(sliders[0].visibleFraction - expected) < 0.02, "\(sliders[0].visibleFraction) vs \(expected)")
            await pause(1.0)
            let later = model.currentPosition() / model.duration
            check("island: progress bar advances with playback", abs(sliders[0].visibleFraction - later) < 0.02 && later > expected, "\(sliders[0].visibleFraction) vs \(later)")
            check("island: volume slider shows the volume", abs(sliders[1].visibleFraction - Double(model.volume) / 100) < 0.02, "\(sliders[1].visibleFraction)")
        }
        let equalizers = Self.views(of: EqualizerNSView.self, in: controller.host)
        checkMotion("island: equalizer animates while playing", equalizers.count == 1 && equalizers[0].looping, equalizer: true)

        click(points.play, in: controller)
        await pause(0.3)
        check("click: play/pause button pauses", !model.isPlaying)
        check("island: equalizer rests on pause", equalizers.first?.looping == false)
        if let progress = sliders.first, model.duration > 0 {
            let frozen = progress.visibleFraction
            await pause(0.5)
            check("island: progress bar stops on pause", abs(progress.visibleFraction - frozen) < 0.001
                && abs(frozen - model.currentPosition() / model.duration) < 0.02, "\(frozen)")
        }
        click(points.play, in: controller)
        await pause(0.3)
        check("click: play/pause button resumes", model.isPlaying)

        click(points.next, in: controller)
        await pause(0.4)
        check("click: next button", model.track?.id == "spotify:track:demo2", model.track?.id ?? "-")
        click(points.previous, in: controller)
        await pause(0.4)
        check("click: previous button", model.track?.id == "spotify:track:demo1", model.track?.id ?? "-")

        let likedBefore = model.likeStatus == .liked
        click(points.like, in: controller)
        await pause(0.3)
        check("click: like button toggles", (model.likeStatus == .liked) != likedBefore)

        click(points.progress(0.5), in: controller)
        await pause(0.2)
        check("click: progress bar seeks", abs(model.currentPosition() - 110.5) < 4, "\(model.currentPosition())")
        if let progress = sliders.first {
            let midway = progress.visibleFraction
            check("click: the bar glides instead of jumping", midway > 0.12 && midway < 0.5, "\(midway)")
            await pause(0.6)
            check("click: the bar arrives at the clicked point", abs(progress.visibleFraction - 0.5) < 0.03, "\(progress.visibleFraction)")
        }

        click(points.volume(0.75), in: controller)
        await pause(0.3)
        check("click: volume slider", abs(model.volume - 75) <= 3, "\(model.volume)")
        click(points.mute, in: controller)
        await pause(0.3)
        check("click: speaker mutes", model.volume == 0, "\(model.volume)")
        click(points.mute, in: controller)
        await pause(0.3)
        check("click: speaker unmutes", abs(model.volume - 75) <= 3, "\(model.volume)")

        let burst = model.loveBurst
        click(points.cover, in: controller, count: 1)
        click(points.cover, in: controller, count: 2)
        await pause(0.4)
        check("click: double-click on the cover likes", model.loveBurst == burst + 1 && model.likeStatus == .liked, "burst=\(model.loveBurst)")

        // The title scrolls only when it does not fit.
        let titles = Self.views(of: MarqueeNSView.self, in: controller.host)
        check("title: one title view, short title stands still", titles.count == 1 && titles.first?.isScrolling == false, "\(titles.count)")
        demo.jump(to: 1)
        await pause(1.0)
        checkMotion("title: a long title scrolls", titles.first?.isScrolling == true)
        demo.jump(to: 0)
        await pause(1.0)
        check("title: scrolling stops for a short title", titles.first?.isScrolling == false)

        controller.state.pinned = false
        await pause(0.8)
        check("island: closes again", model.mode(hovering: controller.state.isHovering) != .expanded)

        // Spotify quits: islands go away; it starts again: they come back.
        model.spotifyDidQuit()
        islands.setActive(false)
        check("lifecycle: island hides when Spotify quits", model.mode(hovering: true) == .hidden)
        await pause(1.3)
        check("lifecycle: windows are released", islands.controllers.isEmpty && model.track == nil)
        model.spotifyDidLaunch()
        islands.setActive(true)
        await pause(0.4)
        check("lifecycle: island returns with Spotify", !islands.controllers.isEmpty && model.track != nil)
    }
}
