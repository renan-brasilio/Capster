//
//  ChorusLoginView.swift
//  Capster
//

import AppKit
import SwiftUI
@preconcurrency import WebKit

/// Embeds a real Chorus login page and captures the resulting session once the user
/// signs in, rather than asking for an API token most users can't generate themselves.
///
/// Chorus is a single-page app, so a successful login doesn't necessarily trigger a
/// full page navigation - the cookie store is polled on a timer instead of relying on
/// `WKNavigationDelegate` callbacks, which is what actually catches the session cookie
/// appearing.
struct ChorusLoginView: NSViewRepresentable {
    let onSessionCaptured: (_ cookieHeader: String, _ xsrfToken: String) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        // Google refuses to sign in inside a WebView it can identify as embedded (an
        // anti-phishing measure), which blocks "Sign in with Google" for anyone whose
        // Chorus login goes through Google SSO. Presenting as a real desktop Safari
        // gets past that signature-based check in most cases.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        webView.uiDelegate = context.coordinator
        webView.load(URLRequest(url: URL(string: "https://chorus.ai/login")!))
        context.coordinator.startPolling(webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onSessionCaptured: onSessionCaptured)
    }

    @MainActor
    final class Coordinator: NSObject, WKUIDelegate {
        private let onSessionCaptured: (String, String) -> Void
        private var timer: Timer?
        private var didCapture = false

        /// SSO (e.g. Google) opens its login flow via `window.open()`, which a plain
        /// `WKWebView` silently drops unless a `uiDelegate` handles it - each popup gets
        /// its own window here, kept alive in this array for as long as it's open.
        private var popupWindows: [NSWindow] = []

        init(onSessionCaptured: @escaping (String, String) -> Void) {
            self.onSessionCaptured = onSessionCaptured
        }

        func startPolling(_ webView: WKWebView) {
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self, weak webView] _ in
                guard let self, let webView, !self.didCapture else { return }
                Task { @MainActor in self.checkForSession(webView) }
            }
        }

        private func checkForSession(_ webView: WKWebView) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self, !self.didCapture else { return }

                let chorusCookies = cookies.filter { $0.domain.contains("chorus.ai") }
                guard chorusCookies.contains(where: { $0.name == "session" }),
                    let xsrfCookie = chorusCookies.first(where: { $0.name == "_xsrf" })
                else { return }

                self.didCapture = true
                self.timer?.invalidate()
                self.timer = nil

                let cookieHeader = chorusCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                self.onSessionCaptured(cookieHeader, xsrfCookie.value)
            }
        }

        // MARK: - WKUIDelegate (popup handling)

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // Reuses `configuration`, not a fresh one, so the popup shares the parent's
            // process pool and cookie store - the SSO session it establishes is visible
            // to the cookie polling happening on the original web view.
            let popupWebView = WKWebView(frame: .zero, configuration: configuration)
            popupWebView.uiDelegate = self
            popupWebView.customUserAgent = webView.customUserAgent

            let width = windowFeatures.width?.doubleValue ?? 480
            let height = windowFeatures.height?.doubleValue ?? 640
            let popupWindow = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: width, height: height),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            popupWindow.title = "Sign in"
            // `.close()`'s fade-out animation racing the WKWebView's own teardown as
            // Google's popup closes itself is a reliable SIGSEGV
            // (`_NSWindowTransformAnimation dealloc` mid-flight) - use `orderOut(nil)`
            // instead for exactly this reason.
            popupWindow.animationBehavior = .none
            popupWindow.isReleasedWhenClosed = false
            popupWindow.contentView = popupWebView
            popupWindow.center()
            popupWindow.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)

            popupWindows.append(popupWindow)
            return popupWebView
        }

        /// The popup calls `window.close()` itself once its flow finishes (success or
        /// cancel) - this is what actually closes our window for it.
        func webViewDidClose(_ webView: WKWebView) {
            popupWindows.removeAll { window in
                guard window.contentView === webView else { return false }
                window.orderOut(nil)
                return true
            }
        }

        deinit {
            timer?.invalidate()
        }
    }
}

/// A window hosting `ChorusLoginView`, dismissed automatically once a session is captured.
@MainActor
final class ChorusLoginWindowCoordinator {
    private var window: NSWindow?

    /// Shows the login window, or brings an already-visible one to front.
    func show(sessionService: ChorusSessionService) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let newWindow = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 480, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Sign in to Chorus"
        newWindow.animationBehavior = .none
        newWindow.isReleasedWhenClosed = false

        let view = ChorusLoginView { [weak self] cookieHeader, xsrfToken in
            Task { @MainActor in
                sessionService.save(cookieHeader: cookieHeader, xsrfToken: xsrfToken)
                self?.dismiss()
            }
        }
        newWindow.contentView = NSHostingView(rootView: view)
        newWindow.center()

        newWindow.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window = newWindow
    }

    func dismiss() {
        window?.orderOut(nil)
        window = nil
    }
}
