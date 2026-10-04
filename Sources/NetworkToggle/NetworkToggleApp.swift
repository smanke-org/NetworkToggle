import SwiftUI
import NetworkToggleKit

@main
struct NetworkToggleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    @State private var settings = AppSettings.shared

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        SettingsWindow.shared.makeContent = {
            AnyView(SettingsView(helper: model.helper, controller: model.controller))
        }
    }

    var body: some Scene {
        // Settings can remove the menu bar icon; the app then lives in the Dock, or nowhere.
        MenuBarExtra(isInserted: $settings.showInMenuBar) {
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

    private var icon: NSImage {
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
