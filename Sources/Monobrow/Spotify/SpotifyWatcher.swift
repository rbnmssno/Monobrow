import AppKit

/// Tells when a player app starts and quits: Spotify, or Wisp for SoundCloud. The system pushes these
/// events; nothing is polled.
final class SpotifyWatcher {
    var onChange: ((Bool) -> Void)?
    private(set) var isRunning = false
    private let bundleID: String
    private var tokens: [NSObjectProtocol] = []

    init(bundleID: String = SpotifyAppleEvents.bundleID) {
        self.bundleID = bundleID
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            self?.handle(note, running: true)
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            self?.handle(note, running: false)
        })
        isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        tokens.forEach { center.removeObserver($0) }
        tokens.removeAll()
    }

    private func handle(_ note: Notification, running: Bool) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == bundleID else { return }
        // A second copy quitting must not hide the island while another one is still running.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != app.processIdentifier && !$0.isTerminated }
        let actual = running || others
        guard actual != isRunning else { return }
        isRunning = actual
        onChange?(actual)
    }
}
