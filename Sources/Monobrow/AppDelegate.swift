import AppKit
import Combine

/// Command-line switches. The app needs none of them in normal use; they exist for development.
struct LaunchOptions {
    /// Use a simulated player instead of Spotify.
    var demo = false
    var verbose = false
    var selfTest = false
    var loginItemTest = false
    /// Real Spotify: nudge the volume by one step once, to prove that property writes work.
    var probeVolume = false
    /// Behave as if Spotify were not running, to measure the app while it only waits.
    var dormant = false
    /// Open and close the player and switch tracks many times, logging memory use.
    var stress = false
    /// Keep the player open on the given demo track, to measure what an open player costs.
    var holdTrack: Int?
    /// Remove what the app keeps in the system (login item, saved Spotify login, settings) and quit.
    var uninstall = false
    var snapshotDirectory: String?
    var logFile: String?

    init(arguments: [String]) {
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--demo": demo = true
            case "--verbose": verbose = true
            case "--selftest": selfTest = true
            case "--selftest-login": loginItemTest = true
            case "--probe-volume": probeVolume = true
            case "--dormant": dormant = true
            case "--stress": stress = true
            case "--uninstall": uninstall = true
            case "--backdrop": DevFlags.backdrop = true
            case "--hold":
                index += 1
                if index < arguments.count { holdTrack = Int(arguments[index]) }
            case "--snapshots":
                index += 1
                if index < arguments.count { snapshotDirectory = arguments[index] }
            case "--log-file":
                index += 1
                if index < arguments.count { logFile = arguments[index] }
            default: break
            }
            index += 1
        }
        if snapshotDirectory != nil || selfTest || stress || holdTrack != nil { demo = true }
    }

    var isDevelopment: Bool { demo || selfTest || loginItemTest || dormant || snapshotDirectory != nil }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let showSettingsNotification = Notification.Name("app.monobrow.Monobrow.showSettings")

    private let options = LaunchOptions(arguments: CommandLine.arguments)
    private let watcher = SpotifyWatcher()
    private var prefs: Preferences!
    private var model: PlayerModel!
    private var backend: PlayerBackend!
    private var account: SpotifyAccount?
    private var loginItem: LoginItem!
    private var islands: IslandManager!
    private var settings: SettingsWindowController!
    private var devTools: DevTools?
    private var observers: [NSObjectProtocol] = []
    private var dockSubscription: AnyCancellable?

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.configure(echo: options.verbose || options.isDevelopment, filePath: options.logFile)

        if options.uninstall {
            uninstall()
            return
        }
        if !options.isDevelopment {
            if refuseToRunFromDiskImage() { return }
            if handOverToRunningCopy() { return }
        }

        // Development runs keep their own settings, so they never disturb the real ones.
        let store = options.isDevelopment ? (UserDefaults(suiteName: "app.monobrow.Monobrow.dev") ?? .standard) : .standard
        prefs = Preferences(store: store)
        loginItem = LoginItem()
        let timing = options.selfTest ? DevTools.fastTiming : Timing.standard
        model = PlayerModel(prefs: prefs, timing: timing)

        let likes: LikeService
        if options.demo {
            backend = DemoBackend()
            likes = DemoLikeService()
            // Shown in the settings window only; it keeps nothing and likes go to the simulated service.
            account = SpotifyAccount(prefs: prefs, secrets: MemorySecretStore())
        } else {
            backend = SpotifyBackend()
            let account = SpotifyAccount(prefs: prefs)
            account.onChange = { [weak self] in self?.model.accountDidChange() }
            self.account = account
            likes = account
        }
        model.attach(backend: backend, likes: likes)
        model.onPermissionProblem = { [weak self] in self?.showSettings(nil) }

        settings = SettingsWindowController { [unowned self] in
            SettingsView(
                prefs: self.prefs,
                model: self.model,
                login: self.loginItem,
                account: self.account,
                actions: SettingsActions(
                    openAutomationSettings: {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                            NSWorkspace.shared.open(url)
                        }
                    },
                    recheckPermission: { [weak self] in self?.backend.recheckPermission() },
                    quit: { NSApp.terminate(nil) }
                )
            )
        }
        islands = IslandManager(model: model, prefs: prefs, timing: timing) { [weak self] in
            self?.makeIslandMenu() ?? NSMenu()
        }

        MainMenu.install(settingsAction: #selector(showSettings(_:)), target: self)
        applyDockIcon(show: prefs.showDockIcon)
        dockSubscription = prefs.$showDockIcon.dropFirst().sink { [weak self] show in
            self?.applyDockIcon(show: show)
        }
        observeSystem()

        if options.demo {
            spotifyChanged(running: true)
        } else if !options.dormant {
            watcher.onChange = { [weak self] running in self?.spotifyChanged(running: running) }
            watcher.start()
            if watcher.isRunning { spotifyChanged(running: true) }
        }

        if options.isDevelopment {
            let tools = DevTools(options: options, model: model, prefs: prefs, islands: islands, backend: backend, loginItem: loginItem) { [weak self] in
                self?.settings.show()
                return self?.settings.currentWindow
            }
            devTools = tools
            tools.start()
        } else {
            // Starting together with Spotify is the point of the app, so it is switched on once,
            // as soon as the app runs from the Applications folder.
            if LoginItem.installedInApplications, !prefs.didSetUpLoginItem {
                prefs.didSetUpLoginItem = true
                loginItem.setEnabled(true)
            }
            if !prefs.didOnboard {
                prefs.didOnboard = true
                showSettings(nil)
            }
            if options.probeVolume { probeVolumeWrite() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(nil)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // The user may have just changed the permission in System Settings.
        if model?.permission == .denied { backend?.recheckPermission() }
        loginItem?.refresh()
    }

    // MARK: Actions

    @objc func showSettings(_ sender: Any?) {
        settings?.show()
    }

    private func spotifyChanged(running: Bool) {
        if running {
            model.spotifyDidLaunch()
            islands.setActive(true)
        } else {
            model.spotifyDidQuit()
            islands.setActive(false)
        }
    }

    private func makeIslandMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ActionMenuItem(title: "Открыть Spotify") { [weak self] in self?.openSpotify() })
        menu.addItem(ActionMenuItem(title: "Настройки…") { [weak self] in self?.showSettings(nil) })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(title: "Выйти из Monobrow") { NSApp.terminate(nil) })
        return menu
    }

    private func openSpotify() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SpotifyAppleEvents.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func applyDockIcon(show: Bool) {
        let policy: NSApplication.ActivationPolicy = show ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Changing the policy pushes the app's windows to the back; bring the settings window forward again.
        if settings?.isVisible == true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.settings.show() }
        }
    }

    private func observeSystem() {
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.model.systemDidWake()
            self?.islands.scheduleRelayout(after: 1)
        })
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showSettings(_:)), name: Self.showSettingsNotification,
            object: nil, suspensionBehavior: .deliverImmediately
        )
    }

    /// Development check against the real Spotify: writes the volume it has just read plus one
    /// step (Spotify reports one step less than it stores), then reads it back.
    private func probeVolumeWrite() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.model.spotifyRunning, self.model.permission == .granted else {
                Log.debug("volume probe skipped: no access to Spotify yet")
                return
            }
            let before = self.model.volume
            Log.debug("volume probe: read \(before), writing \(min(100, before + 1))")
            self.backend.send(.setVolume(min(100, before + 1)))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.backend.refresh()
            }
        }
    }

    /// Run before deleting the app: `--uninstall` takes it out of the login items and removes the
    /// saved Spotify login and the settings, so nothing is left behind.
    private func uninstall() {
        let login = LoginItem()
        login.setEnabled(false)
        KeychainStore(service: SpotifyAuthConfig.keychainService).write(nil, key: SpotifyAuthConfig.refreshTokenKey)
        let loginLeft = KeychainStore(service: SpotifyAuthConfig.keychainService).read(SpotifyAuthConfig.refreshTokenKey) != nil
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
            UserDefaults.standard.synchronize()
        }
        print("login item: \(login.state == .off ? "removed" : "still registered")")
        print("saved Spotify login: \(loginLeft ? "still in the keychain" : "removed")")
        print("settings: removed")
        exit(login.state == .off && !loginLeft ? 0 : 1)
    }

    // MARK: Launch guards

    /// Only one copy may run. Launching the same copy again asks the running one to show its
    /// settings. A copy from another folder (an older build, for example) is asked to quit,
    /// and this one takes over.
    private func handOverToRunningCopy() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me && !$0.isTerminated }
        guard !others.isEmpty else { return false }
        let here = Bundle.main.bundleURL.standardizedFileURL.path
        if others.contains(where: { $0.bundleURL?.standardizedFileURL.path == here }) {
            DistributedNotificationCenter.default().postNotificationName(
                Self.showSettingsNotification, object: nil, userInfo: nil, deliverImmediately: true
            )
            NSApp.terminate(nil)
            return true
        }
        others.forEach { $0.terminate() }
        return false
    }

    /// Started straight from the mounted disk image: explain how to install instead of half-working.
    private func refuseToRunFromDiskImage() -> Bool {
        guard Bundle.main.bundlePath.hasPrefix("/Volumes/") else { return false }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Сначала установи Monobrow"
        alert.informativeText = "Перетащи значок Monobrow на папку «Программы» в этом же окне и запусти его оттуда. Так он сможет стартовать вместе со Spotify."
        alert.addButton(withTitle: "Понятно")
        alert.runModal()
        NSApp.terminate(nil)
        return true
    }
}
