//
//  SlackStatusServiceTests.swift
//  CapsterTests
//

import Testing
import Foundation
@testable import Capster

struct SlackStatusServiceTests {

    @Test func setStatusSendsBearerTokenAndProfileFields() async throws {
        let stub = QueuedSlackHTTPUploading(results: [
            .success((Data(#"{"ok": true}"#.utf8), Self.response(status: 200)))
        ])
        let service = SlackStatusService(session: stub)

        let succeeded = await service.setStatus(text: "Recording", emoji: ":black_circle_for_record:", accessToken: "xoxp-abc")

        #expect(succeeded == true)
        #expect(stub.requests.count == 1)
        #expect(stub.requests[0].url?.absoluteString == "https://slack.com/api/users.profile.set")
        #expect(stub.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer xoxp-abc")

        let body = try #require(stub.requests[0].httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: [String: Any]])
        let profile = try #require(json["profile"])
        #expect(profile["status_text"] as? String == "Recording")
        #expect(profile["status_emoji"] as? String == ":black_circle_for_record:")
    }

    @Test func setStatusReturnsFalseWhenSlackReportsNotOK() async throws {
        let stub = QueuedSlackHTTPUploading(results: [
            .success((Data(#"{"ok": false, "error": "invalid_auth"}"#.utf8), Self.response(status: 200)))
        ])
        let service = SlackStatusService(session: stub)

        let succeeded = await service.setStatus(text: "x", emoji: "x", accessToken: "bad-token")
        #expect(succeeded == false)
    }

    @Test func fetchCurrentStatusReturnsPreviousStatusOnSuccess() async throws {
        let json = #"{"ok": true, "profile": {"status_text": "On PTO", "status_emoji": ":palm_tree:", "status_expiration": 123}}"#
        let stub = QueuedSlackHTTPUploading(results: [.success((Data(json.utf8), Self.response(status: 200)))])
        let service = SlackStatusService(session: stub)

        let status = await service.fetchCurrentStatus(accessToken: "xoxp-abc")

        #expect(status?.text == "On PTO")
        #expect(status?.emoji == ":palm_tree:")
        #expect(status?.expiration == 123)
    }

    @Test func fetchCurrentStatusReturnsNilOnFailure() async throws {
        let stub = QueuedSlackHTTPUploading(results: [
            .success((Data(#"{"ok": false, "error": "invalid_auth"}"#.utf8), Self.response(status: 200)))
        ])
        let service = SlackStatusService(session: stub)

        let status = await service.fetchCurrentStatus(accessToken: "bad-token")
        #expect(status == nil)
    }

    @Test func fetchDoNotDisturbSnoozeActiveReturnsTrueWhenAlreadySnoozed() async throws {
        let json = #"{"ok": true, "snooze_enabled": true}"#
        let stub = QueuedSlackHTTPUploading(results: [.success((Data(json.utf8), Self.response(status: 200)))])
        let service = SlackStatusService(session: stub)

        let snoozeActive = await service.fetchDoNotDisturbSnoozeActive(accessToken: "xoxp-abc")

        #expect(snoozeActive == true)
        #expect(stub.requests[0].url?.absoluteString == "https://slack.com/api/dnd.info")
    }

    @Test func fetchDoNotDisturbSnoozeActiveReturnsFalseWhenNotSnoozed() async throws {
        let json = #"{"ok": true, "snooze_enabled": false}"#
        let stub = QueuedSlackHTTPUploading(results: [.success((Data(json.utf8), Self.response(status: 200)))])
        let service = SlackStatusService(session: stub)

        let snoozeActive = await service.fetchDoNotDisturbSnoozeActive(accessToken: "xoxp-abc")
        #expect(snoozeActive == false)
    }

    @Test func fetchDoNotDisturbSnoozeActiveReturnsNilOnFailure() async throws {
        let stub = QueuedSlackHTTPUploading(results: [
            .success((Data(#"{"ok": false, "error": "invalid_auth"}"#.utf8), Self.response(status: 200)))
        ])
        let service = SlackStatusService(session: stub)

        let snoozeActive = await service.fetchDoNotDisturbSnoozeActive(accessToken: "bad-token")
        #expect(snoozeActive == nil)
    }

    @Test func startDoNotDisturbSendsNumMinutes() async throws {
        let stub = QueuedSlackHTTPUploading(results: [.success((Data(#"{"ok": true}"#.utf8), Self.response(status: 200)))])
        let service = SlackStatusService(session: stub)

        let succeeded = await service.startDoNotDisturb(minutes: 480, accessToken: "xoxp-abc")

        #expect(succeeded == true)
        #expect(stub.requests[0].url?.absoluteString == "https://slack.com/api/dnd.setSnooze")
        let body = try #require(stub.requests[0].httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Int])
        #expect(json["num_minutes"] == 480)
    }

    @Test func endDoNotDisturbCallsEndSnooze() async throws {
        let stub = QueuedSlackHTTPUploading(results: [.success((Data(#"{"ok": true}"#.utf8), Self.response(status: 200)))])
        let service = SlackStatusService(session: stub)

        let succeeded = await service.endDoNotDisturb(accessToken: "xoxp-abc")

        #expect(succeeded == true)
        #expect(stub.requests[0].url?.absoluteString == "https://slack.com/api/dnd.endSnooze")
    }

    @Test func networkErrorReturnsFalseWithoutThrowing() async throws {
        let service = SlackStatusService(session: ThrowingSlackHTTPUploading())
        let succeeded = await service.setStatus(text: "x", emoji: "x", accessToken: "x")
        #expect(succeeded == false)
    }

    private static func response(status: Int) -> URLResponse {
        HTTPURLResponse(url: URL(string: "https://slack.com/api/users.profile.set")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}

private final class QueuedSlackHTTPUploading: HTTPUploading {
    private var results: [Result<(Data, URLResponse), Error>]
    private(set) var requests: [URLRequest] = []

    init(results: [Result<(Data, URLResponse), Error>]) {
        self.results = results
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !results.isEmpty else {
            throw NSError(domain: "QueuedSlackHTTPUploading", code: -1)
        }
        return try results.removeFirst().get()
    }
}

private final class ThrowingSlackHTTPUploading: HTTPUploading {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw NSError(domain: "ThrowingSlackHTTPUploading", code: -1)
    }
}
