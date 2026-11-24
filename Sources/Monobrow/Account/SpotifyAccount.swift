import AppKit
import Combine

/// The user's Spotify login, used only for likes. Runs the browser login (authorization code with
/// PKCE) and answers like requests. All published state changes happen on the main thread.
final class SpotifyAccount: ObservableObject, LikeService {
    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
    }

    private enum Outcome {
        case code(String)
        case denied
    }

    @Published private(set) var status: Status
    /// The last problem, in plain words for the settings window.
    @Published private(set) var message: String?

    var onChange: (() -> Void)?
    var isConnected: Bool { status == .connected }

    private let prefs: Preferences
    private let tokens: TokenManager
    private let api: SpotifyLibraryAPI
    private let openURL: (URL) -> Void
    private var server: LoopbackServer?
    private let flowTimeout = OneShot()
    private var flowID = 0

    init(prefs: Preferences,
         http: HTTPTransport = URLSessionTransport(),
         secrets: SecretStore = KeychainStore(service: SpotifyAuthConfig.keychainService),
         openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.prefs = prefs
        self.openURL = openURL
        tokens = TokenManager(clientID: prefs.clientID, http: http, secrets: secrets)
        api = SpotifyLibraryAPI(tokens: tokens, http: http)
        status = prefs.accountLinked && !prefs.clientID.isEmpty ? .connected : .disconnected
    }

    // MARK: Login

    static func looksLikeClientID(_ text: String) -> Bool {
        (20...64).contains(text.count) && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    static func authorizeURL(clientID: String, challenge: String, state: String) -> URL? {
        let query = FormEncoding.encode([
            ("client_id", clientID),
            ("response_type", "code"),
            ("redirect_uri", SpotifyAuthConfig.redirectURI),
            ("code_challenge_method", "S256"),
            ("code_challenge", challenge),
            ("state", state),
            ("scope", SpotifyAuthConfig.scopes),
        ])
        return URL(string: SpotifyAuthConfig.authorizeURL + "?" + query)
    }

    func connect(clientID rawClientID: String) {
        let clientID = rawClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.looksLikeClientID(clientID) else {
            message = tr("Это не похоже на Client ID. Он состоит из 32 латинских букв и цифр, скопируй его из настроек приложения в Spotify for Developers.", "This doesn't look like a Client ID. It is 32 letters and digits; copy it from your app's settings in Spotify for Developers.")
            return
        }
        cancelFlow()
        message = nil
        prefs.clientID = clientID

        let verifier = PKCE.randomVerifier()
        let state = PKCE.randomState()
        flowID += 1
        let flow = flowID
        let portMessage = tr("Не удалось начать вход: порт \(SpotifyAuthConfig.redirectPort) занят другой программой. Закрой её и попробуй ещё раз.", "Can't start the login: another app is using port \(SpotifyAuthConfig.redirectPort). Quit it and try again.")

        let server: LoopbackServer
        do {
            server = try LoopbackServer(port: SpotifyAuthConfig.redirectPort) { [weak self] request in
                Self.respond(to: request, expectedState: state) { outcome in
                    DispatchQueue.main.async {
                        self?.finish(flow: flow, outcome: outcome, verifier: verifier, clientID: clientID)
                    }
                }
            }
        } catch {
            message = portMessage
            return
        }
        self.server = server
        status = .connecting

        server.start { [weak self] result in
            DispatchQueue.main.async {
                guard let self, flow == self.flowID, self.status == .connecting else { return }
                switch result {
                case .success:
                    let challenge = PKCE.challenge(for: verifier)
                    if let url = Self.authorizeURL(clientID: clientID, challenge: challenge, state: state) {
                        self.openURL(url)
                    } else {
                        self.fail(tr("Не удалось собрать адрес для входа.", "Couldn't build the login address."))
                    }
                case .failure:
                    self.fail(portMessage)
                }
            }
        }
        flowTimeout.schedule(after: 300) { [weak self] in
            guard let self, flow == self.flowID, self.status == .connecting else { return }
            self.fail(tr("Вход не был завершён за 5 минут. Попробуй ещё раз.", "The login wasn't finished within 5 minutes. Try again."))
        }
    }

    func cancelConnect() {
        guard status == .connecting else { return }
        cancelFlow()
        status = .disconnected
        forgetLogin()
    }

    /// Whenever the account ends up disconnected, nothing of the login may stay behind.
    private func forgetLogin() {
        prefs.accountLinked = false
        Task { [tokens] in await tokens.clear() }
    }

    func disconnect() {
        cancelFlow()
        message = nil
        let wasConnected = status == .connected
        status = .disconnected
        forgetLogin()
        if wasConnected { onChange?() }
    }

    private func cancelFlow() {
        flowID += 1
        flowTimeout.cancel()
        server?.stop()
        server = nil
    }

    private func fail(_ text: String) {
        cancelFlow()
        status = .disconnected
        message = text
        forgetLogin()
    }

    private func finish(flow: Int, outcome: Outcome, verifier: String, clientID: String) {
        guard flow == flowID, status == .connecting else { return }
        flowTimeout.cancel()
        // The answer to the browser is already on its way; the port can be freed now.
        server?.stop()
        server = nil
        switch outcome {
        case .denied:
            status = .disconnected
            message = tr("Вход отменён на странице Spotify.", "The login was cancelled on Spotify's page.")
            forgetLogin()
        case .code(let code):
            Task { [weak self, tokens] in
                var failure: String?
                do {
                    await tokens.setClientID(clientID)
                    try await tokens.exchange(code: code, verifier: verifier, redirectURI: SpotifyAuthConfig.redirectURI)
                } catch {
                    failure = Self.describe(error)
                }
                let problem = failure
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard flow == self.flowID, self.status == .connecting else {
                        // The login was cancelled while the code was being exchanged.
                        if self.status != .connected { self.forgetLogin() }
                        return
                    }
                    if let problem {
                        self.status = .disconnected
                        self.message = problem
                        self.forgetLogin()
                    } else {
                        self.prefs.accountLinked = true
                        self.status = .connected
                        self.message = nil
                        self.onChange?()
                    }
                }
            }
        }
    }

    private static func respond(to request: LoopbackServer.Request, expectedState: String,
                                completion: @escaping (Outcome) -> Void) -> LoopbackServer.Response {
        guard request.path == "/callback" else {
            return .init(status: 404, html: page(title: tr("Страница не найдена", "Page not found"), text: tr("Вернись в Monobrow и начни вход заново.", "Go back to Monobrow and start the login again."), ok: false), final: false)
        }
        guard request.query["state"] == expectedState else {
            return .init(status: 400, html: page(title: tr("Запрос не от Monobrow", "This request didn't come from Monobrow"), text: tr("Вернись в Monobrow и начни вход заново.", "Go back to Monobrow and start the login again."), ok: false), final: false)
        }
        if let code = request.query["code"], !code.isEmpty {
            completion(.code(code))
            return .init(status: 200, html: page(title: tr("Monobrow подключён", "Monobrow is connected"), text: tr("Лайки теперь работают. Эту вкладку можно закрыть.", "Likes work now. You can close this tab."), ok: true), final: true)
        }
        completion(.denied)
        return .init(status: 200, html: page(title: tr("Вход отменён", "Login cancelled"), text: tr("Monobrow не получил доступ. Эту вкладку можно закрыть.", "Monobrow didn't get access. You can close this tab."), ok: false), final: true)
    }

    private static func page(title: String, text: String, ok: Bool) -> String {
        let color = ok ? "#1ED760" : "#FFB24A"
        return """
        <!doctype html><html lang="\(tr("ru", "en"))"><head><meta charset="utf-8"><title>Monobrow</title>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#0B0C0F;color:#E7E9ED;
        font:16px -apple-system,BlinkMacSystemFont,sans-serif}main{max-width:420px;padding:32px;text-align:center}
        h1{font-size:24px;margin:0 0 10px;color:\(color)}p{margin:0;color:#99A1AE;line-height:1.5}</style></head>
        <body><main><h1>\(title)</h1><p>\(text)</p></main></body></html>
        """
    }

    static func describe(_ error: Error) -> String {
        switch error as? SpotifyError {
        case .authorization(let detail):
            return tr("Spotify не принял вход (\(detail)). Проверь Client ID и что в приложении указан Redirect URI \(SpotifyAuthConfig.redirectURI).", "Spotify didn't accept the login (\(detail)). Check the Client ID and that your app lists the redirect URI \(SpotifyAuthConfig.redirectURI).")
        case .network:
            return tr("Нет связи со Spotify. Проверь интернет и попробуй ещё раз.", "Can't reach Spotify. Check your connection and try again.")
        case .rateLimited:
            return tr("Spotify просит подождать. Попробуй через минуту.", "Spotify asks to wait. Try again in a minute.")
        case .forbidden:
            return tr("Spotify отклонил запрос. Проверь, что у владельца приложения активен Premium.", "Spotify refused the request. Check that the app owner has an active Premium plan.")
        default:
            return tr("Не получилось завершить вход. Попробуй ещё раз.", "Couldn't finish the login. Try again.")
        }
    }

    // MARK: Likes

    func isLiked(trackURI: String) async throws -> Bool {
        do {
            return try await api.contains(uri: trackURI)
        } catch {
            await record(error)
            throw error
        }
    }

    func setLiked(_ liked: Bool, trackURI: String) async throws {
        do {
            if liked {
                try await api.save(uri: trackURI)
            } else {
                try await api.remove(uri: trackURI)
            }
        } catch {
            await record(error)
            throw error
        }
    }

    private func record(_ error: Error) async {
        await MainActor.run {
            switch error as? SpotifyError {
            case .reauthorizationRequired, .notConnected:
                guard self.status == .connected else { return }
                self.status = .disconnected
                self.message = tr("Spotify больше не принимает сохранённый вход. Подключи аккаунт заново.", "Spotify no longer accepts the saved login. Connect your account again.")
                self.forgetLogin()
                self.onChange?()
            case .forbidden:
                self.message = tr("Spotify отклонил запрос. Проверь, что у владельца приложения активен Premium, а твой аккаунт добавлен в User Management приложения.", "Spotify refused the request. Check that the app owner has an active Premium plan and that your account is listed under the app's User Management.")
            default:
                break
            }
        }
    }
}
