import AppKit
import NetworkToggleKit

/// What the agent commands work on, set by NetworkToggleApp once its model exists.
@MainActor
enum AgentContext {
    static var model: AppModel?
    /// The ToolHUD hub's floating copy of the menu bar panel (`networktoggle://panel`).
    static var showPanel: (() -> Void)?
}

/// Everything an agent can do in NetworkToggle. Add a command here and the CLI, `help`, and
/// the MCP tools all get it. Each `run` is on the main actor and calls the same code as the
/// menu bar panel, the ToolHUD hub menu and the networktoggle:// actions.
///
/// Every command that changes the network is destructive: without --yes it only reports what
/// it would do, since switching or turning Wi-Fi off can cut off the agent's own connection.
/// The change itself runs in the background, as a click does; `status` shows it finishing.
@MainActor
enum AgentCommands {
    static let all: [AgentCommand] = [
        AgentCommand(name: "status", summary: "Show the active connection (`active`), the VPN it carries (`vpn`), Wi-Fi (`wifi`), idle wired connections (`idleWired`), whether the helper that makes changes is set up (`helper`), a change under way (`busy`), how the last one went (`lastAction`, `lastError`) and whether it can be undone (`canUndo`).",
                     example: "nettoggle status --json", readOnly: true) { _ in
            let model = try model()
            let monitor = model.monitor, controller = model.controller!
            monitor.refresh()
            if !AgentSocket.isTestRun { model.refreshHelperState() }
            let wifi: Any = monitor.wiFi.map { wifi -> JSONObject in
                ["name": wifi.name, "on": wifi.linkUp, "interface": wifi.bsdName ?? NSNull(), "ipv4": wifi.ipv4 ?? NSNull()]
            } ?? NSNull()
            return ["app": AppInfo.name, "version": AppInfo.version,
                    "active": monitor.primary.map { brief($0) } ?? NSNull(),
                    "vpn": vpn(monitor) ?? NSNull(),
                    "wifi": wifi,
                    "idleWired": monitor.idleWired.map(\.name),
                    "helper": helperText(model),
                    "busy": controller.busyMessage ?? NSNull(),
                    "lastAction": controller.lastAction ?? NSNull(),
                    "lastError": controller.lastError ?? NSNull(),
                    "canUndo": controller.undoableOrder != nil,
                    "wiredArrival": AppSettings.shared.wiredArrival.rawValue,
                    "testCopy": AgentSocket.isTestRun]
        },

        // MARK: Services

        AgentCommand(name: "services list", summary: "List the network services in the order macOS ranks them (the top working one carries the traffic). Returns `services` (rank, id, name, interface, kind, enabled, linkUp, ipv4, router, speed, active, carriesVPN, usable) and `total`.",
                     example: "nettoggle services list --json", readOnly: true) { _ in
            let monitor = try model().monitor
            monitor.refresh()
            let services = monitor.statuses.enumerated().map { summary($1, rank: $0 + 1) }
            return ["services": services, "total": services.count]
        },
        AgentCommand(name: "services show", summary: "Show one network service: its full id, interface, address, router, link speed, and whether it's active, carries the VPN and is usable.",
                     params: [serviceParam(required: true)],
                     example: "nettoggle services show Wi-Fi --json", readOnly: true) { args in
            let monitor = try model().monitor
            monitor.refresh()
            let status = try find(args.required("service"), in: monitor.statuses)
            var result = summary(status, rank: (monitor.statuses.firstIndex(of: status) ?? 0) + 1)
            result["fullID"] = status.id
            result["gatewayConfirmed"] = status.gatewayConfirmed
            result["idleWired"] = status.isIdleWired
            return result
        },
        AgentCommand(name: "services switch", summary: "Make a connection the active one by moving it to the top of the order, as the panel's Switch button does. Without a service, switches to the fastest working wired connection (like networktoggle://use-wired). Without --yes it only shows what it would do.",
                     params: [serviceParam(required: false, extra: "; leave out for the fastest working wired connection"),
                              .init(name: "reconnect", kind: .boolean, help: "also hold Wi-Fi off until open connections move over, then turn it back on (Switch and force reconnect)")],
                     example: "nettoggle services switch Ethernet --yes --json", destructive: true) { args in
            try refuseInTestCopy(args)
            let model = try model()
            let monitor = model.monitor
            monitor.refresh()
            let reconnect = try args.bool("reconnect") == true
            let target: ServiceStatus
            if let query = args.string("service") {
                target = try find(query, in: monitor.statuses)
            } else {
                let wired = monitor.statuses.filter { $0.service.isWired && $0.isUsable }
                guard let best = wired.max(by: { ($0.speedMbps ?? 0) < ($1.speedMbps ?? 0) }) else {
                    throw AgentError.notFound("no working wired connection. Run `nettoggle services list`")
                }
                target = best
            }
            guard target.isUsable else {
                throw AgentError.invalid("\(target.name) has no working connection yet: it needs a link, an address and a router")
            }
            if target.isPrimary, !reconnect {
                return ["changed": false, "active": target.name, "message": "\(target.name) is already the active connection"]
            }
            let preview: JSONObject = ["wouldSwitchTo": brief(target), "from": monitor.primary?.name ?? NSNull(),
                                       "reconnect": reconnect, "interruptsVPN": interruptsVPN(monitor, newTop: target),
                                       "note": reconnect ? "Wi-Fi goes off for up to 30 seconds while open connections move over, then comes back on"
                                           : "new connections use \(target.name); open ones stay where they are until they reconnect"]
            return try change(args, model: model, preview: preview,
                              started: ["switchingTo": target.name, "reconnect": reconnect]) { controller in
                await controller.switchTo(target, force: reconnect)
            }
        },
        AgentCommand(name: "services reorder", summary: "Put services at the top of the order, in the order given, as dragging them in the panel does; the rest keep their order below. Without --yes it only shows the new order.",
                     params: [.init(name: "order", required: true, help: "service names, interfaces or ids, separated by commas, top first")],
                     example: "nettoggle services reorder --order \"Ethernet,Wi-Fi\" --yes --json", destructive: true) { args in
            try refuseInTestCopy(args)
            let model = try model()
            let monitor = model.monitor
            monitor.refresh()
            let statuses = monitor.statuses
            let wanted = try list(args.required("order")).map { try find($0, in: statuses) }
            guard Set(wanted.map(\.id)).count == wanted.count else { throw AgentError.usage("--order names a service twice") }
            let ids = wanted.map(\.id) + statuses.map(\.id).filter { id in !wanted.contains { $0.id == id } }
            let byID = Dictionary(uniqueKeysWithValues: statuses.map { ($0.id, $0) })
            if ids == statuses.map(\.id) {
                return ["changed": false, "order": statuses.map(\.name), "message": "that's already the order"]
            }
            let newTop = ids.lazy.compactMap { byID[$0] }.first { $0.isUsable && !$0.service.isTunnel }
            let preview: JSONObject = ["current": statuses.map(\.name), "new": ids.compactMap { byID[$0]?.name },
                                       "interruptsVPN": newTop.map { interruptsVPN(monitor, newTop: $0) } ?? false]
            return try change(args, model: model, preview: preview, started: ["order": ids.compactMap { byID[$0]?.name }]) { controller in
                await controller.applyOrder(ids)
            }
        },
        AgentCommand(name: "services undo", summary: "Put back the order from before the last switch or reorder, as Undo last change does. Without --yes it only shows the order it would restore.",
                     example: "nettoggle services undo --yes --json", destructive: true) { args in
            try refuseInTestCopy(args)
            let model = try model()
            guard let previous = model.controller.undoableOrder else {
                throw AgentError.invalid("nothing to undo: no switch or reorder since NetworkToggle opened, or it was already undone")
            }
            let names = Dictionary(uniqueKeysWithValues: model.monitor.statuses.map { ($0.id, $0.name) })
            let order = previous.map { names[$0] ?? $0 }
            return try change(args, model: model, preview: ["wouldRestore": order], started: ["restoring": order]) { controller in
                await controller.undo()
            }
        },

        // MARK: Wi-Fi and stranded connections

        wifiCommand(on: true),
        wifiCommand(on: false),
        AgentCommand(name: "connections move", summary: "Move connections still open over Wi-Fi to the active wired connection, as Move Connections does: turns Wi-Fi off until they reconnect (at most 30 seconds), then back on. Without --yes it only shows what it would do.",
                     example: "nettoggle connections move --yes --json", destructive: true) { args in
            try refuseInTestCopy(args)
            let model = try model()
            let monitor = model.monitor
            monitor.refresh()
            guard let active = monitor.vpnCarrier ?? monitor.primary else { throw AgentError.invalid("there's no active connection to move them to") }
            guard !active.service.isWiFi else { throw AgentError.invalid("Wi-Fi is the active connection, so nothing needs to move off it") }
            guard let wifi = monitor.wiFi, wifi.linkUp, wifi.ipv4 != nil else {
                throw AgentError.invalid("Wi-Fi isn't connected, so no connections are left on it")
            }
            let preview: JSONObject = ["wouldMoveTo": active.name, "from": wifi.name,
                                       "note": "turns \(wifi.name) off until connections still on it reconnect over \(active.name) (at most 30 seconds), then back on. A VPN running over Wi-Fi drops"]
            return try change(args, model: model, preview: preview, started: ["movingTo": active.name]) { controller in
                await controller.moveConnectionsToActive()
            }
        },

        // MARK: Settings and windows

        AgentCommand(name: "settings show", summary: "Show the automatic switching settings: what happens when a wired connection appears (`wiredArrival`: ask, automatically or ignore), whether that also forces a reconnect, the wait before switching, the new-dock prompt, and the connection name in the menu bar.",
                     example: "nettoggle settings show --json", readOnly: true) { _ in
            settings()
        },
        AgentCommand(name: "settings set", summary: "Change the automatic switching settings, as Settings does. Only the options you give change, and they sync to your other Macs like any setting.",
                     params: [.init(name: "wired-arrival", help: "when a wired connection appears: ask (a notification offers to switch), automatically, or ignore"),
                              .init(name: "reconnect", kind: .boolean, help: "true or false: an automatic switch also forces a reconnect"),
                              .init(name: "settle-delay", kind: .integer, help: "seconds to wait before switching: 2, 4 or 8"),
                              .init(name: "ask-new-docks", kind: .boolean, help: "true or false: ask when a new wired connection appears"),
                              .init(name: "show-name", kind: .boolean, help: "true or false: show the connection's name next to the menu bar icon")],
                     example: "nettoggle settings set --wired-arrival automatically --settle-delay 4 --json") { args in
            let settings = AppSettings.shared
            let before = Self.settings()
            if let raw = args.string("wired-arrival") {
                guard let value = AppSettings.WiredArrival(rawValue: raw.lowercased()) else {
                    throw AgentError.usage("--wired-arrival must be ask, automatically or ignore, not \"\(raw)\"")
                }
                if settings.wiredArrival != value { settings.wiredArrival = value }
            }
            if let delay = args.string("settle-delay") {
                guard let seconds = Int(delay), [2, 4, 8].contains(seconds) else {
                    throw AgentError.usage("--settle-delay must be 2, 4 or 8, not \"\(delay)\"")
                }
                if settings.settleDelaySeconds != seconds { settings.settleDelaySeconds = seconds }
            }
            if let value = try args.bool("reconnect"), settings.autoSwitchForcesReconnect != value { settings.autoSwitchForcesReconnect = value }
            if let value = try args.bool("ask-new-docks"), settings.promptForNewServices != value { settings.promptForNewServices = value }
            if let value = try args.bool("show-name"), settings.showNameInMenuBar != value { settings.showNameInMenuBar = value }
            var result = Self.settings()
            result["changed"] = !NSDictionary(dictionary: before).isEqual(to: result)
            return result
        },
        AgentCommand(name: "settings open", summary: "Bring up the Settings window.",
                     example: "nettoggle settings open --json") { _ in
            try refuseWindowInTestCopy()
            SettingsWindow.shared.show()
            return ["open": true]
        },
        AgentCommand(name: "panel open", summary: "Open the menu bar panel (connections, throughput, switch buttons) as a floating window, like networktoggle://panel.",
                     example: "nettoggle panel open --json") { _ in
            try refuseWindowInTestCopy()
            guard let showPanel = AgentContext.showPanel else { throw AgentError.unavailable("NetworkToggle is still starting. Try again in a moment") }
            showPanel()
            return ["open": true]
        },
    ]

    private static func wifiCommand(on: Bool) -> AgentCommand {
        AgentCommand(name: on ? "wifi on" : "wifi off",
                     summary: on ? "Turn Wi-Fi on, as Turn Wi-Fi on does. Without --yes it only shows what it would do."
                         : "Turn Wi-Fi off, as Turn Wi-Fi off does. If Wi-Fi is the active connection, this Mac goes offline. Without --yes it only shows what it would do.",
                     example: on ? "nettoggle wifi on --yes --json" : "nettoggle wifi off --yes --json", destructive: true) { args in
            try refuseInTestCopy(args)
            let model = try model()
            let monitor = model.monitor
            monitor.refresh()
            guard let wifi = monitor.wiFi, let bsd = wifi.bsdName else { throw AgentError.notFound("this Mac has no Wi-Fi service") }
            if wifi.linkUp == on { return ["changed": false, "wifi": wifi.name, "on": on, "message": "Wi-Fi is already \(on ? "on" : "off")"] }
            var preview: JSONObject = ["wouldTurn": on ? "on" : "off", "wifi": wifi.name, "interface": bsd]
            if !on, monitor.primary?.service.isWiFi == true || monitor.vpnCarrier?.service.isWiFi == true {
                preview["warning"] = "Wi-Fi is the active connection: turning it off leaves this Mac without a network connection"
            }
            return try change(args, model: model, preview: preview, started: ["turning": on ? "on" : "off", "wifi": wifi.name]) { controller in
                await controller.toggleWiFi(on: on)
            }
        }
    }

    // MARK: Helpers

    private static func serviceParam(required: Bool, extra: String = "") -> AgentCommand.Param {
        .init(name: "service", required: required, positional: true,
              help: "a service's name (Wi-Fi), interface (en0) or id (any unique start of it)" + extra)
    }

    private static func model() throws -> AppModel {
        guard let model = AgentContext.model else { throw AgentError.unavailable("NetworkToggle is still starting. Try again in a moment") }
        return model
    }

    /// A test copy reads the network but never asks the helper to change it.
    private static func refuseInTestCopy(_ args: Args) throws {
        if args.confirmed, AgentSocket.isTestRun { throw AgentError.testCopy }
    }

    /// The panel and Settings talk to the helper and login items; a test copy shows neither.
    private static func refuseWindowInTestCopy() throws {
        if AgentSocket.isTestRun { throw AgentError.invalid("a test copy (APP_STORE) opens no windows: they read the helper and login items") }
    }

    /// Without --yes, what would happen. With it, starts the change the way a click does and
    /// says how to follow it.
    private static func change(_ args: Args, model: AppModel, preview: JSONObject, started: JSONObject,
                               _ action: @escaping @MainActor (SwitchController) async -> Void) throws -> JSONObject {
        guard args.confirmed else {
            var result = preview
            result["helper"] = helperText(model)
            result["hint"] = "add --yes to do it. It changes this Mac's network, which can drop open connections (and the agent's own)"
            return result
        }
        if AgentSocket.isTestRun { throw AgentError.testCopy }
        model.refreshHelperState()
        guard model.helper.state.isReady else {
            throw AgentError.invalid("the helper isn't set up (\(helperText(model))), so NetworkToggle can't change the network. "
                                     + "Ask the person to open the NetworkToggle menu and finish setup")
        }
        let controller: SwitchController = model.controller
        if let busy = controller.busyMessage { throw AgentError.busy("NetworkToggle is busy: \(busy) Try again when `nettoggle status` shows busy as none") }
        Task { await action(controller) }
        var result = started
        result["started"] = true
        result["hint"] = "runs in the background: run `nettoggle status --json` until busy is none; lastAction or lastError says how it went"
        return result
    }

    private static func helperText(_ model: AppModel) -> String {
        if AgentSocket.isTestRun { return "not checked (test copy)" }
        switch model.helper.state {
        case .ready: return "ready"
        case .requiresApproval: return "waiting for approval in Login Items"
        case .notInstalled: return "not set up"
        case let .failed(reason): return "failed: \(reason)"
        }
    }

    /// The panel's rule: a change that puts traffic on another link than the one a
    /// full-tunnel VPN rides on interrupts the VPN.
    private static func interruptsVPN(_ monitor: NetworkMonitor, newTop: ServiceStatus) -> Bool {
        guard let vpn = monitor.vpn, vpn.isPrimary, let carrier = vpn.carrierBSDName else { return false }
        return newTop.bsdName != carrier
    }

    private static func vpn(_ monitor: NetworkMonitor) -> JSONObject? {
        guard let vpn = monitor.vpn else { return nil }
        return ["name": vpn.name, "tunnel": vpn.tunnelInterface, "fullTunnel": vpn.isPrimary,
                "carriedBy": monitor.vpnCarrier?.name ?? NSNull(), "server": vpn.serverAddress ?? NSNull()]
    }

    private static func short(_ id: String) -> String { String(id.prefix(8)) }

    private static func kind(_ service: NetworkServiceInfo) -> String {
        service.isWiFi ? "wifi" : service.isWired ? "wired" : service.isTunnel ? "vpn" : "other"
    }

    private static func brief(_ status: ServiceStatus) -> JSONObject {
        ["id": short(status.id), "name": status.name, "interface": status.bsdName ?? NSNull(), "kind": kind(status.service),
         "ipv4": status.ipv4 ?? NSNull(), "router": status.router ?? NSNull(), "speed": status.speedLabel ?? NSNull()]
    }

    private static func summary(_ status: ServiceStatus, rank: Int) -> JSONObject {
        var result = brief(status)
        result["rank"] = rank
        result["enabled"] = status.service.isEnabled
        result["linkUp"] = status.linkUp
        result["active"] = status.isPrimary
        result["carriesVPN"] = status.carriesVPN
        result["usable"] = status.isUsable
        return result
    }

    private static func settings() -> JSONObject {
        let settings = AppSettings.shared
        return ["wiredArrival": settings.wiredArrival.rawValue, "reconnect": settings.autoSwitchForcesReconnect,
                "settleDelay": settings.settleDelaySeconds, "askNewDocks": settings.promptForNewServices,
                "showName": settings.showNameInMenuBar]
    }

    private static func list(_ raw: String) -> [String] {
        raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// A service by its name, interface or id (any unique start of the id), ignoring case.
    private static func find(_ query: String, in statuses: [ServiceStatus]) throws -> ServiceStatus {
        let wanted = query.lowercased()
        let exact = statuses.filter { $0.name.lowercased() == wanted || $0.bsdName?.lowercased() == wanted || $0.id.lowercased() == wanted }
        let matches = exact.isEmpty ? statuses.filter { $0.id.lowercased().hasPrefix(wanted) } : exact
        guard let first = matches.first else {
            throw AgentError.notFound("no network service \"\(query)\". Run `nettoggle services list`")
        }
        guard matches.count == 1 else {
            throw AgentError.usage("\"\(query)\" matches \(matches.count) services (\(matches.map { "\($0.name) \(short($0.id))" }.joined(separator: ", "))). Use its id")
        }
        return first
    }
}
