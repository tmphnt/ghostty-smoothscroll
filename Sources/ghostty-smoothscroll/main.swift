// ghostty-smoothscroll: Vimium-style smooth scrolling for Ghostty on macOS.
//
//   ghostty-smoothscroll setup      add the Ghostty keybinds and start at login
//   ghostty-smoothscroll uninstall  undo `setup`
//   ghostty-smoothscroll status     show what is installed and running
//   ghostty-smoothscroll config     create the settings file (if missing) and show its path
//   ghostty-smoothscroll permissions  open the System Settings pane for its permission
//   ghostty-smoothscroll run        the background process (started by `setup`)

import AppKit

let version = "0.1.2"
let agentLabel = "io.github.ghostty-smoothscroll"
var settings = Settings.load()

let home = FileManager.default.homeDirectoryForCurrentUser.path
let agentPlist = "\(home)/Library/LaunchAgents/\(agentLabel).plist"
let logFile = "\(home)/Library/Logs/ghostty-smoothscroll.log"
let includeLine = "config-file = ?smoothscroll.conf"

let keybinds = #"""
# Managed by ghostty-smoothscroll; `ghostty-smoothscroll uninstall` removes it.
#
# ⌘O sends Ctrl+O, so it opens Claude Code's transcript view. (In other
# windows ghostty-smoothscroll takes ⌘O for its own scroll mode.)
keybind = super+o=text:\x0f
# ghostty-smoothscroll presses these, one line per screen refresh, to scroll
# Ghostty's scrollback. (Not the arrow keys: ⌃⌥⇧⌘↓ plays the macOS alert sound.)
keybind = ctrl+alt+shift+super+page_down=scroll_page_lines:1
keybind = ctrl+alt+shift+super+page_up=scroll_page_lines:-1
keybind = ctrl+alt+shift+super+home=scroll_to_top
keybind = ctrl+alt+shift+super+end=scroll_to_bottom

"""#

// MARK: Ghostty config

/// Ghostty's main config file: the first that exists, in Ghostty's search order.
func ghosttyConfig() -> String {
    let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? "\(home)/.config"
    let candidates = [
        "\(xdg)/ghostty/config.ghostty", "\(xdg)/ghostty/config",
        "\(home)/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
        "\(home)/Library/Application Support/com.mitchellh.ghostty/config",
    ]
    return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? "\(xdg)/ghostty/config"
}

func keybindFile(for config: String) -> String {
    (config as NSString).deletingLastPathComponent + "/smoothscroll.conf"
}

func configIncludes(_ config: String) -> Bool {
    let text = (try? String(contentsOfFile: config, encoding: .utf8)) ?? ""
    return text.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == includeLine }
}

// MARK: Launch agent

/// The path to put in the launch agent: a stable one on $PATH (e.g. Homebrew's
/// bin symlink, which survives upgrades) if it points at this binary.
func stableExecutablePath() -> String {
    let me = (Bundle.main.executablePath ?? CommandLine.arguments[0]) as NSString
    let real = me.resolvingSymlinksInPath
    for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
        let candidate = "\(dir)/\(me.lastPathComponent)"
        if (candidate as NSString).resolvingSymlinksInPath == real { return candidate }
    }
    return real
}

@discardableResult
func launchctl(_ args: String...) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit()
    return p.terminationStatus
}

let guiDomain = "gui/\(getuid())"

func agentPlistData() throws -> Data {
    let plist: [String: Any] = [
        "Label": agentLabel,
        "ProgramArguments": [stableExecutablePath(), "run"],
        "RunAtLoad": true,
        "KeepAlive": true,
        "ProcessType": "Interactive",
        "StandardErrorPath": logFile,
    ]
    return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
}

func agentRunning() -> Bool { launchctl("print", "\(guiDomain)/\(agentLabel)") == 0 }

// MARK: Asking

/// Set by --yes: accept every change without asking.
var assumeYes = false

/// Explains one change and asks for a yes or no. Returns true for yes.
func confirm(_ step: String, _ title: String, _ explanation: [String]) -> Bool {
    print("\n\(step) \(title)")
    for line in explanation { print("   \(line)") }
    if assumeYes { print("   → yes (--yes)"); return true }
    while true {
        print("   Make this change? [y/n] ", terminator: "")
        fflush(stdout)
        guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else {
            print(""); return false                       // input closed: treat as no
        }
        if ["y", "yes"].contains(answer) { return true }
        if ["n", "no"].contains(answer) { return false }
    }
}

/// setup and uninstall ask before each change, so they need someone to answer.
func requireAnswers(_ command: String) {
    if assumeYes || isatty(STDIN_FILENO) != 0 { return }
    FileHandle.standardError.write("""
        ghostty-smoothscroll \(command) asks before each change, so run it in a terminal,
        or add --yes to accept every change.\n
        """.data(using: .utf8)!)
    exit(1)
}

// MARK: Commands

func setup() throws {
    requireAnswers("setup")
    let config = ghosttyConfig()
    let conf = keybindFile(for: config)
    let fm = FileManager.default
    print("Setting up ghostty-smoothscroll. It asks before each change; nothing is changed without a yes.")

    // 1. The keybinds file
    var keybindsReady = (try? String(contentsOfFile: conf, encoding: .utf8)) == keybinds
    if keybindsReady {
        print("\n1. Keybinds file for Ghostty: already in place (\(conf)).")
    } else if confirm("1.", fm.fileExists(atPath: conf) ? "Update the keybinds file for Ghostty" : "Add a keybinds file for Ghostty", [
        "\(fm.fileExists(atPath: conf) ? "Rewrites" : "Creates") \(conf), with Ghostty shortcuts:",
        "• ⌘O sends Ctrl+O, so ⌘O opens Claude Code's transcript view.",
        "• ⌃⌥⇧⌘ + Page Down / Page Up / Home / End scroll Ghostty's scrollback by",
        "  one line or to the top / bottom. ghostty-smoothscroll presses these for you;",
        "  you'd never type them yourself.",
        "This file does nothing until step 2 tells Ghostty to load it.",
    ]) {
        try fm.createDirectory(atPath: (config as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try keybinds.write(toFile: conf, atomically: true, encoding: .utf8)
        print("   Done.")
        keybindsReady = true
    } else {
        print("   Skipped. Without these shortcuts, scrolling in a plain shell won't work.")
    }

    // 2. The include line
    var includeReady = configIncludes(config)
    if includeReady {
        print("\n2. Ghostty config loads the keybinds file: already in place.")
    } else if confirm("2.", "Load the keybinds file from your Ghostty config", [
        "Adds two lines at the end of \(config):",
        "    # Smooth scrolling (ghostty-smoothscroll)",
        "    \(includeLine)",
        "Nothing else in your config changes. The ? makes Ghostty ignore the line",
        "if the keybinds file is ever missing.",
    ]) {
        var text = (try? String(contentsOfFile: config, encoding: .utf8)) ?? ""
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += "\n# Smooth scrolling (ghostty-smoothscroll)\n\(includeLine)\n"
        try text.write(toFile: config, atomically: true, encoding: .utf8)
        print("   Done.")
        includeReady = true
    } else {
        print("   Skipped. Ghostty won't know the shortcuts from step 1.")
    }

    // 3. The launch agent
    let plist = try agentPlistData()
    let existing = try? Data(contentsOf: URL(fileURLWithPath: agentPlist))
    var agentReady = existing == plist && agentRunning()
    let agentExplanation = existing == nil ? [
        "Adds a launch agent: \(agentPlist).",
        "macOS then starts ghostty-smoothscroll now and at every login, and restarts it",
        "if it stops. It only acts on keys while Ghostty is the frontmost app.",
    ] : existing == plist ? [
        "The launch agent is installed but not running. This starts it again.",
    ] : [
        "A launch agent is already installed, but it starts a different copy of",
        "ghostty-smoothscroll. This points it at \(stableExecutablePath())",
        "and restarts it.",
    ]
    let agentTitle = existing == nil ? "Run in the background and start at login"
        : existing == plist ? "Start the background process" : "Update the background launch agent"
    if agentReady {
        print("\n3. Run in the background and start at login: already in place.")
    } else if confirm("3.", agentTitle, agentExplanation) {
        try fm.createDirectory(atPath: (agentPlist as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try plist.write(to: URL(fileURLWithPath: agentPlist))
        launchctl("bootout", "\(guiDomain)/\(agentLabel)")
        let status = launchctl("bootstrap", guiDomain, agentPlist)
        print(status == 0 ? "   Done: it's running." : "   Couldn't start it (launchctl exit \(status)).")
        agentReady = status == 0
    } else {
        print("   Skipped. Start it yourself when you want it: ghostty-smoothscroll run")
    }

    // Next steps
    var next: [String] = []
    if keybindsReady && includeReady { next.append("Reload Ghostty's config: ⌘⇧, in Ghostty.") }
    if agentReady {
        next.append("""
            Allow ghostty-smoothscroll when macOS asks, or turn it on yourself in
                 \(permissionPane)
                 (`ghostty-smoothscroll permissions` opens it). It needs this to see and press
                 keys. Scrolling starts by itself once it's allowed.
            """)
    }
    if next.isEmpty { return }
    print("\nNext:")
    for (i, step) in next.enumerated() { print("  \(i + 1). \(step)") }
    print("Then press ⌘O in Ghostty and hold j / k.")
}

func uninstall() throws {
    requireAnswers("uninstall")
    let config = ghosttyConfig()
    let conf = keybindFile(for: config)
    let fm = FileManager.default
    let hasAgent = fm.fileExists(atPath: agentPlist) || agentRunning()
    let hasConf = fm.fileExists(atPath: conf)
    let hasInclude = configIncludes(config)
    if !hasAgent && !hasConf && !hasInclude {
        print("Nothing to remove: ghostty-smoothscroll isn't set up.")
    } else {
        print("Removing ghostty-smoothscroll's setup. It asks before each change.")
    }

    if hasAgent && confirm("•", "Stop it and remove the launch agent", [
        "Stops ghostty-smoothscroll and deletes \(agentPlist),",
        "so it no longer starts at login.",
    ]) {
        launchctl("bootout", "\(guiDomain)/\(agentLabel)")
        try? fm.removeItem(atPath: agentPlist)
        print("   Done.")
    }
    if hasInclude && confirm("•", "Remove the keybinds line from your Ghostty config", [
        "Deletes these lines from \(config):",
        "    # Smooth scrolling (ghostty-smoothscroll)",
        "    \(includeLine)",
        "Nothing else in your config changes.",
    ]), let text = try? String(contentsOfFile: config, encoding: .utf8) {
        // Remove exactly what setup added (with its blank line), else just the two lines.
        let block = "\n\n# Smooth scrolling (ghostty-smoothscroll)\n\(includeLine)\n"
        let cleaned = text.contains(block)
            ? text.replacingOccurrences(of: block, with: "\n")
            : text.components(separatedBy: "\n").filter {
                let t = $0.trimmingCharacters(in: .whitespaces)
                return t != includeLine && t != "# Smooth scrolling (ghostty-smoothscroll)"
            }.joined(separator: "\n")
        try cleaned.write(toFile: config, atomically: true, encoding: .utf8)
        print("   Done. Reload Ghostty's config with ⌘⇧,.")
    }
    if hasConf && confirm("•", "Delete the keybinds file", [
        "Deletes \(conf), which holds the ⌘O and scrolling shortcuts.",
    ]) {
        try? fm.removeItem(atPath: conf)
        print("   Done.")
    }
    print("""

        To remove its permission too: \(permissionPane)
        (`ghostty-smoothscroll permissions` opens it; select ghostty-smoothscroll and click −).
        """)
    if fm.fileExists(atPath: Settings.path) { print("Your settings file stays: \(Settings.path)") }
}

func status() {
    let config = ghosttyConfig()
    let conf = keybindFile(for: config)
    let running = launchctl("print", "\(guiDomain)/\(agentLabel)") == 0
    print("version         \(version)")
    print("ghostty config  \(config) \(configIncludes(config) ? "(includes smoothscroll.conf)" : "(NOT set up)")")
    print("keybinds        \(conf) \(FileManager.default.fileExists(atPath: conf) ? "" : "(missing)")")
    print("launch agent    \(FileManager.default.fileExists(atPath: agentPlist) ? agentPlist : "(not installed)")")
    print("running         \(running ? "yes" : "no")")
    print("log             \(logFile)")
    print("settings        \(Settings.path) \(FileManager.default.fileExists(atPath: Settings.path) ? "" : "(defaults; `config` creates it)")")
    print(String(format: "scroll speed    %.0f lines/s requested; on your displays (reported refresh rates):", settings.scrollSpeed))
    for (name, hz) in displays() {
        let c = Cadence(refresh: hz, speed: settings.scrollSpeed)
        let rhythm = c.framesPerStep == 1 ? "\(c.linesPerStep) line(s) every frame"
                                          : "1 line every \(c.framesPerStep) frames"
        print(String(format: "                  %@ (%.0f Hz): %.0f lines/s, %@", name, hz, c.speed(refresh: hz), rhythm))
    }
}

/// Active displays: name and refresh rate.
func displays() -> [(String, Double)] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16), count: UInt32 = 0
    guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return [] }
    return ids.prefix(Int(count)).map { id in
        let name = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }?.localizedName ?? "display \(id)"
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithCGDisplay(id, &link)
        return (name, link.map(Scroller.refreshRate(of:)) ?? 60)
    }
}

func config() throws {
    if !FileManager.default.fileExists(atPath: Settings.path) {
        try FileManager.default.createDirectory(atPath: (Settings.path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Settings.template.write(toFile: Settings.path, atomically: true, encoding: .utf8)
        print("created \(Settings.path)")
    }
    print(Settings.path)
}

/// For testing by hand or by script: `_key <j|k|d|u|g|o|q> <hold seconds> [cmd]`
/// presses a key in Ghostty as if typed (ghostty-smoothscroll's own tap sees it).
/// Refuses unless Ghostty is the frontmost app.
func testKey(_ args: [String]) {
    let codes: [String: CGKeyCode] = ["j": 38, "k": 40, "d": 2, "u": 32, "g": 5, "o": 31, "q": 12]
    guard args.count >= 2, let code = codes[args[0]], let hold = Double(args[1]) else {
        print("usage: ghostty-smoothscroll _key <j|k|d|u|g|o|q> <hold seconds> [cmd]"); exit(2)
    }
    guard ghosttyIsFrontmost() else { print("Ghostty isn't the frontmost app; not pressing anything"); exit(1) }
    let src = CGEventSource(stateID: .privateState)
    let flags: CGEventFlags = args.count > 2 && args[2] == "cmd" ? .maskCommand : []
    func post(_ down: Bool) {
        let ev = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
        ev?.flags = flags
        ev?.post(tap: .cghidEventTap)
    }
    post(true)
    // Autorepeat, as a held key would: the daemon releases a hold that goes quiet.
    let end = Date().addingTimeInterval(hold)
    Thread.sleep(forTimeInterval: min(hold, NSEvent.keyRepeatDelay))
    while Date() < end {
        let ev = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
        ev?.flags = flags
        ev?.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        ev?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: min(0.033, end.timeIntervalSinceNow))
    }
    post(false)
}

func run() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)    // no Dock icon; the ⇅ menu bar item only
    let daemon = Daemon()
    daemon.start()
    withExtendedLifetime(daemon) { app.run() }
    exit(0)
}

let arguments = CommandLine.arguments.dropFirst()
assumeYes = arguments.contains("--yes") || arguments.contains("-y")
let command = arguments.first { !$0.hasPrefix("-") } ?? "help"
do {
    switch command {
    case "run": run()
    case "setup": try setup()
    case "uninstall": try uninstall()
    case "status": status()
    case "config": try config()
    case "permissions": openPermissionPane(); print("opened \(permissionPane)")
    case "_key": testKey(Array(CommandLine.arguments.dropFirst(2)))
    case "version", "--version": print(version)
    default:
        print("""
            ghostty-smoothscroll \(version): smooth, Vimium-style scrolling for Ghostty.

              setup        add the Ghostty keybinds and start in the background at login
                           (asks before each change; --yes accepts them all)
              uninstall    undo setup (asks the same way)
              status       show what is installed and running
              config       create the settings file (if missing) and show its path
              permissions  open the System Settings pane for its permission
              run          the background process itself (setup starts it for you)

            In Ghostty: ⌘O enters scroll mode. Hold j / k to scroll, d / u for a page,
            g / G for top / bottom, q or Esc to leave. In a Claude Code window ⌘O opens
            the transcript view and the same keys scroll it smoothly.
            """)
    }
} catch {
    FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
