import AppKit
import SwiftUI

/// Settings in an AppKit-hosted window, so the menu, the Dock icon's menu and a
/// relaunch from Applications can all open it. SwiftUI's own Settings scene can
/// only be opened from inside a SwiftUI view, and with both the menu bar and Dock
/// icons hidden there is no such view to open it from.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()

    /// Set once at launch by the app, which owns the objects Settings shows.
    var makeContent: (() -> AnyView)?
    private var window: NSWindow?

    func show() {
        if window == nil, let makeContent {
            let hosting = NSHostingController(rootView: makeContent())
            // A fixed, screen-capped height with the Form scrolling inside it. Sizing
            // the window to the Form's full height crashed once the Form grew taller
            // than the screen: AppKit clamped the window, SwiftUI asked to grow again,
            // and AppKit aborted the endless update-constraints loop.
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.title = "NetworkToggle Settings"
            window.styleMask = [.titled, .closable, .resizable]
            let available = (NSScreen.main?.visibleFrame.height ?? 800) - 80
            window.setContentSize(NSSize(width: 460, height: min(760, available)))
            window.contentMinSize = NSSize(width: 460, height: 300)
            window.contentMaxSize = NSSize(width: 460, height: CGFloat.greatestFiniteMagnitude)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// The Dock icon's menu, and what happens when the app is opened again.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Runs a `networktoggle://` URL; set by NetworkToggleApp.init, which owns the model.
    static var onURL: ((URL) -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar app; it has a Dock icon only if the user turned one on.
        if AppPresence.showInDock { AppPresence.applyDock() }
    }

    /// The Dock icon's right-click menu, when "Show in Dock" is on.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        AppPresence.dockMenu(title: "Settings…", target: self, action: #selector(showSettings))
    }

    /// Clicking the Dock icon, or opening the app again from Applications or
    /// Spotlight, opens Settings — the way back when both icons are hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    @objc func showSettings() {
        SettingsWindow.shared.show()
    }

    /// `networktoggle://use-wired`, `move-connections`, `toggle-wifi` and `undo` (from
    /// ToolHUD, Shortcuts or a script) do what the menu does; anything else opens Settings.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "networktoggle" {
            switch url.host {
            case "use-wired", "move-connections", "toggle-wifi", "undo": Self.onURL?(url)
            default: showSettings()
            }
        }
    }
}
