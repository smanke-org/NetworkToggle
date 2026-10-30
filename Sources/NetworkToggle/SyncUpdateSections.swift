import SwiftUI

/// The iCloud settings sync and update choices, as two sections for a grouped Settings form.
struct SyncUpdateSections: View {
    @ObservedObject private var sync = SettingsSync.shared
    @ObservedObject private var updater = AutoUpdater.shared

    var body: some View {
        Section {
            Toggle("Sync settings with your other Macs", isOn: $sync.isEnabled)
            if sync.isEnabled {
                LabeledContent {
                    Button("Sync Now") { sync.syncNow() }
                } label: {
                    if let error = sync.lastError {
                        Text(error).foregroundStyle(.red)
                    } else if let date = sync.lastSynced {
                        Text("Synced \(date.formatted(date: .omitted, time: .shortened))\(sync.lastSource.map { $0 == (Host.current().localizedName ?? "") ? "" : " from \($0)" } ?? "")")
                    } else {
                        Text("Waiting for iCloud Drive…")
                    }
                }
            }
        } header: {
            Text("iCloud")
        } footer: {
            Text("What happens when a wired connection appears, how long to wait, what the menu bar shows, where NetworkToggle appears and asking before quitting follow you to every Mac signed in to the same iCloud account with sync turned on. Declined network services and the helper's approval stay on each Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            Picker("When an update is available", selection: $updater.policy) {
                ForEach(UpdatePolicy.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if updater.policy != .off {
                UpdateIntervalPicker(interval: $updater.interval)
            }
            if let staged = updater.staged {
                LabeledContent("Version \(staged.version) is ready") {
                    Button("Install Now") { updater.installNow() }
                }
            }
            LabeledContent("Version \(AppInfo.displayVersion)") {
                Button("Check Now") { UpdateController.checkForUpdates() }
            }
            if let error = updater.lastError {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            if updater.policy != .off && !updater.notificationsAllowed {
                LabeledContent {
                    Button("Open Notification Settings") { AutoUpdater.openNotificationSettings() }
                } label: {
                    Label("Notifications are off for NetworkToggle, so update news only shows in the menu.", systemImage: "bell.slash")
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Updates")
        } footer: {
            Text(updateFooter).font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { updater.refreshNotificationStatus() }
    }

    private var updateFooter: String {
        switch updater.policy {
        case .automatic:
            return "NetworkToggle checks \(updater.interval.phrase). A new version installs itself when no network switch is in progress or waiting for your answer, no app is presenting or keeping the screen awake, and your Mac hasn't been used for 2 minutes. You'll get a notification when it's done."
        case .ask:
            return "NetworkToggle checks \(updater.interval.phrase) and sends a notification when a new version is out. Nothing installs until you choose to."
        case .off:
            return "NetworkToggle won't look for updates on its own. Use Check Now whenever you like."
        }
    }
}
