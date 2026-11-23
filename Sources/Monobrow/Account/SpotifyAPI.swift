import Foundation

private struct TokenResponse: Decodable {
    let access_token: String
    let expires_in: Double?
    let refresh_token: String?
}

private struct TokenErrorBody: Decodable {
    let error: String?
    let error_description: String?
}

/// Holds the Spotify login: exchanges the authorization code, refreshes the access token when it
/// expires and keeps the refresh token in the secret store. Concurrent callers share one refresh.
actor TokenManager {
    private let http: HTTPTransport
    private let secrets: SecretStore
    private var clientID: String
    private var accessToken: String?
    private var expiry = Date.distantPast
    private var refreshToken: String?
    private var refreshTokenLoaded = false
    private var refreshTask: Task<String, Error>?
    /// Grows with every `clear()`. A request that started before a clear must not store its result.
    private var epoch = 0

    init(clientID: String, http: HTTPTransport, secrets: SecretStore) {
        self.clientID = clientID
        self.http = http
        self.secrets = secrets
    }

    func setClientID(_ value: String) {
        clientID = value
    }

    func exchange(code: String, verifier: String, redirectURI: String) async throws {
        let started = epoch
        let response = try await requestToken([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", clientID),
            ("code_verifier", verifier),
        ])
        guard let refresh = response.refresh_token, !refresh.isEmpty else { throw SpotifyError.invalidResponse }
        guard started == epoch else { throw SpotifyError.notConnected }
        adopt(response, refreshToken: refresh)
    }

    func validAccessToken() async throws -> String {
        if let accessToken, Date() < expiry { return accessToken }
        if let refreshTask { return try await refreshTask.value }
        let task = Task { try await self.refresh() }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    /// Call when the API answers 401: the next request refreshes the token first.
    func invalidateAccessToken() {
        accessToken = nil
        expiry = .distantPast
    }

    func clear() {
        epoch += 1
        accessToken = nil
        expiry = .distantPast
        refreshToken = nil
        refreshTokenLoaded = true
        secrets.write(nil, key: SpotifyAuthConfig.refreshTokenKey)
    }

    private func storedRefreshToken() -> String? {
        if !refreshTokenLoaded {
            refreshToken = secrets.read(SpotifyAuthConfig.refreshTokenKey)
            refreshTokenLoaded = true
        }
        return refreshToken
    }

    private func refresh() async throws -> String {
        guard !clientID.isEmpty, let token = storedRefreshToken() else { throw SpotifyError.notConnected }
        let started = epoch
        do {
            let response = try await requestToken([
                ("grant_type", "refresh_token"),
                ("refresh_token", token),
                ("client_id", clientID),
            ])
            // Disconnected while the request was under way: the new tokens are not wanted.
            guard started == epoch else { throw SpotifyError.notConnected }
            // Spotify may or may not hand out a new refresh token; keep the old one if it does not.
            adopt(response, refreshToken: response.refresh_token.flatMap { $0.isEmpty ? nil : $0 } ?? token)
            return response.access_token
        } catch SpotifyError.authorization {
            if started == epoch { clear() }
            throw SpotifyError.reauthorizationRequired
        }
    }

    private func adopt(_ response: TokenResponse, refreshToken newToken: String) {
        accessToken = response.access_token
        expiry = Date().addingTimeInterval(max(60, (response.expires_in ?? 3600) - 60))
        if newToken != refreshToken || !refreshTokenLoaded {
            secrets.write(newToken, key: SpotifyAuthConfig.refreshTokenKey)
        }
        refreshToken = newToken
        refreshTokenLoaded = true
    }

    private func requestToken(_ fields: [(String, String)]) async throws -> TokenResponse {
        var request = URLRequest(url: SpotifyAuthConfig.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(FormEncoding.encode(fields).utf8)
        let (data, response) = try await http.send(request)
        switch response.statusCode {
        case 200:
            guard let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data), !decoded.access_token.isEmpty else {
                throw SpotifyError.invalidResponse
            }
            return decoded
        case 400, 401:
            let body = try? JSONDecoder().decode(TokenErrorBody.self, from: data)
            throw SpotifyError.authorization(body?.error_description ?? body?.error ?? "invalid_request")
        case 429:
            throw SpotifyError.rateLimited(retryAfterSeconds(response))
        default:
            throw SpotifyError.server(response.statusCode)
        }
    }
}

/// The three library calls the like button needs. Spotify replaced the per-type endpoints with
/// `/me/library` in February 2026; it takes Spotify URIs in the `uris` query parameter.
actor SpotifyLibraryAPI {
    private static let endpoint = "https://api.spotify.com/v1/me/library"

    private let tokens: TokenManager
    private let http: HTTPTransport
    private var blockedUntil = Date.distantPast

    init(tokens: TokenManager, http: HTTPTransport) {
        self.tokens = tokens
        self.http = http
    }

    func contains(uri: String) async throws -> Bool {
        let data = try await perform("GET", path: "/contains", uri: uri)
        guard let flags = try? JSONDecoder().decode([Bool].self, from: data), let first = flags.first else {
            throw SpotifyError.invalidResponse
        }
        return first
    }

    func save(uri: String) async throws {
        _ = try await perform("PUT", path: "", uri: uri)
    }

    func remove(uri: String) async throws {
        _ = try await perform("DELETE", path: "", uri: uri)
    }

    private func perform(_ method: String, path: String, uri: String) async throws -> Data {
        let wait = blockedUntil.timeIntervalSinceNow
        if wait > 0 { throw SpotifyError.rateLimited(wait) }
        guard let url = URL(string: Self.endpoint + path + "?uris=" + FormEncoding.escape(uri)) else {
            throw SpotifyError.invalidResponse
        }
        var refreshed = false
        while true {
            let token = try await tokens.validAccessToken()
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            if method != "GET" { request.httpBody = Data() }
            let (data, response) = try await http.send(request)
            switch response.statusCode {
            case 200..<300:
                return data
            case 401:
                // The access token expired early or was revoked: refresh once, then give up.
                if refreshed { throw SpotifyError.reauthorizationRequired }
                refreshed = true
                await tokens.invalidateAccessToken()
            case 403:
                throw SpotifyError.forbidden
            case 429:
                let seconds = retryAfterSeconds(response)
                blockedUntil = Date().addingTimeInterval(seconds)
                throw SpotifyError.rateLimited(seconds)
            default:
                throw SpotifyError.server(response.statusCode)
            }
        }
    }
}
