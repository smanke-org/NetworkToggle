import AppKit
import SwiftUI

/// Settings in an AppKit-hosted window, so the menu, the Dock icon's menu and a
/// relaunch from Applications can all open it. SwiftUI's own Settings scene can
/// only be opened from inside a SwiftUI view, and with both the menu bar and Dock
/// icons hidden there is no such view to open it from.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()

    /// The width the form is laid out for, and the narrowest the window can be dragged to.
    static let width: CGFloat = 460
    static let minimumSize = NSSize(width: width, height: 280)

    /// The content size the user last dragged the window to (per Mac, not synced), or nil
    /// while they haven't: then it opens at the form's own height.
    static var chosenSize: NSSize? {
        get { UserDefaults.standard.string(forKey: "settings.contentSize").map(NSSizeFromString) }
        set { UserDefaults.standard.set(newValue.map(NSStringFromSize), forKey: "settings.contentSize") }
    }

    /// Set once at launch by the app, which owns the objects Settings shows.
    var makeContent: (() -> AnyView)?
    private var window: NSWindow?

    func show() {
        if window == nil, let makeContent {
            let content = makeContent()
            // The Form's natural height (measured at the form's width), capped to the
            // screen, with the Form scrolling inside. Sizing the window to the Form's full
            // height crashed once the Form grew taller than the screen: AppKit clamped the
            // window, SwiftUI asked to grow again, and AppKit aborted the endless
            // update-constraints loop. It fills whatever size the user drags the window to.
            let natural = NSHostingView(rootView: content.frame(width: Self.width)).fittingSize.height
            let hosting = NSHostingController(rootView: content.frame(minWidth: Self.width, maxWidth: .infinity,
                                                                      maxHeight: .infinity))
            hosting.sizingOptions = []
            // Inside a plain container, so SwiftUI doesn't manage the window's size limits
            // (as the window's own content controller it cleared the minimum size whenever a
            // sheet came and went).
            let container = NSViewController()
            container.view = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 400))
            container.addChild(hosting)
            hosting.view.frame = container.view.bounds
            hosting.view.autoresizingMask = [.width, .height]
            container.view.addSubview(hosting.view)
            let window = NSWindow(contentViewController: container)
            window.title = "NetworkToggle Settings"
            // Resizable as well as scrolling: drag it bigger to see more at once.
            window.styleMask = [.titled, .closable, .resizable]
            let available = (NSScreen.main?.visibleFrame.height ?? 800) - 80
            var size = NSSize(width: Self.width, height: min(max(natural, Self.minimumSize.height), available))
            if let chosen = Self.chosenSize {
                size = NSSize(width: max(chosen.width, Self.minimumSize.width),
                              height: min(max(chosen.height, Self.minimumSize.height), available))
            }
            window.setContentSize(size)
            window.contentMinSize = Self.minimumSize
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // After an update whose notes weren't seen yet.
        if let window { WhatsNew.shared.present(on: window) }
    }

    /// This version's release notes, when asked for from Settings.
    func showWhatsNew() {
        if let window { WhatsNew.shared.present(on: window, asked: true) }
    }

    /// A size the user dragged to is kept, and used next time.
    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window else { return }
        Self.chosenSize = window.contentRect(forFrameRect: window.frame).size
    }

    #if DEBUG
    var debugWindow: NSWindow? { window }
    #endif
}

/// Quits NetworkToggle without asking: for quitting itself (installing an update, ending a test).
@MainActor
enum QuitConfirmation {
    private(set) static var confirmed = false

    static func quitNow() {
        confirmed = true
        NSApp.terminate(nil)
    }
}

/// The Dock icon's menu, and what happens when the app is opened again.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Runs a `networktoggle://` URL; set by NetworkToggleApp.init, which owns the model.
    static var onURL: ((URL) -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // An agent CLI test copy (APP_STORE) runs with no Dock icon or menu bar item at all.
        if AgentSocket.isTestRun {
            NSApp.setActivationPolicy(.prohibited)
            return
        }
        if let snapshot = ProcessInfo.processInfo.environment["NETWORKTOGGLE_DEBUG_HELP_TEST"] {
            DebugHelpTest.run(snapshot: snapshot, delegate: nil)
            return
        }
        if let how = ProcessInfo.processInfo.environment["NETWORKTOGGLE_DEBUG_QUIT_TEST"] {
            DebugQuitTest.run(how)
            return
        }
        // The update prompt, What's New and Settings drawn to PNGs; starts nothing else.
        if let folder = ProcessInfo.processInfo.environment["NETWORKTOGGLE_DEBUG_UPDATE_NOTES"] {
            DebugUpdateNotes.run(folder: folder)
            return
        }
        #endif
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

    /// Quitting asks first, while "Ask before quitting" is on in Settings › General. Not when
    /// the Mac is logging out, restarting or shutting down (macOS gives the quit a reason
    /// then), and not when NetworkToggle quits itself to install an update.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let systemQuit = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
        guard AppSettings.shared.confirmQuit, !QuitConfirmation.confirmed, !systemQuit else { return .terminateNow }

        // A menu bar app needs to be a regular one for the alert to come to the front; the
        // old policy goes back a runloop turn later, once the alert is gone (AppKit ignores
        // it while the modal still holds the app active).
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { DispatchQueue.main.async { NSApp.setActivationPolicy(previousPolicy) } }

        let alert = NSAlert()
        alert.messageText = "Quit \(AppInfo.name)?"
        alert.informativeText = "Automatic switching and wired-connection offers stop until you open \(AppInfo.name) again."
        // NSAlert puts a Cancel button on Esc, and Quit has no key, so Return does nothing:
        // quitting takes a click on Quit, never a stray keystroke.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit").keyEquivalent = ""
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        UpdateController.bringForward(alert)

        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        if alert.suppressionButton?.state == .on { AppSettings.shared.confirmQuit = false }
        return .terminateNow
    }

    /// `networktoggle://use-wired`, `move-connections`, `toggle-wifi` and `undo` (from
    /// ToolHUD, Shortcuts or a script) do what the menu does, and `panel` opens the menu's
    /// panel as a window; anything else opens Settings.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "networktoggle" {
            switch url.host {
            case "use-wired", "move-connections", "toggle-wifi", "undo", "panel": Self.onURL?(url)
            default: showSettings()
            }
        }
    }
}
