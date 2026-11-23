import Combine
import Foundation

enum ScreenMode: String {
    case builtIn
    case all
}

/// User settings, stored in UserDefaults.
final class Preferences: ObservableObject {
    private let store: UserDefaults

    @Published var showPeek: Bool { didSet { store.set(showPeek, forKey: Key.showPeek) } }
    @Published var animatedEqualizer: Bool { didSet { store.set(animatedEqualizer, forKey: Key.animatedEqualizer) } }
    @Published var hideWhenPaused: Bool { didSet { store.set(hideWhenPaused, forKey: Key.hideWhenPaused) } }
    @Published var screenMode: ScreenMode { didSet { store.set(screenMode.rawValue, forKey: Key.screenMode) } }
    @Published var showDockIcon: Bool { didSet { store.set(showDockIcon, forKey: Key.showDockIcon) } }
    @Published var clientID: String { didSet { store.set(clientID, forKey: Key.clientID) } }

    /// True once the Spotify account was connected successfully. The token itself lives in the Keychain.
    var accountLinked: Bool {
        get { store.bool(forKey: Key.accountLinked) }
        set { store.set(newValue, forKey: Key.accountLinked) }
    }

    var didOnboard: Bool {
        get { store.bool(forKey: Key.didOnboard) }
        set { store.set(newValue, forKey: Key.didOnboard) }
    }

    /// True once "open at login" was switched on automatically; after that the choice is the user's.
    var didSetUpLoginItem: Bool {
        get { store.bool(forKey: Key.didSetUpLoginItem) }
        set { store.set(newValue, forKey: Key.didSetUpLoginItem) }
    }

    private enum Key {
        static let showPeek = "showPeek"
        static let animatedEqualizer = "animatedEqualizer"
        static let hideWhenPaused = "hideWhenPaused"
        static let screenMode = "screenMode"
        static let showDockIcon = "showDockIcon"
        static let clientID = "spotifyClientID"
        static let accountLinked = "spotifyAccountLinked"
        static let didOnboard = "didOnboard"
        static let didSetUpLoginItem = "didSetUpLoginItem"
    }

    init(store: UserDefaults) {
        self.store = store
        store.register(defaults: [
            Key.showPeek: true,
            Key.animatedEqualizer: true,
            Key.hideWhenPaused: true,
            Key.screenMode: ScreenMode.builtIn.rawValue,
            Key.showDockIcon: false,
        ])
        showPeek = store.bool(forKey: Key.showPeek)
        animatedEqualizer = store.bool(forKey: Key.animatedEqualizer)
        hideWhenPaused = store.bool(forKey: Key.hideWhenPaused)
        screenMode = ScreenMode(rawValue: store.string(forKey: Key.screenMode) ?? "") ?? .builtIn
        showDockIcon = store.bool(forKey: Key.showDockIcon)
        clientID = store.string(forKey: Key.clientID) ?? ""
    }
}
