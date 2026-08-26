//
//  PostProcessingCoordinatorTests.swift
//  CapsterTests
//

import Testing
import Foundation
@testable import Capster

@MainActor
struct PostProcessingCoordinatorTests {

    private func makeSettings() -> SettingsStore {
        let suiteName = "com.renanfamous.CapsterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return SettingsStore(defaults: defaults, keychain: InMemoryKeychainStub())
    }

    private func recordingURL() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
        FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: Data())
        return url
    }

    /// A signed-in `ChorusSessionService` backed by an in-memory Keychain stub.
    private func makeSignedInChorusSession() -> ChorusSessionService {
        let session = ChorusSessionService(keychain: InMemoryKeychainStub())
        session.save(cookieHeader: "session=test", xsrfToken: "test-xsrf")
        return session
    }

    @Test func neitherEnabledIsANoOp() async throws {
        let settings = makeSettings()
        let notifications = NotificationService(settings: settings)
        let coordinator = PostProcessingCoordinator(
            settings: settings, notificationService: notifications, chorusSession: makeSignedInChorusSession()
        )

        coordinator.start(recordingURL: recordingURL())
        await coordinator.waitUntilFinished()

        #expect(coordinator.transcodeState == .notNeeded)
        #expect(coordinator.uploadState == .notNeeded)
        #expect(coordinator.isRunning == false)
    }

    @Test func transcodeFailureStillRunsUploadAgainstOriginalFile() async throws {
        let settings = makeSettings()
        settings.handBrakeTranscodeEnabled = true
        settings.chorusUploadEnabled = true
        // No HandBrakeCLI located -> transcode step fails with .binaryNotConfigured.

        var receivedFileURL: URL?
        let uploadStub = RecordingUploadStub { url in receivedFileURL = url }
        let uploadService = ChorusUploadService(session: uploadStub)
        let notifications = NotificationService(settings: settings)
        let coordinator = PostProcessingCoordinator(
            settings: settings,
            notificationService: notifications,
            chorusSession: makeSignedInChorusSession(),
            uploadService: uploadService
        )

        let input = recordingURL()
        coordinator.start(recordingURL: input)
        await coordinator.waitUntilFinished()

        if case .failed = coordinator.transcodeState {} else {
            Issue.record("Expected transcode to fail without a configured binary")
        }
        #expect(receivedFileURL?.lastPathComponent == input.lastPathComponent)
    }

    @Test func deleteOriginalAfterTranscodeRemovesTheOriginalOnSuccess() async throws {
        let settings = makeSettings()
        settings.handBrakeTranscodeEnabled = true
        settings.deleteOriginalAfterTranscode = true

        let dummyBinary = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)-HandBrakeCLI")
        FileManager.default.createFile(atPath: dummyBinary.path(percentEncoded: false), contents: Data())
        defer { try? FileManager.default.removeItem(at: dummyBinary) }
        settings.setHandBrakeCLIURL(dummyBinary)

        let input = recordingURL()
        let expectedOutput = HandBrakeTranscodeService.outputURL(for: input)
        defer { try? FileManager.default.removeItem(at: expectedOutput) }

        let transcodeService = HandBrakeTranscodeService(processRunner: SucceedingTranscodeRunner(outputURL: expectedOutput))
        let notifications = NotificationService(settings: settings)
        let coordinator = PostProcessingCoordinator(
            settings: settings,
            notificationService: notifications,
            chorusSession: makeSignedInChorusSession(),
            transcodeService: transcodeService
        )

        coordinator.start(recordingURL: input)
        await coordinator.waitUntilFinished()

        #expect(coordinator.transcodeState == .succeeded)
        #expect(FileManager.default.fileExists(atPath: input.path(percentEncoded: false)) == false)
        #expect(FileManager.default.fileExists(atPath: expectedOutput.path(percentEncoded: false)) == true)
    }

    @Test func keepingOriginalAfterTranscodeLeavesItOnDisk() async throws {
        let settings = makeSettings()
        settings.handBrakeTranscodeEnabled = true
        settings.deleteOriginalAfterTranscode = false

        let dummyBinary = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)-HandBrakeCLI")
        FileManager.default.createFile(atPath: dummyBinary.path(percentEncoded: false), contents: Data())
        defer { try? FileManager.default.removeItem(at: dummyBinary) }
        settings.setHandBrakeCLIURL(dummyBinary)

        let input = recordingURL()
        defer { try? FileManager.default.removeItem(at: input) }
        let expectedOutput = HandBrakeTranscodeService.outputURL(for: input)
        defer { try? FileManager.default.removeItem(at: expectedOutput) }

        let transcodeService = HandBrakeTranscodeService(processRunner: SucceedingTranscodeRunner(outputURL: expectedOutput))
        let notifications = NotificationService(settings: settings)
        let coordinator = PostProcessingCoordinator(
            settings: settings,
            notificationService: notifications,
            chorusSession: makeSignedInChorusSession(),
            transcodeService: transcodeService
        )

        coordinator.start(recordingURL: input)
        await coordinator.waitUntilFinished()

        #expect(FileManager.default.fileExists(atPath: input.path(percentEncoded: false)) == true)
    }

    @Test func renamePromptRenamesFileOnDiskAndUploadsUnderNewName() async throws {
        let settings = makeSettings()
        settings.chorusUploadEnabled = true
        settings.chorusRenameBeforeUploadEnabled = true

        var receivedFileURL: URL?
        let uploadStub = RecordingUploadStub { url in receivedFileURL = url }
        let uploadService = ChorusUploadService(session: uploadStub)
        let notifications = NotificationService(settings: settings)
        let coordinator = PostProcessingCoordinator(
            settings: settings,
            notificationService: notifications,
            chorusSession: makeSignedInChorusSession(),
            uploadService: uploadService
        )

        let input = recordingURL()
        coordinator.start(recordingURL: input, formattedDuration: "1:23")

        while coordinator.renamePrompt == nil { await Task.yield() }
        #expect(coordinator.renamePrompt?.formattedDuration == "1:23")
        #expect(coordinator.renamePrompt?.destinationDirectory == input.deletingLastPathComponent())
        coordinator.submitRename("Client Demo")
        await coordinator.waitUntilFinished()

        #expect(receivedFileURL?.lastPathComponent == "Client Demo.mp4")
        #expect(FileManager.default.fileExists(atPath: input.path(percentEncoded: false)) == false)

        let renamedURL = input.deletingLastPathComponent().appending(path: "Client Demo.mp4")
        defer { try? FileManager.default.removeItem(at: renamedURL) }
        #expect(FileManager.default.fileExists(atPath: renamedURL.path(percentEncoded: false)) == true)
    }

    /// The rename happens before transcoding starts, so the same new name should carry
    /// through to the transcoded output too - not just the file that gets uploaded.
    @Test func renameAppliesBeforeTranscodeSoTheTranscodedFileSharesTheNewName() async throws {
        let settings = makeSettings()
        settings.handBrakeTranscodeEnabled = true
        settings.chorusUploadEnabled = true
        settings.chorusRenameBeforeUploadEnabled = true

        let dummyBinary = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)-HandBrakeCLI")
        FileManager.default.createFile(atPath: dummyBinary.path(percentEncoded: false), contents: Data())
        defer { try? FileManager.default.removeItem(at: dummyBinary) }
        settings.setHandBrakeCLIURL(dummyBinary)

        let newName = "Transcode Rename Test \(UUID().uuidString)"
        let input = recordingURL()
        let renamedInput = input.deletingLastPathComponent().appending(path: "\(newName).mp4")
        let expectedOutput = HandBrakeTranscodeService.outputURL(for: renamedInput)
        defer { try? FileManager.default.removeItem(at: expectedOutput) }

        var receivedFileURL: URL?
        var receivedTitle: String?
        let uploadStub = RecordingUploadStub(
            onUpload: { url in receivedFileURL = url },
            onSetTitle: { title in receivedTitle = title }
        )
        let uploadService = ChorusUploadService(session: uploadStub)
        let transcodeService = HandBrakeTranscodeService(processRunner: SucceedingTranscodeRunner(outputURL: expectedOutput))
        let notifications = NotificationService(settings: settings)
        let coordinator = PostProcessingCoordinator(
            settings: settings,
            notificationService: notifications,
            chorusSession: makeSignedInChorusSession(),
            transcodeService: transcodeService,
            uploadService: uploadService
        )

        coordinator.start(recordingURL: input)

        while coordinator.renamePrompt == nil { await Task.yield() }
        coordinator.submitRename(newName)
        await coordinator.waitUntilFinished()

        #expect(coordinator.transcodeState == .succeeded)
        #expect(FileManager.default.fileExists(atPath: expectedOutput.path(percentEncoded: false)) == true)
        // The uploaded file is the transcoded one (with the suffix)...
        #expect(receivedFileURL?.lastPathComponent == "\(newName) (Transcoded).mp4")
        // ...but the title Chorus shows should stay the clean recording name.
        #expect(receivedTitle == newName)
    }

    @Test func skippingTheRenamePromptUploadsUnderTheOriginalName() async throws {
        let settings = makeSettings()
        settings.chorusUploadEnabled = true
        settings.chorusRenameBeforeUploadEnabled = true

        var receivedFileURL: URL?
        let uploadStub = RecordingUploadStub { url in receivedFileURL = url }
        let uploadService = ChorusUploadService(session: uploadStub)
        let notifications = NotificationService(settings: settings)
        let coordinator = PostProcessingCoordinator(
            settings: settings,
            notificationService: notifications,
            chorusSession: makeSignedInChorusSession(),
            uploadService: uploadService
        )

        let input = recordingURL()
        defer { try? FileManager.default.removeItem(at: input) }
        coordinator.start(recordingURL: input)

        while coordinator.renamePrompt == nil { await Task.yield() }
        coordinator.submitRename(nil)
        await coordinator.waitUntilFinished()

        #expect(receivedFileURL?.lastPathComponent == input.lastPathComponent)
    }
}

/// Stubs a successful HandBrakeCLI run by writing the expected output file, mirroring
/// what the real binary would do, without shelling out to anything.
private final class SucceedingTranscodeRunner: ProcessRunning {
    private let outputURL: URL

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func run(executableURL: URL, arguments: [String], onOutputLine: @escaping (String) -> Void) async throws -> Int32 {
        FileManager.default.createFile(atPath: outputURL.path(percentEncoded: false), contents: Data())
        return 0
    }
}

/// Captures the file URL the Chorus multipart request was built from, by reading back
/// the `Content-Disposition` filename header - avoids needing a real network stack while
/// still exercising the real request-building code.
private final class RecordingUploadStub: HTTPUploading {
    private let onUpload: (URL) -> Void
    private let onSetTitle: (String) -> Void

    init(onUpload: @escaping (URL) -> Void, onSetTitle: @escaping (String) -> Void = { _ in }) {
        self.onUpload = onUpload
        self.onSetTitle = onSetTitle
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!

        guard let body = request.httpBody, let bodyString = String(data: body, encoding: .utf8) else {
            return (Data("{}".utf8), response)
        }

        if let filenameRange = bodyString.range(of: "filename=\"") {
            let rest = bodyString[filenameRange.upperBound...]
            if let endQuote = rest.firstIndex(of: "\"") {
                onUpload(URL(fileURLWithPath: String(rest[..<endQuote])))
            }
            // The real upload step's response is decoded strictly (callid/success), unlike
            // the later steps - a bare "{}" here would make the whole pipeline fail before
            // ever reaching associate/setTitle/access, regardless of what this test cares about.
            return (Data(#"{"callid": "TEST123", "success": true}"#.utf8), response)
        }

        // The setTitle step posts to .../v2/ with a form-encoded "value=<title>" pair.
        if request.url?.absoluteString == "https://chorus.ai/api/recording/v2/",
           let valueRange = bodyString.range(of: "value=") {
            let rawValue = bodyString[valueRange.upperBound...].split(separator: "&").first.map(String.init) ?? ""
            onSetTitle(rawValue.removingPercentEncoding ?? rawValue)
        }

        return (Data("{}".utf8), response)
    }
}
