import Foundation
import CryptoKit
import AppKit
import Security

// MARK: - Own OAuth login
//
// Replaces reading Claude Code CLI's Keychain item. That item's ACL gets
// reset every time the CLI itself rotates its refresh token, which is what
// caused the recurring macOS password prompt — "Always Allow" only survives
// until the CLI rewrites the item. Owning our own OAuth grant, stored under
// our own Keychain item, means only this app ever touches that item's ACL.
//
// Same public client_id and endpoints Claude Code CLI itself uses (this is
// the standard "claude login" authorization-code + PKCE flow — client_id is
// a public app identifier, not a secret). No local HTTP listener: the
// hosted redirect shows the user a code to copy, same UX as `claude login`
// in a terminal.

private let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
private let oauthAuthorizeURL = "https://claude.ai/oauth/authorize"
private let oauthTokenURL = "https://console.anthropic.com/v1/oauth/token"
private let oauthRedirectURI = "https://console.anthropic.com/oauth/code/callback"
private let oauthScope = "user:inference user:profile user:sessions:claude_code user:mcp_servers"

private struct StoredCredentials: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Double // epoch seconds
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Double

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

// MARK: - Own Keychain item

private enum AuthKeychain {
    static let service = "ClaudeTokenIsland-credentials"

    // Updates in place when the item already exists rather than delete+recreate —
    // deleting and recreating is exactly the pattern that resets a Keychain
    // item's "Always Allow" ACL, which is the bug this whole rebuild exists to
    // avoid (see AuthManager's header comment).
    static func save(_ creds: StoredCredentials) {
        guard let data = try? JSONEncoder().encode(creds) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            SecItemAdd(attributes as CFDictionary, nil)
        }
    }

    static func load() -> StoredCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(StoredCredentials.self, from: data)
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - PKCE

private func randomURLSafeString(bytes: Int) -> String {
    var buffer = [UInt8](repeating: 0, count: bytes)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &buffer)
    return Data(buffer).base64URLEncodedString()
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - AuthManager

@MainActor
final class AuthManager: ObservableObject {
    static let shared = AuthManager()

    @Published private(set) var isAuthenticated: Bool
    @Published var lastError: String?

    private var pendingVerifier: String?
    private var pendingState: String?

    var urlSession: URLSession = .shared

    private init() {
        isAuthenticated = AuthKeychain.load() != nil
    }

    /// Opens the browser to Claude's login page. User approves, then copies
    /// the code shown on the success page and pastes it back via `completeLogin`.
    func beginLogin() {
        let verifier = randomURLSafeString(bytes: 48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        let state = randomURLSafeString(bytes: 32)
        pendingVerifier = verifier
        pendingState = state

        var components = URLComponents(string: oauthAuthorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: oauthClientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: oauthRedirectURI),
            URLQueryItem(name: "scope", value: oauthScope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    /// `pastedCode` is the "code#state" string Claude's success page shows.
    func completeLogin(pastedCode: String) async {
        guard let verifier = pendingVerifier else {
            lastError = "No login in progress — tap \"Sign in\" first."
            return
        }
        let trimmed = pastedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "#", maxSplits: 1).map(String.init)
        let code = parts.first ?? trimmed
        let state = parts.count > 1 ? parts[1] : (pendingState ?? "")

        do {
            let body: [String: String] = [
                "grant_type": "authorization_code",
                "code": code,
                "state": state,
                "client_id": oauthClientID,
                "redirect_uri": oauthRedirectURI,
                "code_verifier": verifier
            ]
            let token = try await requestToken(body: body)
            AuthKeychain.save(StoredCredentials(
                accessToken: token.accessToken,
                refreshToken: token.refreshToken,
                expiresAt: Date().timeIntervalSince1970 + token.expiresIn
            ))
            pendingVerifier = nil
            pendingState = nil
            lastError = nil
            isAuthenticated = true
        } catch {
            lastError = "Sign-in failed: \(error.localizedDescription)"
        }
    }

    func signOut() {
        AuthKeychain.clear()
        isAuthenticated = false
    }

    /// Returns a currently-valid access token, refreshing first if it's expired
    /// or about to expire.
    func validAccessToken() async throws -> String {
        guard var creds = AuthKeychain.load() else {
            throw NSError(domain: "Auth", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "Not signed in."])
        }
        let expiresSoon = creds.expiresAt - Date().timeIntervalSince1970 < 60
        if expiresSoon {
            creds = try await refresh(creds)
        }
        return creds.accessToken
    }

    /// Forces a refresh (e.g. after the API itself rejected the token with 401).
    func forceRefresh() async throws -> String {
        guard let creds = AuthKeychain.load() else {
            throw NSError(domain: "Auth", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "Not signed in."])
        }
        return try await refresh(creds).accessToken
    }

    private func refresh(_ creds: StoredCredentials) async throws -> StoredCredentials {
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": creds.refreshToken,
            "client_id": oauthClientID
        ]
        do {
            let token = try await requestToken(body: body)
            let updated = StoredCredentials(
                accessToken: token.accessToken,
                refreshToken: token.refreshToken,
                expiresAt: Date().timeIntervalSince1970 + token.expiresIn
            )
            AuthKeychain.save(updated)
            return updated
        } catch {
            // Refresh token itself is dead — only real fix is signing in again.
            AuthKeychain.clear()
            await MainActor.run { self.isAuthenticated = false }
            throw error
        }
    }

    private func requestToken(body: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: oauthTokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "OAuthToken", code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: "Token request failed: \(text)"])
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }
}
