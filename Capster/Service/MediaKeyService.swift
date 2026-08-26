//
//  MediaKeyService.swift
//  Capster
//

import AppKit

/// Sends the system-wide Play/Pause media key - the same HID event a keyboard's media key
/// sends. Whatever app currently owns "Now Playing" (Music, Spotify, a browser tab, etc.)
/// responds to it directly, with no per-app integration needed.
enum MediaKeyService {

    /// `NX_KEYTYPE_PLAY` from IOKit's private `hidsystem/ev_keymap.h` - hardcoded since that
    /// header isn't importable from Swift, but the value has been stable across macOS
    /// releases and is the same constant every "simulate a media key" utility uses.
    private static let playPauseKeyCode: Int32 = 16

    /// Toggles play/pause on whatever's currently playing. There's no separate "pause only"
    /// system key - like a real hardware media key, this does nothing if nothing is
    /// playing, and resumes rather than pauses if playback happens to already be paused.
    static func togglePlayPause() {
        postMediaKeyEvent(keyDown: true)
        postMediaKeyEvent(keyDown: false)
    }

    private static func postMediaKeyEvent(keyDown: Bool) {
        let flags = keyDown ? 0xa00 : 0xb00
        let data1 = Int((playPauseKeyCode << 16) | Int32(flags))

        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        )

        event?.cgEvent?.post(tap: .cghidEventTap)
    }
}
