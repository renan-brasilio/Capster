//
//  ChorusSessionService.swift
//  Capster
//

import Foundation

/// Holds the Chorus web session captured via an embedded login (`ChorusLoginView`).
///
/// Most Chorus users don't have the role permission needed to generate a personal API
/// token for the documented REST API, so Capster instead drives the same session-cookie
/// endpoint the "Import a Recording" feature in Chorus's own Settings uses. See
/// `ChorusUploadService` for the captured request contract.
@MainActor
@Observable
final class ChorusSessionService {
    private static let cookieKey = "chorusSessionCookie"
    private static let xsrfKey = "chorusXsrfToken"

    private let keychain: KeychainServing

    private(set) var isSignedIn: Bool

    init(keychain: KeychainServing = KeychainService()) {
        self.keychain = keychain
        self.isSignedIn = keychain.readString(key: Self.cookieKey) != nil
    }

    var cookieHeader: String? { keychain.readString(key: Self.cookieKey) }
    var xsrfToken: String? { keychain.readString(key: Self.xsrfKey) }

    /// Stores a freshly captured session. `cookieHeader` is the full `Cookie` request
    /// header value (every chorus.ai cookie, `name=value` pairs joined with `; `);
    /// `xsrfToken` is the value of the `_xsrf` cookie, echoed separately as the
    /// `X-Xsrftoken` header per Chorus's double-submit CSRF pattern.
    func save(cookieHeader: String, xsrfToken: String) {
        try? keychain.saveString(cookieHeader, key: Self.cookieKey)
        try? keychain.saveString(xsrfToken, key: Self.xsrfKey)
        isSignedIn = true
    }

    func signOut() {
        try? keychain.deleteString(key: Self.cookieKey)
        try? keychain.deleteString(key: Self.xsrfKey)
        isSignedIn = false
    }
}
