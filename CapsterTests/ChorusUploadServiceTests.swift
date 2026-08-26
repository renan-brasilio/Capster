//
//  ChorusUploadServiceTests.swift
//  CapsterTests
//

import Testing
import Foundation
@testable import Capster

struct ChorusUploadServiceTests {

    private func tempFileWithData() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
        try Data("fake video bytes".utf8).write(to: url)
        return url
    }

    @Test func emptySessionThrowsWithoutCallingNetwork() async throws {
        let stub = QueuedHTTPUploading(results: [.success((Data(), Self.response(status: 200)))])
        let service = ChorusUploadService(session: stub)

        await #expect(throws: ChorusUploadError.self) {
            _ = try await service.upload(fileURL: try self.tempFileWithData(), cookieHeader: "", xsrfToken: "", isPrivate: true)
        }
        #expect(stub.requests.isEmpty)
    }

    @Test func successfulUploadPerformsAllThreeStepsWithAuthHeaders() async throws {
        let uploadJSON = #"{"callid": "ABC123", "account_id": null, "success": true}"#
        let stub = QueuedHTTPUploading(results: [
            .success((Data(uploadJSON.utf8), Self.response(status: 200))),
            .success((Data(), Self.response(status: 200))),
            .success((Data(), Self.response(status: 200)))
        ])
        let service = ChorusUploadService(session: stub)

        let result = try await service.upload(
            fileURL: try tempFileWithData(), cookieHeader: "session=abc; _xsrf=tok123", xsrfToken: "tok123", isPrivate: true
        )

        #expect(result.callID == "ABC123")
        #expect(stub.requests.count == 3)

        #expect(stub.requests[0].url?.absoluteString == "https://chorus.ai/api/recording/upload/")
        #expect(stub.requests[0].httpMethod == "POST")
        #expect(stub.requests[1].url?.absoluteString == "https://chorus.ai/api/recording/v2")
        #expect(stub.requests[1].httpMethod == "POST")
        #expect(stub.requests[2].url?.absoluteString == "https://chorus.ai/api/recording/access/ABC123")
        #expect(stub.requests[2].httpMethod == "PATCH")

        for request in stub.requests {
            #expect(request.value(forHTTPHeaderField: "Cookie") == "session=abc; _xsrf=tok123")
            #expect(request.value(forHTTPHeaderField: "X-Xsrftoken") == "tok123")
        }
    }

    @Test func isPrivateFlagIsSentInAccessStepBody() async throws {
        let uploadJSON = #"{"callid": "ABC123", "success": true}"#
        let stub = QueuedHTTPUploading(results: [
            .success((Data(uploadJSON.utf8), Self.response(status: 200))),
            .success((Data(), Self.response(status: 200))),
            .success((Data(), Self.response(status: 200)))
        ])
        let service = ChorusUploadService(session: stub)

        _ = try await service.upload(fileURL: try tempFileWithData(), cookieHeader: "c", xsrfToken: "x", isPrivate: false)

        let accessBody = try #require(stub.requests[2].httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: accessBody) as? [String: Bool])
        #expect(json["is_private"] == false)
    }

    @Test func uploadStepHTTPErrorStopsBeforeLaterSteps() async throws {
        let stub = QueuedHTTPUploading(results: [
            .success((Data(), Self.response(status: 401)))
        ])
        let service = ChorusUploadService(session: stub)

        await #expect(throws: ChorusUploadError.self) {
            _ = try await service.upload(fileURL: try self.tempFileWithData(), cookieHeader: "c", xsrfToken: "x", isPrivate: true)
        }
        #expect(stub.requests.count == 1)
    }

    /// Chorus's backend needs a moment after `/upload/` responds before the new `callid`
    /// is queryable by the follow-up calls - a transient 404 there should be retried
    /// rather than treated as a hard failure.
    @Test func accessStep404IsRetriedUntilItSucceeds() async throws {
        let uploadJSON = #"{"callid": "ABC123", "success": true}"#
        let stub = QueuedHTTPUploading(results: [
            .success((Data(uploadJSON.utf8), Self.response(status: 200))),
            .success((Data(), Self.response(status: 200))), // associate
            .success((Data(), Self.response(status: 404))), // access, retried...
            .success((Data(), Self.response(status: 200)))  // ...until it succeeds
        ])
        let service = ChorusUploadService(session: stub)

        let result = try await service.upload(fileURL: try tempFileWithData(), cookieHeader: "c", xsrfToken: "x", isPrivate: true)

        #expect(result.callID == "ABC123")
        #expect(stub.requests.count == 4)
    }

    @Test func uploadStepSuccessFalseThrowsUnexpectedResponse() async throws {
        let json = #"{"callid": "ABC123", "success": false}"#
        let stub = QueuedHTTPUploading(results: [
            .success((Data(json.utf8), Self.response(status: 200)))
        ])
        let service = ChorusUploadService(session: stub)

        await #expect(throws: ChorusUploadError.self) {
            _ = try await service.upload(fileURL: try self.tempFileWithData(), cookieHeader: "c", xsrfToken: "x", isPrivate: true)
        }
    }

    @Test func associateStepFailureStopsBeforeAccessStep() async throws {
        let uploadJSON = #"{"callid": "ABC123", "success": true}"#
        let stub = QueuedHTTPUploading(results: [
            .success((Data(uploadJSON.utf8), Self.response(status: 200))),
            .success((Data(), Self.response(status: 500)))
        ])
        let service = ChorusUploadService(session: stub)

        await #expect(throws: ChorusUploadError.self) {
            _ = try await service.upload(fileURL: try self.tempFileWithData(), cookieHeader: "c", xsrfToken: "x", isPrivate: true)
        }
        #expect(stub.requests.count == 2)
    }

    private static func response(status: Int) -> URLResponse {
        HTTPURLResponse(url: URL(string: "https://chorus.ai/api/recording/upload/")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}

/// Returns queued results in order, one per call, and records every request made -
/// mirrors the real service's sequential upload/access/associate calls.
private final class QueuedHTTPUploading: HTTPUploading {
    private var results: [Result<(Data, URLResponse), Error>]
    private(set) var requests: [URLRequest] = []

    init(results: [Result<(Data, URLResponse), Error>]) {
        self.results = results
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !results.isEmpty else {
            throw NSError(domain: "QueuedHTTPUploading", code: -1, userInfo: [NSLocalizedDescriptionKey: "No more queued results"])
        }
        return try results.removeFirst().get()
    }
}
