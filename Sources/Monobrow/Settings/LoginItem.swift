import Combine
import Foundation
import ServiceManagement

/// "Open at login" for the app itself. Monobrow then waits in the background for Spotify to start.
final class LoginItem: ObservableObject {
    enum State: Equatable {
        case off
        case on
        /// Registered, but switched off by the user in System Settings.
        case needsApproval
    }

    @Published private(set) var state = State.off
    @Published private(set) var problem: String?

    init() {
        refresh()
    }

    /// Opening at login only makes sense for a copy that stays where it is.
    static var installedInApplications: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    func refresh() {
        let newState: State
        switch SMAppService.mainApp.status {
        case .enabled: newState = .on
        case .requiresApproval: newState = .needsApproval
        default: newState = .off
        }
        if newState != state { state = newState }
    }

    func setEnabled(_ enabled: Bool) {
        problem = nil
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
        } catch {
            problem = enabled
                ? "macOS не дала добавить Monobrow в автозапуск. Добавь его вручную: Системные настройки → Основные → Объекты входа."
                : "Не получилось убрать Monobrow из автозапуска. Убери его вручную: Системные настройки → Основные → Объекты входа."
            Log.error("login item change failed: \((error as NSError).domain) \((error as NSError).code)")
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
