//
//  CountdownOverlay.swift
//  Capster
//

import AppKit
import SwiftUI

/// A borderless panel covering a single screen for the numeric countdown. Accepts clicks
/// and key presses (rather than being click-through) so any of them can skip it - it only
/// covers the screen for a few seconds, unlike the Presenter Overlay prompt.
private final class CountdownPanel: NSPanel {
    var onSkip: (() -> Void)?

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        onSkip?()
    }

    override func mouseDown(with event: NSEvent) {
        onSkip?()
    }
}

/// A small, interactive floating panel for the "enable Presenter Overlay manually" prompt.
/// Unlike `CountdownPanel`, this must accept clicks for its Resume button - and must NOT
/// cover the whole screen, since the user needs to be able to click Control Center
/// (top-right of the menu bar) while it's showing. Shown together with
/// `PresenterOverlayScrimPanel` for the same full-screen darkened backdrop the countdown
/// uses, without this panel itself blocking clicks outside its own small bounds.
private final class PresenterOverlayPromptPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
}

/// A full-screen darkened backdrop shown behind `PresenterOverlayPromptPanel`, matching
/// `CountdownPanel`'s scrim so the two overlays read as the same visual family. Click-
/// through (`ignoresMouseEvents = true`) so it never blocks Control Center or anything
/// else on screen - only the small prompt panel on top of it is actually interactive.
private final class PresenterOverlayScrimPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = NSColor.black.withAlphaComponent(0.2)
        hasShadow = false
        level = .screenSaver
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
    }
}

/// Drives the number shown by the countdown overlay.
@MainActor
@Observable
final class CountdownState {
    var secondsRemaining: Int
    init(secondsRemaining: Int) {
        self.secondsRemaining = secondsRemaining
    }
}

/// Shows the pre-recording flow: an optional prompt asking the user to manually enable
/// Presenter Overlay (macOS gives apps no API to do this themselves), followed by an
/// optional full-screen numeric countdown, both before the capture actually begins.
@MainActor
final class CountdownOverlay {

    private var countdownPanel: CountdownPanel?
    private var promptPanel: PresenterOverlayPromptPanel?
    private var promptScrimPanel: PresenterOverlayScrimPanel?
    private var resumeContinuation: CheckedContinuation<Void, Never>?
    private var countdownTask: Task<Void, Never>?

    /// Shows a small prompt asking the user to enable Presenter Overlay via Control
    /// Center, over the same full-screen darkened backdrop the countdown uses, and
    /// suspends until they click Resume. The prompt itself stays small and positioned
    /// clear of Control Center; the backdrop is click-through, so neither blocks it.
    func waitForPresenterOverlayEnable(on screen: NSScreen) async {
        let scrim = PresenterOverlayScrimPanel(screen: screen)
        scrim.makeKeyAndOrderFront(nil)
        promptScrimPanel = scrim

        let width: CGFloat = 340
        let height: CGFloat = 260
        let origin = promptOrigin(width: width, height: height, screen: screen)
        let contentRect = CGRect(x: origin.x, y: origin.y, width: width, height: height)

        let panel = PresenterOverlayPromptPanel(contentRect: contentRect)
        panel.contentView = NSHostingView(rootView: PresenterOverlayPromptView { [weak self] in
            self?.resumeContinuation?.resume()
            self?.resumeContinuation = nil
        })

        panel.makeKeyAndOrderFront(nil)
        promptPanel = panel

        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }

        panel.orderOut(nil)
        promptPanel = nil
        scrim.orderOut(nil)
        promptScrimPanel = nil
    }

    /// Shows the numeric countdown on the given screen and suspends until it finishes or
    /// the user skips it (any key press or click).
    /// - Parameters:
    ///   - seconds: How many whole seconds to count down from.
    ///   - screen: The screen to display the countdown on.
    func runCountdown(seconds: Int, on screen: NSScreen) async {
        guard seconds > 0 else { return }

        let state = CountdownState(secondsRemaining: seconds)
        let panel = CountdownPanel(screen: screen)
        panel.contentView = NSHostingView(rootView: CountdownOverlayView(state: state))

        let task = Task { @MainActor in
            for remaining in stride(from: seconds, through: 1, by: -1) {
                if Task.isCancelled { return }
                state.secondsRemaining = remaining
                try? await Task.sleep(for: .seconds(1))
            }
        }
        countdownTask = task

        panel.onSkip = { task.cancel() }
        panel.makeKeyAndOrderFront(nil)
        countdownPanel = panel

        await task.value

        countdownPanel?.orderOut(nil)
        countdownPanel = nil
        countdownTask = nil
    }

    /// Dismisses whichever overlay is currently showing and releases anyone waiting on
    /// `waitForPresenterOverlayEnable`.
    func cancel() {
        resumeContinuation?.resume()
        resumeContinuation = nil
        promptPanel?.orderOut(nil)
        promptPanel = nil
        promptScrimPanel?.orderOut(nil)
        promptScrimPanel = nil
        countdownTask?.cancel()
        countdownTask = nil
        countdownPanel?.orderOut(nil)
        countdownPanel = nil
    }

    /// Places the prompt near the top-center of the screen, clear of Control Center in
    /// the top-right corner of the menu bar.
    private func promptOrigin(width: CGFloat, height: CGFloat, screen: NSScreen) -> CGPoint {
        let menuBarThickness = NSStatusBar.system.thickness
        let gap: CGFloat = 16
        let originX = screen.frame.midX - width / 2
        let originY = screen.frame.maxY - menuBarThickness - height - gap
        return CGPoint(x: originX, y: originY)
    }
}

// MARK: - Countdown View

private struct CountdownOverlayView: View {
    let state: CountdownState

    var body: some View {
        ZStack {
            Color.black.opacity(0.2)

            VStack(spacing: 12) {
                Text("\(state.secondsRemaining)")
                    .font(.system(size: 180, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 20)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.easeOut(duration: 0.3), value: state.secondsRemaining)

                Text("Recording starting, get ready")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 10)

                Text("Press any key or click to skip")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .shadow(color: .black.opacity(0.5), radius: 8)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Presenter Overlay Prompt View

private struct PresenterOverlayPromptView: View {
    let onResume: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.rectangle.badge.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 10)

            Text("Enable Presenter Overlay")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 10)

            Text("macOS doesn't allow apps to turn this on automatically. Open Control Center, enable Presenter Overlay, then click Resume.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .shadow(color: .black.opacity(0.5), radius: 8)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("Resume") {
                onResume()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 340)
    }
}
