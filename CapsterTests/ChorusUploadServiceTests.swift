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
            _ = try await service.upload(fileURL: try self.tempFileWithData(), title: "x", cookieHeader: "", xsrfToken: "", isPrivate: true)
        }
        #expect(stub.requests.isEmpty)
    }

    @Test func successfulUploadPerformsAllFourStepsWithAuthHeaders() async throws {
        let uploadJSON = #"{"callid": "ABC123", "account_id": null, "success": true}"#
        let stub = QueuedHTTPUploading(results: [
            .success((Data(uploadJSON.utf8), Self.response(status: 200))),
            .success((Data(), Self.response(status: 200))), // associate
            .success((Data(), Self.response(status: 200))), // setTitle
            .success((Data(), Self.response(status: 200)))  // access
        ])
        let service = ChorusUploadService(session: stub)

        let result = try await service.upload(
            fileURL: try tempFileWithData(), title: "My Recording", cookieHeader: "session=abc; _xsrf=tok123", xsrfToken: "tok123", isPrivate: true
        )

        #expect(result.callID == "ABC123")
        #expect(stub.requests.count == 4)

        #expect(stub.requests[0].url?.absoluteString == "https://chorus.ai/api/recording/upload/")
        #expect(stub.requests[0].httpMethod == "POST")
        #expect(stub.requests[1].url?.absoluteString == "https://chorus.ai/api/recording/v2")
        #expect(stub.requests[1].httpMethod == "POST")
        #expect(stub.requests[2].url?.absoluteString == "https://chorus.ai/api/recording/v2/")
        #expect(stub.requests[2].httpMethod == "POST")
        #expect(stub.requests[3].url?.absoluteString == "https://chorus.ai/api/recording/access/ABC123")
        #expect(stub.requests[3].httpMethod == "PATCH")

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
            .success((Data(), Self.response(status: 200))),
            .success((Data(), Self.response(status: 200)))
        ])
        let service = ChorusUploadService(session: stub)

        _ = try await service.upload(fileURL: try tempFileWithData(), title: "x", cookieHeader: "c", xsrfToken: "x", isPrivate: false)

        let accessBody = try #require(stub.requests[3].httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: accessBody) as? [String: Bool])
        #expect(json["is_private"] == false)
    }

    /// Confirmed by watching Chorus's own "Recording Settings" rename dialog fire this
    /// exact request - `name` is always the literal string "stage" (Chorus's internal key
    /// for the title field), and `value` is the title itself.
    @Test func titleIsSentAsStageFieldInSetTitleStep() async throws {
        let uploadJSON = #"{"callid": "ABC123", "success": true}"#
        let stub = QueuedHTTPUploading(results: [
            .success((Data(uploadJSON.utf8), Self.response(status: 200))),
            .success((Data(), Self.response(status: 200))), // associate
            .success((Data(), Self.response(status: 200))), // setTitle
            .success((Data(), Self.response(status: 200)))  // access
        ])
        let service = ChorusUploadService(session: stub)

        _ = try await service.upload(fileURL: try tempFileWithData(), title: "Client Demo", cookieHeader: "c", xsrfToken: "x", isPrivate: true)

        let setTitleBody = try #require(stub.requests[2].httpBody)
        let bodyString = try #require(String(data: setTitleBody, encoding: .utf8))
        #expect(bodyString.contains("callid=ABC123"))
        #expect(bodyString.contains("name=stage"))
        #expect(bodyString.contains("value=Client%20Demo"))
    }

    @Test func uploadStepHTTPErrorStopsBeforeLaterSteps() async throws {
        let stub = QueuedHTTPUploading(results: [
            .success((Data(), Self.response(status: 401)))
        ])
        let service = ChorusUploadService(session: stub)

        await #expect(throws: ChorusUploadError.self) {
            _ = try await service.upload(fileURL: try self.tempFileWithData(), title: "x", cookieHeader: "c", xsrfToken: "x", isPrivate: true)
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
            .success((Data(), Self.response(status: 200))), // setTitle
            .success((Data(), Self.response(status: 404))), // access, retried...
            .success((Data(), Self.response(status: 200)))  // ...until it succeeds
        ])
        let service = ChorusUploadService(session: stub)

        let result = try await service.upload(fileURL: try tempFileWithData(), title: "x", cookieHeader: "c", xsrfToken: "x", isPrivate: true)

        #expect(result.callID == "ABC123")
        #expect(stub.requests.count == 5)
    }

    /// A 500 on the access step specifically has also been observed during the same
    /// "still settling" window as the 404 case above, so it gets the same retry treatment.
    @Test func accessStep500IsRetriedUntilItSucceeds() async throws {
        let uploadJSON = #"{"callid": "ABC123", "success": true}"#
        let stub = QueuedHTTPUploading(results: [
            .success((Data(uploadJSON.utf8), Self.response(status: 200))),
            .success((Data(), Self.response(status: 200))), // associate
            .success((Data(), Self.response(status: 200))), // setTitle
            .success((Data(), Self.response(status: 500))), // access, retried...
            .success((Data(), Self.response(status: 200)))  // ...until it succeeds
        ])
        let service = ChorusUploadService(session: stub)

        let result = try await service.upload(fileURL: try tempFileWithData(), title: "x", cookieHeader: "c", xsrfToken: "x", isPrivate: true)

        #expect(result.callID == "ABC123")
        #expect(stub.requests.count == 5)
    }

    @Test func uploadStepSuccessFalseThrowsUnexpectedResponse() async throws {
        let json = #"{"callid": "ABC123", "success": false}"#
        let stub = QueuedHTTPUploading(results: [
            .success((Data(json.utf8), Self.response(status: 200)))
        ])
        let service = ChorusUploadService(session: stub)

        await #expect(throws: ChorusUploadError.self) {
            _ = try await service.upload(fileURL: try self.tempFileWithData(), title: "x", cookieHeader: "c", xsrfToken: "x", isPrivate: true)
        }
    }

    @Test func associateStepFailureStopsBeforeLaterSteps() async throws {
        let uploadJSON = #"{"callid": "ABC123", "success": true}"#
        let stub = QueuedHTTPUploading(results: [
            .success((Data(uploadJSON.utf8), Self.response(status: 200))),
            .success((Data(), Self.response(status: 500)))
        ])
        let service = ChorusUploadService(session: stub)

        await #expect(throws: ChorusUploadError.self) {
            _ = try await service.upload(fileURL: try self.tempFileWithData(), title: "x", cookieHeader: "c", xsrfToken: "x", isPrivate: true)
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
