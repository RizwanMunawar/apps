import AVFoundation
import AppCore
import AppKit
import SwiftUI

/// A plain `AVPlayerLayer` in an `NSViewRepresentable`, with our own controls.
///
/// Deliberately not SwiftUI's `VideoPlayer`: AVKit's SwiftUI wrapper crashes on launch inside a
/// SwiftUI-lifecycle app here, aborting in the runtime while it tries to build the metadata for
/// `AVPlayerView` ("failed to demangle superclass ... So12AVPlayerViewC"). Driving the layer
/// directly avoids AVKit entirely, and the playback surface is all this screen needs anyway.
struct VideoPlayerView: View {
    let url: URL
    let palette: Palette

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var observer: Any?

    var body: some View {
        ZStack(alignment: .bottom) {
            PlayerLayerView(player: player)
                .background(Color.black)

            if let player {
                controls(for: player)
            }
        }
        .onAppear { setUp() }
        .onDisappear { tearDown() }
        .onChange(of: url) { _, _ in
            tearDown()
            setUp()
        }
    }

    private func controls(for player: AVPlayer) -> some View {
        HStack(spacing: 14) {
            Button {
                if isPlaying { player.pause() } else {
                    // Restarting from the end is what a viewer expects from a play button on a
                    // finished clip, rather than nothing happening.
                    if player.currentTime() >= (player.currentItem?.duration ?? .zero) {
                        player.seek(to: .zero)
                    }
                    player.play()
                }
                isPlaying.toggle()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(AppFont.text(13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(.white.opacity(0.18)))
            }
            .buttonStyle(.plain)

            Button {
                player.seek(to: .zero)
                player.play()
                isPlaying = true
            } label: {
                Image(systemName: "gobackward")
                    .font(AppFont.text(12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help("Play from the start")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.45), in: Capsule())
        .padding(14)
    }

    private func setUp() {
        let player = AVPlayer(url: url)
        self.player = player
        observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
        ) { _ in isPlaying = false }
        player.play()
        isPlaying = true
    }

    private func tearDown() {
        player?.pause()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        player = nil
        isPlaying = false
    }
}

private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> LayerBackedView {
        let view = LayerBackedView()
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: LayerBackedView, context: Context) {
        nsView.playerLayer.player = player
    }

    final class LayerBackedView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.addSublayer(playerLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func layout() {
            super.layout()
            // The sublayer doesn't autoresize with the view, so keep it pinned by hand.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}
