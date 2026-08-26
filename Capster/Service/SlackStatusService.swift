//
//  SlackStatusService.swift
//  Capster
//

import Foundation
import OSLog

/// Sets/restores a Slack status and toggles Slack's own Do Not Disturb (separate from
/// macOS's) around a recording, via Slack's Web API.
///
/// Every method here is non-throwing and best-effort, like `DoNotDisturbService` - a
/// Slack API hiccup shouldn't block or fail a recording, just get logged.
final class SlackStatusService {
    struct PreviousStatus {
        let text: String
        let emoji: String
        let expiration: Int
    }

    private let session: HTTPUploading
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Capster", category: "SlackStatusService")

    init(session: HTTPUploading = URLSession.shared) {
        self.session = session
    }

    /// Fetches the user's current status, to restore afterward. Returns `nil` on any
    /// failure, in which case the caller should just clear the status instead of
    /// restoring it.
    func fetchCurrentStatus(accessToken: String) async -> PreviousStatus? {
        var request = URLRequest(url: URL(string: "https://slack.com/api/users.profile.get")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, _) = try await session.data(for: request)
            let decoded = try JSONDecoder().decode(ProfileGetResponse.self, from: data)
            guard decoded.ok, let profile = decoded.profile else {
                logger.error("Failed to fetch Slack status: \(decoded.error ?? "unknown error", privacy: .public)")
                return nil
            }
            return PreviousStatus(
                text: profile.statusText ?? "",
                emoji: profile.statusEmoji ?? "",
                expiration: profile.statusExpiration ?? 0
            )
        } catch {
            logger.error("Failed to fetch Slack status: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func setStatus(text: String, emoji: String, expiration: Int = 0, accessToken: String) async -> Bool {
        var request = URLRequest(url: URL(string: "https://slack.com/api/users.profile.set")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "profile": [
                "status_text": text,
                "status_emoji": emoji,
                "status_expiration": expiration
            ]
        ])

        return await performExpectingOK(request, action: "setting Slack status")
    }

    /// Whether the user already has an active manual Do Not Disturb snooze, checked
    /// before starting one - so a recording never turns off a snooze it didn't start.
    /// Returns `nil` on failure, in which case the caller should treat it as "already on"
    /// and leave DND alone entirely, rather than risk ending someone else's snooze.
    func fetchDoNotDisturbSnoozeActive(accessToken: String) async -> Bool? {
        var request = URLRequest(url: URL(string: "https://slack.com/api/dnd.info")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, _) = try await session.data(for: request)
            let decoded = try JSONDecoder().decode(DoNotDisturbInfoResponse.self, from: data)
            guard decoded.ok else {
                logger.error("Failed to fetch Slack Do Not Disturb state: \(decoded.error ?? "unknown error", privacy: .public)")
                return nil
            }
            return decoded.snoozeEnabled ?? false
        } catch {
            logger.error("Failed to fetch Slack Do Not Disturb state: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func startDoNotDisturb(minutes: Int, accessToken: String) async -> Bool {
        var request = URLRequest(url: URL(string: "https://slack.com/api/dnd.setSnooze")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["num_minutes": minutes])

        return await performExpectingOK(request, action: "starting Slack Do Not Disturb")
    }

    @discardableResult
    func endDoNotDisturb(accessToken: String) async -> Bool {
        var request = URLRequest(url: URL(string: "https://slack.com/api/dnd.endSnooze")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        return await performExpectingOK(request, action: "ending Slack Do Not Disturb")
    }

    private func performExpectingOK(_ request: URLRequest, action: String) async -> Bool {
        do {
            let (data, _) = try await session.data(for: request)
            let decoded = try JSONDecoder().decode(SlackAPIResponse.self, from: data)
            if !decoded.ok {
                logger.error("Failed \(action, privacy: .public): \(decoded.error ?? "unknown error", privacy: .public)")
            }
            return decoded.ok
        } catch {
            logger.error("Failed \(action, privacy: .public): \(error.localizedDescription)")
            return false
        }
    }
}

private struct SlackAPIResponse: Decodable {
    let ok: Bool
    let error: String?
}

private struct DoNotDisturbInfoResponse: Decodable {
    let ok: Bool
    let error: String?
    let snoozeEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case ok, error
        case snoozeEnabled = "snooze_enabled"
    }
}

private struct ProfileGetResponse: Decodable {
    let ok: Bool
    let error: String?
    let profile: Profile?

    struct Profile: Decodable {
        let statusText: String?
        let statusEmoji: String?
        let statusExpiration: Int?

        enum CodingKeys: String, CodingKey {
            case statusText = "status_text"
            case statusEmoji = "status_emoji"
            case statusExpiration = "status_expiration"
        }
    }
}
