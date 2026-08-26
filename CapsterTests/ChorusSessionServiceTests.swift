//
//  ChorusSessionServiceTests.swift
//  CapsterTests
//

import Testing
import Foundation
@testable import Capster

@MainActor
struct ChorusSessionServiceTests {

    @Test func startsSignedOutWithNoStoredSession() {
        let service = ChorusSessionService(keychain: InMemoryKeychainStub())
        #expect(service.isSignedIn == false)
        #expect(service.cookieHeader == nil)
        #expect(service.xsrfToken == nil)
    }

    @Test func savingSessionMarksSignedInAndRoundTripsThroughKeychain() {
        let service = ChorusSessionService(keychain: InMemoryKeychainStub())

        service.save(cookieHeader: "session=abc; _xsrf=tok", xsrfToken: "tok")

        #expect(service.isSignedIn == true)
        #expect(service.cookieHeader == "session=abc; _xsrf=tok")
        #expect(service.xsrfToken == "tok")
    }

    @Test func signOutClearsStoredSession() {
        let service = ChorusSessionService(keychain: InMemoryKeychainStub())
        service.save(cookieHeader: "session=abc", xsrfToken: "tok")

        service.signOut()

        #expect(service.isSignedIn == false)
        #expect(service.cookieHeader == nil)
        #expect(service.xsrfToken == nil)
    }

    @Test func reloadsSignedInStateFromExistingKeychainData() {
        let keychain = InMemoryKeychainStub()
        let first = ChorusSessionService(keychain: keychain)
        first.save(cookieHeader: "session=abc", xsrfToken: "tok")

        let second = ChorusSessionService(keychain: keychain)
        #expect(second.isSignedIn == true)
        #expect(second.cookieHeader == "session=abc")
    }
}
