import AppKit
import SwiftUI

struct SettingsActions {
    var openAutomationSettings: () -> Void
    var recheckPermission: () -> Void
    var quit: () -> Void
}

struct SettingsView: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var model: PlayerModel
    @ObservedObject var login: LoginItem
    /// Nil in demo mode, where there is no real Spotify account.
    let account: SpotifyAccount?
    let actions: SettingsActions

    var body: some View {
        Form {
            if model.permission == .denied {
                accessSection
            }
            launchSection
            islandSection
            if let account {
                AccountSection(account: account, prefs: prefs)
            }
            footerSection
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 700)
        .onAppear { login.refresh() }
    }

    private var accessSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Monobrow не может управлять Spotify", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("macOS не разрешает Monobrow отправлять команды Spotify. Открой настройки доступа, найди Monobrow в разделе «Автоматизация» и включи переключатель Spotify.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Открыть настройки доступа", action: actions.openAutomationSettings)
                    Button("Проверить снова", action: actions.recheckPermission)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var launchSection: some View {
        Section("Запуск") {
            Toggle(isOn: Binding(get: { login.state == .on }, set: { login.setEnabled($0) })) {
                row("Запускать вместе со Spotify",
                    "Monobrow стартует при входе в систему и ждёт в фоне. Остров появляется, когда открываешь Spotify, и исчезает вместе с ним.")
            }
            if login.state == .needsApproval {
                HStack {
                    Text("Автозапуск Monobrow выключен в системных настройках.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Открыть", action: login.openSystemSettings)
                }
            }
            if let problem = login.problem {
                Text(problem).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Toggle(isOn: $prefs.showDockIcon) {
                row("Показывать значок в Dock",
                    "Без значка Monobrow работает незаметно. Чтобы снова открыть это окно, запусти Monobrow ещё раз или нажми на остров правой кнопкой.")
            }
        }
    }

    private var islandSection: some View {
        Section("Остров") {
            Toggle(isOn: $prefs.showPeek) {
                row("Показывать новый трек", "Когда трек меняется, остров на пару секунд раскрывается с названием и артистом.")
            }
            Toggle(isOn: $prefs.animatedEqualizer) {
                row("Анимированный эквалайзер", "Выключи, если нужен совсем неподвижный остров. В режиме энергосбережения он замирает сам.")
            }
            Toggle(isOn: $prefs.hideWhenPaused) {
                row("Прятать на паузе", "Через 10 секунд после паузы остров уходит в вырез. Наведи курсор на вырез, и плеер откроется.")
            }
            Picker(selection: $prefs.screenMode) {
                Text("MacBook").tag(ScreenMode.builtIn)
                Text("Все экраны").tag(ScreenMode.all)
            } label: {
                row("Где показывать", "С закрытой крышкой остров сам переезжает на внешний монитор.")
            }
            .pickerStyle(.segmented)
        }
    }

    private var footerSection: some View {
        Section {
            HStack {
                Text("Monobrow \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Выйти из Monobrow", action: actions.quit)
            }
        }
    }

    private func row(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Connecting the Spotify account for likes.
private struct AccountSection: View {
    @ObservedObject var account: SpotifyAccount
    @ObservedObject var prefs: Preferences
    @State private var clientID = ""
    @State private var showSteps = false
    @State private var copied = false

    var body: some View {
        Section("Лайки") {
            switch account.status {
            case .connected:
                HStack {
                    Label("Аккаунт Spotify подключён", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Отключить") { account.disconnect() }
                }
            case .connecting:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Заверши вход в браузере…")
                    Spacer()
                    Button("Отмена") { account.cancelConnect() }
                }
            case .disconnected:
                VStack(alignment: .leading, spacing: 8) {
                    Text("Чтобы ставить лайки, подключи свой аккаунт Spotify. Понадобится Client ID твоего приложения в Spotify for Developers. Нужен Premium.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        TextField("Client ID", text: $clientID, prompt: Text("Client ID, 32 символа"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .onSubmit(connect)
                        Button("Подключить", action: connect)
                            .disabled(clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(.vertical, 2)
                DisclosureGroup("Как получить Client ID", isExpanded: $showSteps) {
                    steps
                }
            }
            if let message = account.message {
                Text(message).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { clientID = prefs.clientID }
    }

    private func connect() {
        account.connect(clientID: clientID)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 8) {
            step(1, "Открой Spotify for Developers и войди в свой аккаунт.")
            Button("Открыть Spotify for Developers") { NSWorkspace.shared.open(SpotifyAuthConfig.dashboardURL) }
            step(2, "Нажми Create app. Название и описание могут быть любыми.")
            step(3, "В поле Redirect URIs вставь этот адрес и нажми Add:")
            HStack {
                Text(SpotifyAuthConfig.redirectURI)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                Button(copied ? "Скопировано" : "Скопировать") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(SpotifyAuthConfig.redirectURI, forType: .string)
                    copied = true
                }
            }
            step(4, "В списке APIs отметь Web API, прими условия и нажми Save.")
            step(5, "На странице приложения открой Settings, скопируй Client ID и вставь его в поле выше.")
        }
        .padding(.top, 4)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}
