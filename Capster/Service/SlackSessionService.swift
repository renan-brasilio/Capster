//
//  SlackSessionService.swift
//  Capster
//

import AppKit
import CryptoKit
import Foundation
import OSLog

enum SlackSessionError: LocalizedError {
    case stateMismatch
    case missingCode
    case missingPKCEVerifier
    case missingClientSecret
    case exchangeFailed(String)

    var errorDescription: String? {
        switch self {
        case .stateMismatch:
            return "Slack sign-in state didn't match - please try signing in again."
        case .missingCode:
            return "Slack didn't return an authorization code."
        case .missingPKCEVerifier:
            return "Lost track of the sign-in request - please try signing in again."
        case .missingClientSecret:
            return "No Slack Client Secret configured in Settings."
        case .exchangeFailed(let message):
            return "Slack sign-in failed: \(message)"
        }
    }
}

/// Holds the Slack OAuth user access token, and drives the sign-in flow that produces it.
///
/// Slack's `users.profile.set` and `dnd.setSnooze`/`dnd.endSnooze` both require a real
/// per-user OAuth token (there's no session-cookie shortcut like Chorus's), so this opens
/// Slack's own web authorize page in the default browser and completes the flow via the
/// `capster://slack-oauth-callback` redirect - the user has to create their own Slack App
/// (with `users.profile:write` and `dnd:write` user scopes, redirecting to that URL) since
/// most workspaces don't allow arbitrary third-party app installs.
@MainActor
@Observable
final class SlackSessionService {
    static let redirectURI = "capster://slack-oauth-callback"
    private static let authorizeScopes = "users.profile:write,dnd:write"

    private static let accessTokenKey = "slackAccessToken"
    private static let clientSecretKey = "slackClientSecret"

    private let keychain: KeychainServing
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Capster", category: "SlackSessionService")

    /// The `state` value from the most recent `beginSignIn(clientID:)` call, checked
    /// against the callback to guard against a stray/forged redirect completing sign-in.
    /// Internal (not private) so tests can read it to build a matching callback URL.
    private(set) var pendingState: String?

    /// The PKCE code verifier generated alongside `pendingState` - Slack requires PKCE
    /// for any redirect URI that isn't a plain https:// URL (a custom app scheme like
    /// `capster://` counts as a "desktop URI" and gets rejected without it).
    private var pendingCodeVerifier: String?

    private(set) var isSignedIn: Bool

    init(keychain: KeychainServing = KeychainService()) {
        self.keychain = keychain
        self.isSignedIn = keychain.readString(key: Self.accessTokenKey) != nil
    }

    var accessToken: String? { keychain.readString(key: Self.accessTokenKey) }
    var clientSecret: String? { keychain.readString(key: Self.clientSecretKey) }

    func saveClientSecret(_ secret: String) {
        try? keychain.saveString(secret, key: Self.clientSecretKey)
    }

    /// Opens Slack's OAuth authorize page in the default browser.
    func beginSignIn(clientID: String) {
        let state = UUID().uuidString
        let codeVerifier = Self.generatePKCECodeVerifier()
        pendingState = state
        pendingCodeVerifier = codeVerifier

        var components = URLComponents(string: "https://slack.com/oauth/v2/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "user_scope", value: Self.authorizeScopes),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: Self.pkceCodeChallenge(for: codeVerifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    /// Completes sign-in from the `capster://slack-oauth-callback` redirect URL, exchanging
    /// the authorization code for a user access token.
    func completeSignIn(callbackURL: URL, clientID: String, session: HTTPUploading = URLSession.shared) async throws {
        let queryItems = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []

        guard let state = queryItems.first(where: { $0.name == "state" })?.value, state == pendingState else {
            throw SlackSessionError.stateMismatch
        }
        pendingState = nil

        guard let codeVerifier = pendingCodeVerifier else {
            throw SlackSessionError.missingPKCEVerifier
        }
        pendingCodeVerifier = nil

        guard let code = queryItems.first(where: { $0.name == "code" })?.value else {
            throw SlackSessionError.missingCode
        }

        guard let clientSecret else {
            throw SlackSessionError.missingClientSecret
        }

        var request = URLRequest(url: URL(string: "https://slack.com/api/oauth.v2.access")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "client_secret", value: clientSecret),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_verifier", value: codeVerifier)
        ]
        request.httpBody = bodyComponents.percentEncodedQuery?.data(using: .utf8)

        let (data, _) = try await session.data(for: request)
        let decoded = try JSONDecoder().decode(OAuthAccessResponse.self, from: data)

        guard decoded.ok, let token = decoded.authedUser?.accessToken else {
            throw SlackSessionError.exchangeFailed(decoded.error ?? "unknown error")
        }

        try? keychain.saveString(token, key: Self.accessTokenKey)
        isSignedIn = true
        logger.info("Slack sign-in succeeded")
    }

    func signOut() {
        try? keychain.deleteString(key: Self.accessTokenKey)
        isSignedIn = false
    }

    // MARK: - PKCE

    /// A high-entropy random string per RFC 7636 (43-128 chars from the unreserved URL
    /// character set) - generated fresh for every sign-in attempt.
    private static func generatePKCECodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    /// The "S256" challenge derived from a verifier: base64url(SHA256(verifier)).
    private static func pkceCodeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }
}

private extension Data {
    /// Standard base64, made URL-safe per RFC 4648 §5 (used by both the PKCE verifier
    /// and challenge): `+`/`/` swapped for `-`/`_`, and padding stripped.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private struct OAuthAccessResponse: Decodable {
    let ok: Bool
    let error: String?
    let authedUser: AuthedUser?

    enum CodingKeys: String, CodingKey {
        case ok, error
        case authedUser = "authed_user"
    }

    struct AuthedUser: Decodable {
        let accessToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
        }
    }
}
