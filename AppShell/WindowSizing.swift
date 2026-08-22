import AppKit
import SwiftUI

/// Pins the window's minimum size, and opens it at exactly that size the first time.
///
/// SwiftUI's own `.frame(minWidth:minHeight:)` on the root view turned out not to hold this
/// reliably: depending on what was in the saved state, the window either collapsed to a fraction
/// of the layout or restored far larger than asked. `NSWindow.minSize` is the property the window
/// server actually enforces when someone drags a corner, so it is set directly.
struct WindowSizing: NSViewRepresentable {
    let size: CGSize

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // There is no window at make time, and no single later moment that reliably has one, so
        // keep looking briefly and stop as soon as it appears.
        retry(from: view, attemptsLeft: 40)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(from: nsView)
    }

    private func retry(from view: NSView, attemptsLeft: Int) {
        guard attemptsLeft > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if view.window == nil {
                retry(from: view, attemptsLeft: attemptsLeft - 1)
            } else {
                apply(from: view)
            }
        }
    }

    private func apply(from view: NSView) {
        guard let window = view.window else { return }
        window.contentMinSize = size
        window.minSize = window.frameRect(forContentRect: CGRect(origin: .zero, size: size)).size

        // Only resize a window that is currently too small: growing it is the user's business,
        // and re-applying on every layout pass would fight them as they drag. A window restored
        // off the edge of the screen gets brought back at the same time.
        let frame = window.frame
        let content = window.contentRect(forFrameRect: frame).size
        let tooSmall = content.width < size.width - 1 || content.height < size.height - 1
        let offscreen = NSScreen.screens.allSatisfy { !$0.visibleFrame.intersects(frame) }

        if tooSmall {
            window.setContentSize(
                CGSize(width: max(content.width, size.width), height: max(content.height, size.height))
            )
        }
        if tooSmall || offscreen {
            window.center()
        }
    }
}
