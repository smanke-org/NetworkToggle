import AppKit

/// `NETWORKTOGGLE_DEBUG_QUIT_TEST=<return|cancel|quit|suppress|off>` (trace to
/// `NETWORKTOGGLE_DEBUG_TRACE`): quits as ⌘Q does, then answers the question a second later:
/// presses Return, clicks Cancel or Quit (ticking "Don't ask again" first for `suppress`), or
/// with `off` turns the setting off first. What the question looked like is traced before any
/// answer, and a run that is still going afterwards traces the setting and the activation
/// policy. `NETWORKTOGGLE_DEBUG_QUIT_DELAY` (seconds, default 1) waits longer before quitting,
/// time enough to open the app again so it is active, as it is when you quit it yourself;
/// Settings, which that opens, is then rendered to `NETWORKTOGGLE_DEBUG_SNAPSHOT` if set.
@MainActor
enum DebugQuitTest {
    /// A Help or quit test run, which shares the installed app's settings and helper and so
    /// starts nothing else. Always false in a release build.
    nonisolated static var isTestRun: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        return env["NETWORKTOGGLE_DEBUG_HELP_TEST"] != nil || env["NETWORKTOGGLE_DEBUG_QUIT_TEST"] != nil
        #else
        return false
        #endif
    }

    #if DEBUG
    private static var lines: [String] = []

    static func run(_ how: String) {
        trace("started policy \(NSApp.activationPolicy().rawValue) active \(NSApp.isActive)")
        let env = ProcessInfo.processInfo.environment
        let delay = env["NETWORKTOGGLE_DEBUG_QUIT_DELAY"].flatMap(Double.init) ?? 1
        if delay > 1 {
            // Opening the app again makes it a regular app. Leave the Dock again as the
            // Settings switch does, keeping Settings in front, so the quit starts from a menu
            // bar app that you're using.
            DispatchQueue.main.asyncAfter(deadline: .now() + delay - 1) {
                MainActor.assumeIsolated {
                    let window = NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeKey }
                    trace("reopened: window \(window?.title ?? "none") key \(window?.isKeyWindow == true) active \(NSApp.isActive) policy \(NSApp.activationPolicy().rawValue)")
                    if let path = env["NETWORKTOGGLE_DEBUG_SNAPSHOT"], let view = window?.contentView?.superview,
                       let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    }
                    if !AppPresence.showInDock { AppPresence.applyDock(keepInFront: window) }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                if how == "off" { AppSettings.shared.confirmQuit = false }
                trace("quitting confirmQuit \(AppSettings.shared.confirmQuit) policy \(NSApp.activationPolicy().rawValue) active \(NSApp.isActive)")
                let answer = Timer(timeInterval: 1, repeats: false) { _ in
                    MainActor.assumeIsolated { Self.answer(how) }
                }
                RunLoop.main.add(answer, forMode: .common)
                NSApp.terminate(nil)
                // Only reached when the quit was called off.
                let after = Timer(timeInterval: 0.5, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        trace("still running; confirmQuit \(AppSettings.shared.confirmQuit); policy \(NSApp.activationPolicy().rawValue) active \(NSApp.isActive)")
                    }
                }
                RunLoop.main.add(after, forMode: .common)
            }
        }
    }

    private static func trace(_ s: String) {
        lines.append(s)
        guard let path = ProcessInfo.processInfo.environment["NETWORKTOGGLE_DEBUG_TRACE"] else { return }
        try? lines.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func answer(_ how: String) {
        guard let window = NSApp.modalWindow else { trace("no question"); return }
        var texts: [String] = []
        var buttons: [NSButton] = []
        func walk(_ view: NSView) {
            if let button = view as? NSButton { buttons.append(button) }
            else if let field = view as? NSTextField, !field.stringValue.isEmpty { texts.append(field.stringValue) }
            view.subviews.forEach(walk)
        }
        if let content = window.contentView { walk(content) }
        let titles = buttons.map { "\($0.title)[\($0.keyEquivalent == "\r" ? "Return" : $0.keyEquivalent == "\u{1b}" ? "Esc" : $0.keyEquivalent)]" }
        trace("asked \(texts) buttons \(titles) key \(window.isKeyWindow) visible \(window.isVisible) active \(NSApp.isActive) policy \(NSApp.activationPolicy().rawValue)")
        switch how {
        case "return":
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: "\r",
                                            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                NSApp.postEvent(event, atStart: false)
            }
            // Return should leave the question up; close it with Cancel afterwards.
            let check = Timer(timeInterval: 1, repeats: false) { _ in
                MainActor.assumeIsolated {
                    trace("after Return: question still up \(NSApp.modalWindow != nil)")
                    buttons.first { $0.title == "Cancel" }?.performClick(nil)
                }
            }
            RunLoop.main.add(check, forMode: .common)
        case "cancel": buttons.first { $0.title == "Cancel" }?.performClick(nil)
        case "quit", "suppress":
            if how == "suppress" { buttons.first { $0.title == "Don't ask again" }?.performClick(nil) }
            buttons.first { $0.title == "Quit" }?.performClick(nil)
        default: break
        }
    }
    #endif
}
