import AppKit
import SwiftUI

// MARK: - Content

/// One page of Help. `Help.resolve` swaps `{…}` tokens for the user's own settings, such
/// as their shortcuts, so the text matches what they've set up.
struct HelpTopic: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let blocks: [HelpBlock]

    static func == (a: HelpTopic, b: HelpTopic) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor
enum HelpBlock {
    case text(String)
    case heading(String)
    /// Keys on the left, what they do on the right.
    case keys([(String, String)])
    case tip(String)

    var searchText: String {
        switch self {
        case .text(let s), .heading(let s), .tip(let s): Help.resolve(s)
        case .keys(let rows): rows.map { Help.resolve($0.0) + " " + Help.resolve($0.1) }.joined(separator: " ")
        }
    }
}

@MainActor
enum Help {
    /// NetworkToggle has no shortcuts the user sets, so nothing needs swapping.
    static func resolve(_ text: String) -> String { text }
    static var debugTokens: String { "" }
    static let testTabs = ["Settings"]
    static func topic(forSettingsTab tab: String) -> String { "getting-started" }

    static var topics: [HelpTopic] { [
        HelpTopic(id: "getting-started", title: "Getting Started", symbol: "sparkles", blocks: [
            .text("NetworkToggle shows which network connection is really carrying your traffic, and switches to a wired one when you want, or automatically when you plug into a dock."),
            .text("It exists because macOS often keeps using Wi-Fi even with a faster cable plugged in: a dock it hasn't seen before gets a brand-new network service listed below Wi-Fi, and open connections, VPNs especially, stay on Wi-Fi even after the switch."),
            .heading("The helper"),
            .text("Changing the order of network services needs administrator rights, so NetworkToggle installs a small helper the first time. Approve it when macOS asks, in System Settings › General › Login Items. Settings › Helper shows its status, and Remove helper takes it away."),
            .tip("Turn on \"Show the connection name\" in Settings to see the active connection's name next to the menu bar icon."),
            .tip("While ToolHUD is running, NetworkToggle's main actions move into ToolHUD's menu bar menu as a submenu, and the icon here steps aside until ToolHUD quits. Move Connections to… there pulls connections still on Wi-Fi across, as the panel's button does, and Show Connections… opens the full panel under ToolHUD's icon. To keep the icon, turn off \"Put in ToolHUD's menu while ToolHUD is running\" in Settings."),
        ]),

        HelpTopic(id: "switching", title: "Switching Connections", symbol: "arrow.left.arrow.right", blocks: [
            .text("Click the menu bar icon to see every connection, which one is carrying traffic, and its speed. Drag a connection to change the order, or use Move to Top."),
            .keys([
                ("Switch to [connection]", "Make the idle wired connection the one macOS uses"),
                ("Use (on hover)", "Make any working connection in the list the one macOS uses"),
                ("Switch and force reconnect", "Also hold Wi-Fi off until open connections move over, then turn Wi-Fi back on"),
                ("Turn Wi-Fi off / on", "Switch Wi-Fi itself"),
                ("Undo last change", "Put the previous order back"),
                ("Move connections", "Move connections still open over the old link"),
            ]),
            .text("If a VPN is running over the connection you're leaving, NetworkToggle warns that switching will interrupt it. A VPN doesn't move on its own; disconnect and reconnect it."),
        ]),

        HelpTopic(id: "automatic", title: "Automatic Switching", symbol: "cable.connector", blocks: [
            .text("Settings › Automatic switching decides what happens when a wired connection appears:"),
            .keys([
                ("Ask me", "A notification offers to switch"),
                ("Switch automatically", "Switch to it on its own"),
                ("Do nothing", "Leave things as they are"),
                ("Also force a reconnect", "Move open connections over too"),
                ("Wait before switching", "Let the cable settle for 2, 4 or 8 seconds first"),
            ]),
            .heading("New docks"),
            .text("With \"Ask when a new wired connection appears\" on, NetworkToggle offers to move a brand-new service above Wi-Fi so it's actually used. Clear declined connections forgets the ones you said no to."),
        ]),

        HelpTopic(id: "automation", title: "Automation", symbol: "gearshape.2", blocks: [
            .keys([
                ("networktoggle://use-wired", "Switch to the fastest working wired connection"),
                ("networktoggle://move-connections", "Move connections still on the old link"),
                ("networktoggle://toggle-wifi", "Turn Wi-Fi off or on"),
                ("networktoggle://undo", "Undo the last change"),
                ("networktoggle://panel", "Open the menu bar panel in a window"),
            ]),
            .text("Use these links from Shortcuts, scripts or a launcher. ToolHUD's NetworkToggle buttons use them."),
        ]),

        HelpTopic(id: "troubleshooting", title: "Troubleshooting", symbol: "wrench.and.screwdriver", blocks: [
            .heading("\"Setup needed\" in the menu"),
            .text("The helper isn't installed or approved. Click Install helper, then allow NetworkToggle in System Settings › General › Login Items."),
            .heading("Plugged in, but still on Wi-Fi"),
            .text("The cable's service may be new and listed below Wi-Fi. Use it from the menu, or turn on \"Ask when a new wired connection appears\". Open connections may still be on Wi-Fi: use Switch and force reconnect."),
            .heading("A self-assigned address"),
            .text("A connection with a 169.254 address has no working network behind it, so macOS never uses it. Check the cable and the dock."),
        ]),
    ] }
}

// MARK: - Window

@Observable
@MainActor
final class HelpState {
    var selection: String? = "getting-started"
    var query = ""
}

@MainActor
final class HelpWindow: NSObject, NSWindowDelegate {
    static let shared = HelpWindow()

    let state = HelpState()
    private(set) var window: NSWindow?

    /// Opens Help, on `topic` when given.
    func show(topic: String? = nil) {
        if let topic { state.query = ""; state.selection = topic }
        if window == nil {
            let hosting = NSHostingController(rootView: HelpView(state: state))
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.title = "NetworkToggle Help"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            let screen = NSScreen.main?.visibleFrame.height ?? 800
            window.setContentSize(NSSize(width: 820, height: min(600, screen - 80)))
            window.contentMinSize = NSSize(width: 640, height: 400)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("NetworkToggleHelp")
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct HelpView: View {
    @Bindable var state: HelpState

    private var matches: [HelpTopic] {
        let query = state.query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return Help.topics }
        return Help.topics.filter { topic in
            topic.title.lowercased().contains(query) || topic.blocks.contains { $0.searchText.lowercased().contains(query) }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(matches, selection: $state.selection) { topic in
                Label(topic.title, systemImage: topic.symbol).tag(topic.id)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .overlay {
                if matches.isEmpty { Text("No matches").foregroundStyle(.secondary) }
            }
        } detail: {
            if let topic = Help.topics.first(where: { $0.id == state.selection }) {
                HelpPage(topic: topic, query: state.query)
            } else {
                Text("Choose a topic").foregroundStyle(.secondary)
            }
        }
        .searchable(text: $state.query, placement: .sidebar, prompt: "Search Help")
        .onChange(of: state.query) {
            // Keep a matching topic on screen while searching.
            if let first = matches.first, !matches.contains(where: { $0.id == state.selection }) { state.selection = first.id }
        }
    }
}

struct HelpPage: View {
    let topic: HelpTopic
    let query: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(topic.title, systemImage: topic.symbol)
                    .font(.largeTitle.weight(.semibold))
                    .padding(.bottom, 4)
                ForEach(Array(topic.blocks.enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .padding(28)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func view(for block: HelpBlock) -> some View {
        switch block {
        case .text(let s):
            Text(Help.resolve(s)).fixedSize(horizontal: false, vertical: true)
        case .heading(let s):
            Text(Help.resolve(s)).font(.title3.weight(.semibold)).padding(.top, 8)
        case .tip(let s):
            Label { Text(Help.resolve(s)).fixedSize(horizontal: false, vertical: true) } icon: {
                Image(systemName: "lightbulb").foregroundStyle(.yellow)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .keys(let rows):
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    let keys = Help.resolve(row.0), what = Help.resolve(row.1)
                    let hit = !query.isEmpty && (keys + " " + what).lowercased().contains(query.lowercased())
                    GridRow {
                        Text(keys)
                            .font(.body.monospaced().weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                            // The same key column width in every table on every page.
                            .frame(width: 210, alignment: .leading)
                        Text(what).fixedSize(horizontal: false, vertical: true)
                    }
                    .background(hit ? Color.yellow.opacity(0.25) : .clear)
                }
            }
        }
    }
}

/// The round "?" button macOS puts in the corner of settings panes.
struct HelpButton: NSViewRepresentable {
    let topic: String

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.open))
        button.bezelStyle = .helpButton
        button.toolTip = "NetworkToggle Help"
        button.setAccessibilityLabel("Help")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.topic = topic }

    func makeCoordinator() -> Coordinator { Coordinator(topic: topic) }

    @MainActor
    final class Coordinator: NSObject {
        var topic: String
        init(topic: String) { self.topic = topic }
        @objc func open() { HelpWindow.shared.show(topic: topic) }
    }
}
