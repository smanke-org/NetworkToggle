import AppKit

/// The app's entry point. `nettoggle <command>` (the app binary under a short name) runs the
/// command against the running app and exits, without starting a second copy; with no
/// command it opens the app. See Agent/AgentCLI.swift.
@main
enum AppMain {
    @MainActor
    static func main() {
        if let code = AgentCLI.runIfRequested() { exit(code) }
        NetworkToggleApp.main()
    }
}
