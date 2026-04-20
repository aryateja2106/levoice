import AppKit
import SwiftUI

/// Owns the shortcut palette window lifecycle. Opens a single non-modal panel
/// that shows the frontmost app's keyboard shortcuts in a filterable list.
///
/// Kept out of `AppState` so the rest of the app doesn't need to import AppKit
/// just to know about this window.
@MainActor
final class ShortcutPaletteController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let viewModel = ShortcutPaletteViewModel()

    /// True when the palette window is currently visible on screen.
    var isVisible: Bool { window?.isVisible == true }

    /// Toggles the palette. Same hotkey opens and closes. Preferred over `show()`
    /// for global-hotkey callers because it matches muscle memory (press once to
    /// open, same press to dismiss) without interfering with app-level Escape.
    func toggle() {
        if isVisible {
            window?.orderOut(nil)
        } else {
            show()
        }
    }

    /// Shows the palette. If already visible, just brings it to the front and
    /// refreshes its shortcut capture (the frontmost app may have changed).
    func show() {
        viewModel.refresh()

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Shortcuts"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        window.contentView = NSHostingView(rootView: ShortcutPaletteView(viewModel: viewModel))

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Keep the window reference so reopening is fast — the AppKit cost of
        // recreating NSHostingView is non-trivial.
    }
}
