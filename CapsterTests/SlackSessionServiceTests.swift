//
//  SlackSessionServiceTests.swift
//  CapsterTests
//

import Testing
import Foundation
@testable import Capster

@MainActor
struct SlackSessionServiceTests {

    @Test func startsSignedOutWithNoStoredToken() {
        let service = SlackSessionService(keychain: InMemoryKeychainStub())
        #expect(service.isSignedIn == false)
        #expect(service.accessToken == nil)
    }

    @Test func signOutClearsStoredToken() async throws {
        let keychain = InMemoryKeychainStub()
        let service = SlackSessionService(keychain: keychain)
        service.saveClientSecret("secret")
        service.beginSignIn(clientID: "client-id")

        let stub = QueuedSlackAuthUploading(results: [
            .success((Data(#"{"ok": true, "authed_user": {"access_token": "xoxp-abc"}}"#.utf8), Self.response()))
        ])
        try await service.completeSignIn(
            callbackURL: URL(string: "capster://slack-oauth-callback?code=abc&state=\(service.pendingState!)")!,
            clientID: "client-id",
            session: stub
        )
        #expect(service.isSignedIn == true)

        service.signOut()

        #expect(service.isSignedIn == false)
        #expect(service.accessToken == nil)
    }

    @Test func completeSignInExchangesCodeAndStoresToken() async throws {
        let keychain = InMemoryKeychainStub()
        let service = SlackSessionService(keychain: keychain)
        service.saveClientSecret("shhh")
        service.beginSignIn(clientID: "client-id")
        let state = try #require(service.pendingState)

        let stub = QueuedSlackAuthUploading(results: [
            .success((Data(#"{"ok": true, "authed_user": {"access_token": "xoxp-abc"}}"#.utf8), Self.response()))
        ])

        try await service.completeSignIn(
            callbackURL: URL(string: "capster://slack-oauth-callback?code=the-code&state=\(state)")!,
            clientID: "client-id",
            session: stub
        )

        #expect(service.isSignedIn == true)
        #expect(service.accessToken == "xoxp-abc")

        let request = try #require(stub.requests.first)
        #expect(request.url?.absoluteString == "https://slack.com/api/oauth.v2.access")
        let bodyString = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(bodyString.contains("code=the-code"))
        #expect(bodyString.contains("client_secret=shhh"))
    }

    @Test func completeSignInThrowsOnStateMismatch() async throws {
        let service = SlackSessionService(keychain: InMemoryKeychainStub())
        service.saveClientSecret("shhh")
        service.beginSignIn(clientID: "client-id")

        let stub = QueuedSlackAuthUploading(results: [])

        await #expect(throws: SlackSessionError.self) {
            _ = try await service.completeSignIn(
                callbackURL: URL(string: "capster://slack-oauth-callback?code=x&state=wrong-state")!,
                clientID: "client-id",
                session: stub
            )
        }
        #expect(service.isSignedIn == false)
    }

    @Test func completeSignInThrowsWhenSlackReportsFailure() async throws {
        let service = SlackSessionService(keychain: InMemoryKeychainStub())
        service.saveClientSecret("shhh")
        service.beginSignIn(clientID: "client-id")
        let state = try #require(service.pendingState)

        let stub = QueuedSlackAuthUploading(results: [
            .success((Data(#"{"ok": false, "error": "invalid_code"}"#.utf8), Self.response()))
        ])

        await #expect(throws: SlackSessionError.self) {
            _ = try await service.completeSignIn(
                callbackURL: URL(string: "capster://slack-oauth-callback?code=x&state=\(state)")!,
                clientID: "client-id",
                session: stub
            )
        }
        #expect(service.isSignedIn == false)
    }

    private static func response() -> URLResponse {
        HTTPURLResponse(url: URL(string: "https://slack.com/api/oauth.v2.access")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
}

private final class QueuedSlackAuthUploading: HTTPUploading {
    private var results: [Result<(Data, URLResponse), Error>]
    private(set) var requests: [URLRequest] = []

    init(results: [Result<(Data, URLResponse), Error>]) {
        self.results = results
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !results.isEmpty else {
            throw NSError(domain: "QueuedSlackAuthUploading", code: -1)
        }
        return try results.removeFirst().get()
    }
}
