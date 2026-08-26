//
//  ChorusUploadService.swift
//  Capster
//

import Foundation
import OSLog

enum ChorusUploadError: LocalizedError {
    case notSignedIn
    case requestBuildFailed(Error)
    case networkError(Error)
    case httpError(step: String, statusCode: Int, message: String?)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Not signed in to Chorus. Sign in from Settings > Automation."
        case .requestBuildFailed(let error):
            return "Failed to build the Chorus upload request: \(error.localizedDescription)"
        case .networkError(let error):
            return "Network error while uploading to Chorus: \(error.localizedDescription)"
        case .httpError(let step, let statusCode, let message):
            return "Chorus (\(step)) returned HTTP \(statusCode)\(message.map { ": \($0)" } ?? "")"
        case .unexpectedResponse:
            return "Chorus's upload response didn't include the expected recording ID."
        }
    }
}

/// Abstracts the network call so tests can stub responses without hitting a real
/// network or requiring a real Chorus session.
protocol HTTPUploading {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPUploading {}

struct ChorusUploadResult {
    /// Chorus's identifier for the created recording.
    let callID: String
}

// MARK: - Request contract, captured 2026-08-26 from a real Chorus account via the
// browser's DevTools Network tab while using the "Import a Recording" feature under
// Chorus > Settings > Personal Settings. This is Chorus's own internal web-app
// endpoint, not the documented public REST API (`api-docs.chorus.ai`) - used because
// most users don't have the role permission needed to generate an API token for that
// one. Auth is the session `Cookie` header plus an `X-Xsrftoken` header, both captured
// by `ChorusLoginView`'s embedded login flow and held by `ChorusSessionService`.
// `X-Xsrftoken` is just the value of the `_xsrf` cookie echoed back as a header - a
// standard double-submit CSRF pattern (Tornado's default cookie name, suggesting
// Chorus's backend is Tornado-based).
//
// Three sequential calls, confirmed against real responses:
//   1. POST /api/recording/upload/          multipart, field "file"
//        -> {"callid": "...", "account_id": null, "success": true}
//   2. PATCH /api/recording/access/{callid}  JSON {"is_private": <bool>}
//   3. POST /api/recording/v2                form-urlencoded:
//        callid=<callid>&ext_id=&ext_name=&ext_type=
//      (CRM/meeting association fields - left blank since Capster has no CRM context
//      to offer; Chorus pre-fills these from other signals when a real user does it
//      through the UI.)
//
// Unlike the documented API, no response ever exposes a viewable link for the
// recording, so `ChorusUploadResult` only carries the call ID.

private enum ChorusEndpoint {
    static let upload = URL(string: "https://chorus.ai/api/recording/upload/")!
    static let v2 = URL(string: "https://chorus.ai/api/recording/v2")!

    static func access(callID: String) -> URL {
        URL(string: "https://chorus.ai/api/recording/access/\(callID)")!
    }
}

private struct ChorusUploadResponse: Decodable {
    let callid: String
    let success: Bool
}

final class ChorusUploadService {
    private let session: HTTPUploading
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Capster", category: "ChorusUploadService")

    init(session: HTTPUploading = URLSession.shared) {
        self.session = session
    }

    func upload(fileURL: URL, cookieHeader: String, xsrfToken: String, isPrivate: Bool) async throws -> ChorusUploadResult {
        guard !cookieHeader.isEmpty, !xsrfToken.isEmpty else { throw ChorusUploadError.notSignedIn }

        let callID = try await uploadFile(fileURL: fileURL, cookieHeader: cookieHeader, xsrfToken: xsrfToken)
        // Privacy is set last, after association - if associating with a record pulls in
        // that record's own default sharing, doing it first would clobber an explicit
        // privacy choice made here.
        try await associate(callID: callID, cookieHeader: cookieHeader, xsrfToken: xsrfToken)
        try await setPrivacy(callID: callID, isPrivate: isPrivate, cookieHeader: cookieHeader, xsrfToken: xsrfToken)

        logger.info("Chorus upload succeeded, callid: \(callID)")
        return ChorusUploadResult(callID: callID)
    }

    // MARK: - Steps

    private func uploadFile(fileURL: URL, cookieHeader: String, xsrfToken: String) async throws -> String {
        let fileData: Data
        do {
            fileData = try Data(contentsOf: fileURL)
        } catch {
            throw ChorusUploadError.requestBuildFailed(error)
        }

        var request = URLRequest(url: ChorusEndpoint.upload)
        request.httpMethod = "POST"
        applyAuthHeaders(cookieHeader: cookieHeader, xsrfToken: xsrfToken, to: &request)

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func append(_ string: String) { body.append(string.data(using: .utf8) ?? Data()) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n")
        append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n")
        request.httpBody = body

        let data = try await performExpectingSuccess(request, step: "upload")
        guard let decoded = try? JSONDecoder().decode(ChorusUploadResponse.self, from: data), decoded.success else {
            throw ChorusUploadError.unexpectedResponse
        }
        return decoded.callid
    }

    private func setPrivacy(callID: String, isPrivate: Bool, cookieHeader: String, xsrfToken: String) async throws {
        var request = URLRequest(url: ChorusEndpoint.access(callID: callID))
        request.httpMethod = "PATCH"
        applyAuthHeaders(cookieHeader: cookieHeader, xsrfToken: xsrfToken, to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["is_private": isPrivate])

        // Also retries a 500 here (unlike the other steps) - observed in practice on this
        // endpoint specifically, with the same "still settling" timing as the 404 case below.
        let data = try await performExpectingSuccess(request, step: "access", retryCount: 4, retryableStatusCodes: [404, 500])
        logger.info("Chorus access step response: \(String(data: data, encoding: .utf8) ?? "<empty>", privacy: .public)")
    }

    private func associate(callID: String, cookieHeader: String, xsrfToken: String) async throws {
        var request = URLRequest(url: ChorusEndpoint.v2)
        request.httpMethod = "POST"
        applyAuthHeaders(cookieHeader: cookieHeader, xsrfToken: xsrfToken, to: &request)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "callid", value: callID),
            URLQueryItem(name: "ext_id", value: ""),
            URLQueryItem(name: "ext_name", value: ""),
            URLQueryItem(name: "ext_type", value: "")
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        _ = try await performExpectingSuccess(request, step: "associate", retryCount: 4)
    }

    // MARK: - Helpers

    /// Beyond the session itself, matches header fields observed on the real browser
    /// request that our request otherwise omits - `X-Al-Version` in particular looks
    /// like a version-routing header, and its absence could plausibly cause a literal
    /// 404 (no matching route) rather than a 401/403 if Chorus's gateway routes on it.
    private func applyAuthHeaders(cookieHeader: String, xsrfToken: String, to request: inout URLRequest) {
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(xsrfToken, forHTTPHeaderField: "X-Xsrftoken")
        request.setValue("https://chorus.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://chorus.ai/settings/personal-settings", forHTTPHeaderField: "Referer")
        request.setValue("2019-09-01", forHTTPHeaderField: "X-Al-Version")
    }

    /// `retryCount` retries a status in `retryableStatusCodes` with backoff before giving
    /// up - Chorus's backend appears to need a moment after `/upload/` responds before the
    /// new `callid` is queryable by the follow-up calls, which otherwise fail instantly
    /// (404 on most steps; 500 has also been observed on the access step specifically). The
    /// initial upload step itself doesn't have this issue, so it passes 0 (no retry).
    private func performExpectingSuccess(
        _ request: URLRequest,
        step: String,
        retryCount: Int = 0,
        retryableStatusCodes: Set<Int> = [404]
    ) async throws -> Data {
        var attempt = 0

        while true {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw ChorusUploadError.networkError(error)
            }

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            if (200..<300).contains(statusCode) {
                return data
            }

            if retryableStatusCodes.contains(statusCode), attempt < retryCount {
                attempt += 1
                logger.info("Chorus \(step, privacy: .public) returned HTTP \(statusCode), retrying (\(attempt)/\(retryCount)) - likely still processing the upload")
                try? await Task.sleep(for: .seconds(Double(attempt)))
                continue
            }

            logger.error("Chorus \(step, privacy: .public) failed: HTTP \(statusCode) at \(request.url?.absoluteString ?? "?", privacy: .public)")
            throw ChorusUploadError.httpError(step: step, statusCode: statusCode, message: String(data: data, encoding: .utf8))
        }
    }
}
