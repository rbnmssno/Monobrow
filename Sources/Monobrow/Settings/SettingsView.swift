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
                Label(tr("Monobrow не может управлять Spotify", "Monobrow can't control Spotify"), systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(tr("macOS не разрешает Monobrow отправлять команды Spotify. Открой настройки доступа, найди Monobrow в разделе «Автоматизация» и включи переключатель Spotify.", "macOS doesn't allow Monobrow to send commands to Spotify. Open the privacy settings, find Monobrow under Automation and turn on Spotify."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(tr("Открыть настройки доступа", "Open Privacy Settings"), action: actions.openAutomationSettings)
                    Button(tr("Проверить снова", "Check Again"), action: actions.recheckPermission)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var launchSection: some View {
        Section(tr("Запуск", "Launch")) {
            Toggle(isOn: Binding(get: { login.state == .on }, set: { login.setEnabled($0) })) {
                row(tr("Запускать вместе со Spotify", "Start with Spotify"),
                    tr("Monobrow стартует при входе в систему и ждёт в фоне. Остров появляется, когда открываешь Spotify, и исчезает вместе с ним.", "Monobrow opens at login and waits in the background. The island appears when you open Spotify and goes away when you quit it."))
            }
            if login.state == .needsApproval {
                HStack {
                    Text(tr("Автозапуск Monobrow выключен в системных настройках.", "Monobrow is turned off in Login Items."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(tr("Открыть", "Open"), action: login.openSystemSettings)
                }
            }
            if let problem = login.problem {
                Text(problem).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Toggle(isOn: $prefs.showDockIcon) {
                row(tr("Показывать значок в Dock", "Show in Dock"),
                    tr("Без значка Monobrow работает незаметно. Чтобы снова открыть это окно, запусти Monobrow ещё раз или нажми на остров правой кнопкой.", "Without a Dock icon Monobrow stays out of sight. To get back to this window, open Monobrow again or right-click the island."))
            }
        }
    }

    private var islandSection: some View {
        Section(tr("Остров", "Island")) {
            Toggle(isOn: $prefs.showPeek) {
                row(tr("Показывать новый трек", "Announce new tracks"), tr("Когда трек меняется, остров на пару секунд раскрывается с названием и артистом.", "When the track changes, the island briefly opens with the title and artist."))
            }
            Toggle(isOn: $prefs.animatedEqualizer) {
                row(tr("Анимированный эквалайзер", "Animated equalizer"), tr("Выключи, если нужен совсем неподвижный остров. В режиме энергосбережения он замирает сам.", "Turn it off for a completely still island. It also stops by itself in Low Power Mode."))
            }
            Toggle(isOn: $prefs.hideWhenPaused) {
                row(tr("Прятать на паузе", "Hide when paused"), tr("Через 10 секунд после паузы остров уходит в вырез. Наведи курсор на вырез, и плеер откроется.", "Ten seconds after you pause, the island folds into the notch. Hover the notch to open the player."))
            }
            Picker(selection: $prefs.screenMode) {
                Text("MacBook").tag(ScreenMode.builtIn)
                Text(tr("Все экраны", "All Screens")).tag(ScreenMode.all)
            } label: {
                row(tr("Где показывать", "Show on"), tr("С закрытой крышкой остров сам переезжает на внешний монитор.", "With the lid closed, the island moves to the external display by itself."))
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
                Button(tr("Выйти из Monobrow", "Quit Monobrow"), action: actions.quit)
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
        Section(tr("Лайки", "Likes")) {
            switch account.status {
            case .connected:
                HStack {
                    Label(tr("Аккаунт Spotify подключён", "Spotify account connected"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button(tr("Отключить", "Disconnect")) { account.disconnect() }
                }
            case .connecting:
                HStack {
                    ProgressView().controlSize(.small)
                    Text(tr("Заверши вход в браузере…", "Finish signing in in your browser…"))
                    Spacer()
                    Button(tr("Отмена", "Cancel")) { account.cancelConnect() }
                }
            case .disconnected:
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("Чтобы ставить лайки, подключи свой аккаунт Spotify. Понадобится Client ID твоего приложения в Spotify for Developers. Нужен Premium.", "To like tracks, connect your Spotify account. You'll need the Client ID of your own app in Spotify for Developers, and Spotify Premium."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        TextField("Client ID", text: $clientID, prompt: Text(tr("Client ID, 32 символа", "Client ID, 32 characters")))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .onSubmit(connect)
                        Button(tr("Подключить", "Connect"), action: connect)
                            .disabled(clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(.vertical, 2)
                DisclosureGroup(tr("Как получить Client ID", "How to get a Client ID"), isExpanded: $showSteps) {
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
            step(1, tr("Открой Spotify for Developers и войди в свой аккаунт.", "Open Spotify for Developers and log in."))
            Button(tr("Открыть Spotify for Developers", "Open Spotify for Developers")) { NSWorkspace.shared.open(SpotifyAuthConfig.dashboardURL) }
            step(2, tr("Нажми Create app. Название и описание могут быть любыми.", "Click Create app. Any name and description will do."))
            step(3, tr("В поле Redirect URIs вставь этот адрес и нажми Add:", "Paste this address into Redirect URIs and click Add:"))
            HStack {
                Text(SpotifyAuthConfig.redirectURI)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                Button(copied ? tr("Скопировано", "Copied") : tr("Скопировать", "Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(SpotifyAuthConfig.redirectURI, forType: .string)
                    copied = true
                }
            }
            step(4, tr("В списке APIs отметь Web API, прими условия и нажми Save.", "Under APIs, select Web API, accept the terms and click Save."))
            step(5, tr("На странице приложения открой Settings, скопируй Client ID и вставь его в поле выше.", "On the app's page open Settings, copy the Client ID and paste it into the field above."))
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
