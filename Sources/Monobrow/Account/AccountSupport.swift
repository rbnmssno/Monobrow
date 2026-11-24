import CryptoKit
import Foundation
import Security

/// Saving a track to Liked Songs and asking whether it is there.
protocol LikeService: AnyObject {
    var isConnected: Bool { get }
    func isLiked(trackURI: String) async throws -> Bool
    func setLiked(_ liked: Bool, trackURI: String) async throws
}

enum SpotifyError: Error, Equatable {
    case notConnected
    /// The saved login no longer works; the user has to connect again.
    case reauthorizationRequired
    case authorization(String)
    case forbidden
    case rateLimited(TimeInterval)
    case network
    case server(Int)
    case invalidResponse
}

enum SpotifyAuthConfig {
    static let redirectPort: UInt16 = 43917
    static let redirectURI = "http://127.0.0.1:43917/callback"
    static let scopes = "user-library-read user-library-modify"
    static let authorizeURL = "https://accounts.spotify.com/authorize"
    static let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!
    static let dashboardURL = URL(string: "https://developer.spotify.com/dashboard")!
    static let keychainService = "app.monobrow.Monobrow"
    static let refreshTokenKey = "spotify-refresh-token"
}

/// Proof Key for Code Exchange (RFC 7636): lets a desktop app log in without a client secret.
enum PKCE {
    static func randomVerifier() -> String {
        base64URL(Data((0..<48).map { _ in UInt8.random(in: .min ... .max) }))
    }

    static func randomState() -> String {
        base64URL(Data((0..<18).map { _ in UInt8.random(in: .min ... .max) }))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum FormEncoding {
    private static let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    /// `a=1&b=2` with every value percent-encoded; pairs keep the given order.
    static func encode(_ fields: [(String, String)]) -> String {
        fields.map { escape($0.0) + "=" + escape($0.1) }.joined(separator: "&")
    }
}

// MARK: Secrets

protocol SecretStore {
    func read(_ key: String) -> String?
    func write(_ value: String?, key: String)
}

/// Stores the login in the user's Keychain.
struct KeychainStore: SecretStore {
    let service: String

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    func read(_ key: String) -> String? {
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String?, key: String) {
        SecItemDelete(query(key) as CFDictionary)
        guard let value else { return }
        var item = query(key)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrLabel as String] = tr("Monobrow: вход в Spotify", "Monobrow: Spotify login")
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { Log.error("keychain write failed: \(status)") }
    }
}

final class MemorySecretStore: SecretStore {
    private var values: [String: String] = [:]
    private let lock = NSLock()

    func read(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func write(_ value: String?, key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }
}

// MARK: HTTP

protocol HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

final class URLSessionTransport: HTTPTransport {
    /// Created on first use (thread-safe), so nothing network-related loads until a like is needed.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 25
        return URLSession(configuration: configuration)
    }()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await Self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SpotifyError.invalidResponse }
            return (data, http)
        } catch let error as SpotifyError {
            throw error
        } catch {
            throw SpotifyError.network
        }
    }
}

func retryAfterSeconds(_ response: HTTPURLResponse) -> TimeInterval {
    let value = response.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0) } ?? 5
    return value.clamped(1, 3600)
}
