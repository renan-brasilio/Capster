//
//  PlayerContainerView.swift
//  Capster
//

import AVKit
import SwiftUI

/// Wraps AVKit's `AVPlayerView` (not SwiftUI's `VideoPlayer`, which exposes no seek
/// tolerance or periodic time observation) so the timeline can drive playback and
/// scrubbing precisely from `EditorViewModel`. Transport controls are built in SwiftUI
/// instead of AVPlayerView's own, so `controlsStyle` is `.none`.
struct PlayerContainerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}
