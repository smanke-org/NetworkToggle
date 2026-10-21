import SwiftUI
import NetworkToggleKit

@main
struct NetworkToggleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    @State private var settings = AppSettings.shared
    @State private var hub = MenuHub.shared

    init() {
        // Before anything saves a setting: an empty domain means a brand-new install.
        let newInstall = SettingsSync.domainIsEmpty()
        let model = AppModel()
        #if DEBUG
        // A Help test run shares the installed app's settings and helper, so it starts
        // nothing else: no sync, no updates, no switching.
        if ProcessInfo.processInfo.environment["NETWORKTOGGLE_DEBUG_HELP_TEST"] != nil {
            _model = State(initialValue: model)
            return
        }
        #endif
        // An automatic update restarts the app and its helper; never mid-switch.
        AutoUpdater.shared.appBusyReason = {
            if let busy = model.controller.busyMessage { return "busy: \(busy)" }
            if model.notifier.isOffering { return "a switch offer is waiting for an answer" }
            return nil
        }
        SettingsSync.shared.onApply = { AppSettings.shared.reload() }
        // NSApp exists only once the app has started.
        DispatchQueue.main.async { AppAppearance.start() }
        if newInstall { SettingsSync.shared.adoptOnNewInstall() }
        SettingsSync.shared.start()
        AutoUpdater.shared.start()
        _model = State(initialValue: model)
        SettingsWindow.shared.makeContent = {
            AnyView(SettingsView(helper: model.helper, controller: model.controller))
        }
        let hubMenu = HubMenu(model: model)
        hubMenu.start()
        AppDelegate.onURL = { url in
            let monitor = model.monitor, controller = model.controller!
            switch url.host {
            case "use-wired":
                // The fastest working wired connection, and the stragglers moved over with it.
                monitor.refresh()
                let wired = monitor.statuses.filter { $0.service.isWired && $0.isUsable }
                guard let best = wired.max(by: { ($0.speedMbps ?? 0) < ($1.speedMbps ?? 0) }), !best.isPrimary else { return }
                Task { await controller.switchTo(best, force: true) }
            case "move-connections":
                Task { await controller.moveConnectionsToActive() }
            case "toggle-wifi":
                guard let wifi = monitor.wiFi else { return }
                Task { await controller.toggleWiFi(on: !wifi.linkUp) }
            case "undo":
                guard controller.undoableOrder != nil else { return }
                Task { await controller.undo() }
            case "panel":
                hubMenu.showPanel()
            default:
                break
            }
        }
    }

    var body: some Scene {
        // Settings can remove the menu bar icon; the app then lives in the Dock, or nowhere.
        // ToolHUD can also take it into its own menu while it runs; that never changes the
        // setting, so the icon comes back when ToolHUD quits.
        MenuBarExtra(isInserted: Binding(get: { settings.showInMenuBar && !hub.isHosted },
                                         set: { if !hub.isHosted { settings.showInMenuBar = $0 } })) {
            MenuContentView(
                monitor: model.monitor,
                helper: model.helper,
                controller: model.controller,
                meter: model.meter,
                strandedMonitor: model.strandedMonitor,
                strandedMeter: model.strandedMeter,
                onAppear: { model.refreshHelperState() }
            )
        } label: {
            MenuBarLabel(monitor: model.monitor)
        }
        .menuBarExtraStyle(.window)
        .commands {
            // The app menu, while there is a Dock icon: Settings… opens the same window.
            CommandGroup(after: .appInfo) {
                // Right below About: the developer's site, which lists every app.
                Button("Our other apps…") { if let url = URL(string: "https://stevemanke.com/") { NSWorkspace.shared.open(url) } }
            }
            CommandGroup(replacing: .help) {
                Button("NetworkToggle Help") { HelpWindow.shared.show() }
                    .keyboardShortcut("?", modifiers: .command)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { SettingsWindow.shared.show() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

/// The menu bar item itself is the indicator: an RJ45 plug that is solid while a wired
/// connection is carrying traffic, hollow while it is not, and badged the moment a
/// better wired link is sitting idle.
struct MenuBarLabel: View {
    let monitor: NetworkMonitor
    @State private var settings = AppSettings.shared

    private var icon: NSImage { Self.image(for: monitor) }

    static func image(for monitor: NetworkMonitor) -> NSImage {
        guard let primary = monitor.primary else {
            return ConnectorShape.menuBarImage(filled: false, slashed: true)
        }
        if primary.service.isWired {
            return ConnectorShape.menuBarImage(filled: true)
        }
        return ConnectorShape.menuBarImage(filled: false, badged: !monitor.idleWired.isEmpty)
    }

    private var accessibilityDescription: String {
        guard let primary = monitor.primary else { return "No network connection" }
        var description = "Network: \(primary.name)"
        if let vpn = monitor.vpn { description += ", through \(vpn.name)" }
        if !monitor.idleWired.isEmpty { description += ". A wired connection is available." }
        return description
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: icon)
            if settings.showNameInMenuBar, let name = monitor.primary?.name {
                Text(name)
            }
        }
        .accessibilityLabel(accessibilityDescription)
    }
}
