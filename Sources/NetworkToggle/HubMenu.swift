import AppKit
import SwiftUI

/// NetworkToggle's menu for ToolHUD's menu hub (see `MenuHub`). The menu bar item here is a
/// panel, which can't travel as a menu, so this offers the panel's main actions and a way to
/// the panel itself, opened as a floating window under ToolHUD's icon.
@MainActor
final class HubMenu: NSObject {
    private let model: AppModel
    private var panel: NSPanel?
    private var resignObserver: NSObjectProtocol?
    /// Clicks in other apps close the panel even if it never became key.
    private var clickMonitor: Any?

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        MenuHub.shared.start(menu: { self.build() }, icon: { MenuBarLabel.image(for: self.model.monitor) })
    }

    private var monitor: NetworkMonitor { model.monitor }
    private var controller: SwitchController { model.controller }

    private func build() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let primary = monitor.primary {
            menu.addItem(disabled: "Network: \(primary.name)")
            if let vpn = monitor.vpn { menu.addItem(disabled: "Through \(vpn.name)") }
        } else {
            menu.addItem(disabled: "No network connection")
        }
        menu.addItem(.separator())

        if let target = monitor.idleWired.first {
            // A switch that would cut off a full-tunnel VPN asks first, and that question
            // lives in the panel.
            let ask = interruptsVPN(target)
            menu.addItem(withTitle: "Switch to \(target.name)\(ask ? "…" : "")",
                         action: ask ? #selector(showPanel) : #selector(switchToWired), target: self)
            menu.addItem(withTitle: "Switch and Force Reconnect\(ask ? "…" : "")",
                         action: ask ? #selector(showPanel) : #selector(switchToWiredForcing), target: self)
                .toolTip = "Holds Wi-Fi off until open connections move, then turns it back on."
        } else {
            menu.addItem(disabled: "No idle wired connection")
        }
        // Connections opened before a wired link took over stay on Wi-Fi. The panel names them,
        // but its icon is hidden while ToolHUD hosts this menu, so the way to move them has to
        // be here too.
        if let active = monitor.vpnCarrier ?? monitor.primary, !active.service.isWiFi,
           let wifi = monitor.wiFi, wifi.linkUp, wifi.ipv4 != nil, model.helper.state.isReady {
            menu.addItem(withTitle: "Move Connections to \(active.name)", action: #selector(moveConnections), target: self)
                .toolTip = "Turns Wi-Fi off until connections still on it reconnect over \(active.name), then turns it back on."
        }
        if let wifi = monitor.wiFi, model.helper.state.isReady {
            menu.addItem(withTitle: wifi.linkUp ? "Turn Wi-Fi Off" : "Turn Wi-Fi On", action: #selector(toggleWiFi), target: self)
        }
        if controller.undoableOrder != nil {
            menu.addItem(withTitle: "Undo Last Change", action: #selector(undo), target: self)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show Connections…", action: #selector(showPanel), target: self)
        menu.addItem(.separator())

        if let staged = AutoUpdater.shared.staged {
            menu.addItem(withTitle: "Update to \(staged.version) Now", action: #selector(installUpdate), target: self)
        } else if let pending = UpdateAvailability.shared.pending {
            menu.addItem(withTitle: "Update to \(pending)…", action: #selector(checkForUpdates), target: self)
        } else {
            menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), target: self)
        }
        menu.addItem(withTitle: "NetworkToggle Help", action: #selector(showHelp), target: self)
            .image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(showSettings), target: self)
        settings.keyEquivalent = ","
        menu.addItem(withTitle: "About NetworkToggle", action: #selector(showAbout), target: self)
        menu.addItem(withTitle: "Our other apps…", action: #selector(showOtherApps), target: self)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit NetworkToggle", action: #selector(quit), target: self)
        menu.addItem(.separator())
        menu.addItem(disabled: "\(AppInfo.name) \(AppInfo.displayVersion)")
        return menu
    }

    /// The panel's own rule: moving traffic off the link a full-tunnel VPN rides on.
    private func interruptsVPN(_ target: ServiceStatus) -> Bool {
        guard let vpn = monitor.vpn, vpn.isPrimary, let carrier = vpn.carrierBSDName else { return false }
        return target.bsdName != carrier
    }

    // MARK: - Actions

    @objc private func switchToWired() { switchWired(force: false) }
    @objc private func switchToWiredForcing() { switchWired(force: true) }

    private func switchWired(force: Bool) {
        guard let target = monitor.idleWired.first else { return }
        Task { await controller.switchTo(target, force: force) }
    }

    @objc private func moveConnections() { Task { await controller.moveConnectionsToActive() } }

    @objc private func toggleWiFi() {
        guard let wifi = monitor.wiFi else { return }
        Task { await controller.toggleWiFi(on: !wifi.linkUp) }
    }

    @objc private func undo() { Task { await controller.undo() } }
    @objc private func installUpdate() { AutoUpdater.shared.installNow() }
    @objc private func checkForUpdates() { UpdateController.checkForUpdates() }
    @objc private func showHelp() { HelpWindow.shared.show() }
    @objc private func showSettings() { SettingsWindow.shared.show() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func showOtherApps() {
        if let url = URL(string: "https://stevemanke.com/") { NSWorkspace.shared.open(url) }
    }

    /// The menu bar panel's contents in a floating window just below the menu bar, where the
    /// pointer is (under ToolHUD's icon). It closes when it loses focus, as the panel does.
    /// Also `networktoggle://panel`.
    @objc func showPanel() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let content = MenuContentView(monitor: model.monitor, helper: model.helper, controller: model.controller,
                                      meter: model.meter, strandedMonitor: model.strandedMonitor,
                                      strandedMeter: model.strandedMeter, onAppear: { [model] in model.refreshHelperState() })
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = .preferredContentSize
        let panel = HubPanel(contentViewController: hosting)
        panel.styleMask = [.titled, .closable, .fullSizeContentView]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.layoutIfNeeded()

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let width = panel.frame.width
            let x = min(max(mouse.x - width / 2, visible.minX + 8), visible.maxX - width - 8)
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: visible.maxY - 4))
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated { [weak self] in self?.closePanel() }
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            MainActor.assumeIsolated { [weak self] in self?.closePanel() }
        }
        panel.onCancel = { [weak self] in self?.closePanel() }
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func closePanel() {
        guard let panel else { return }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        self.panel = nil
        panel.close()
        // Like the menu bar panel, give focus back to the app that had it.
        if NSApp.isActive, !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeKey }) { NSApp.hide(nil) }
    }
}

/// Escape closes it, as it does the menu bar panel.
private final class HubPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

private extension NSMenu {
    @discardableResult
    func addItem(withTitle title: String, action: Selector, target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        addItem(item)
        return item
    }

    func addItem(disabled title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
    }
}
