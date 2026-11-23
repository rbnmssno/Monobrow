import AppKit

/// Tells when the Spotify desktop app starts and quits. The system pushes these events; nothing is polled.
final class SpotifyWatcher {
    var onChange: ((Bool) -> Void)?
    private(set) var isRunning = false
    private var tokens: [NSObjectProtocol] = []

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            self?.handle(note, running: true)
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            self?.handle(note, running: false)
        })
        isRunning = Self.spotifyIsRunning()
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        tokens.forEach { center.removeObserver($0) }
        tokens.removeAll()
    }

    static func spotifyIsRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: SpotifyAppleEvents.bundleID).isEmpty
    }

    private func handle(_ note: Notification, running: Bool) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == SpotifyAppleEvents.bundleID else { return }
        // A second copy quitting must not hide the island while another one is still running.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: SpotifyAppleEvents.bundleID)
            .contains { $0.processIdentifier != app.processIdentifier && !$0.isTerminated }
        let actual = running || others
        guard actual != isRunning else { return }
        isRunning = actual
        onChange?(actual)
    }
}
