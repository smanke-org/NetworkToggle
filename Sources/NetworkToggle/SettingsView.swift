import SwiftUI
import NetworkToggleKit

struct SettingsView: View {
    let helper: HelperClient
    let controller: SwitchController

    @State private var settings = AppSettings.shared
    @State private var login = LaunchAtLogin.shared

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open NetworkToggle at login", isOn: Binding(
                    get: { login.isEnabled || login.needsApproval },
                    set: { login.set($0) }
                ))
                if login.needsApproval {
                    Text("It's switched off in Login Items. Turn NetworkToggle back on there to have it open at login.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Login Items Settings") { login.openLoginItemsSettings() }
                }
                if let error = login.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Automatic switching") {
                Picker("When a wired connection appears", selection: $settings.wiredArrival) {
                    ForEach(AppSettings.WiredArrival.allCases) { behaviour in
                        Text(behaviour.label).tag(behaviour)
                    }
                }
                Toggle("Also force a reconnect", isOn: $settings.autoSwitchForcesReconnect)
                    .disabled(settings.wiredArrival == .ignore)
                Text("Holds Wi-Fi off until connections opened over it have moved to the "
                     + "wired link, then turns it back on. A VPN does not move this way — "
                     + "disconnect and reconnect it instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Wait before switching", selection: $settings.settleDelaySeconds) {
                    Text("2 seconds").tag(2)
                    Text("4 seconds").tag(4)
                    Text("8 seconds").tag(8)
                }
                .disabled(settings.wiredArrival == .ignore)
            }

            Section("New docks") {
                Toggle("Ask when a new wired connection appears", isOn: $settings.promptForNewServices)
                Text("A dock macOS has not seen before gets a brand-new network service, "
                     + "added below Wi-Fi where it will never be chosen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Clear declined connections") { controller.clearDeclined() }
            }

            Section("Menu bar") {
                Toggle("Show the connection name", isOn: $settings.showNameInMenuBar)
            }

            Section("Updates") {
                Toggle("Check for updates at launch", isOn: $settings.checkForUpdatesAtLaunch)
                Text("The launch check never installs anything on its own — it puts an "
                     + "\u{201C}Update to…\u{201D} item in the menu and waits for you. Updates are "
                     + "refused unless they are signed by the same developer as this copy "
                     + "and notarized by Apple.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Check Now") { UpdateController.checkForUpdates() }
                    if let skipped = settings.skippedUpdateVersion {
                        Spacer()
                        Button("Stop skipping \(skipped)") {
                            settings.skippedUpdateVersion = nil
                        }
                    }
                }
            }

            Section("Helper") {
                LabeledContent("Status", value: helperDescription)
                Button("Remove helper") {
                    Task { await helper.uninstallHelper() }
                }
                .disabled(!helper.state.isReady)
            }

            Section {
                LabeledContent("Version", value: AppInfo.displayVersion)
            }
        }
        .formStyle(.grouped)
        .onAppear { login.refresh() }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var helperDescription: String {
        switch helper.state {
        case .ready: "Installed and running"
        case .notInstalled: "Not installed"
        case .requiresApproval: "Waiting for approval in Login Items"
        case let .failed(reason): reason
        }
    }
}
