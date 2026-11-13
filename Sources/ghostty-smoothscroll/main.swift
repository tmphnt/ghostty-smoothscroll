// ghostty-smoothscroll: Vimium-style smooth scrolling for Ghostty on macOS.
//
//   ghostty-smoothscroll setup      add the Ghostty keybinds and start at login
//   ghostty-smoothscroll uninstall  undo `setup`
//   ghostty-smoothscroll status     show what is installed and running
//   ghostty-smoothscroll run        the background process (started by `setup`)

import AppKit

let version = "0.1.0"
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

func writeAgent() throws {
    let plist: [String: Any] = [
        "Label": agentLabel,
        "ProgramArguments": [stableExecutablePath(), "run"],
        "RunAtLoad": true,
        "KeepAlive": true,
        "ProcessType": "Interactive",
        "StandardErrorPath": logFile,
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try FileManager.default.createDirectory(atPath: (agentPlist as NSString).deletingLastPathComponent,
                                            withIntermediateDirectories: true)
    try data.write(to: URL(fileURLWithPath: agentPlist))
}

// MARK: Commands

func setup() throws {
    let config = ghosttyConfig()
    let conf = keybindFile(for: config)
    try FileManager.default.createDirectory(atPath: (config as NSString).deletingLastPathComponent,
                                            withIntermediateDirectories: true)
    try keybinds.write(toFile: conf, atomically: true, encoding: .utf8)
    print("wrote \(conf)")
    if !configIncludes(config) {
        var text = (try? String(contentsOfFile: config, encoding: .utf8)) ?? ""
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += "\n# Smooth scrolling (ghostty-smoothscroll)\n\(includeLine)\n"
        try text.write(toFile: config, atomically: true, encoding: .utf8)
        print("added `\(includeLine)` to \(config)")
    }

    try writeAgent()
    launchctl("bootout", "\(guiDomain)/\(agentLabel)")
    let status = launchctl("bootstrap", guiDomain, agentPlist)
    print(status == 0 ? "started the background process (it also starts at login)"
                      : "could not start the launch agent (launchctl exit \(status))")
    print("""

        Next:
          1. Reload Ghostty's config: ⌘⇧, in Ghostty.
          2. Allow Accessibility when macOS asks (System Settings → Privacy & Security
             → Accessibility → ghostty-smoothscroll). Scrolling starts by itself once
             it's allowed.
        Then press ⌘O in Ghostty and hold j / k.
        """)
}

func uninstall() throws {
    launchctl("bootout", "\(guiDomain)/\(agentLabel)")
    try? FileManager.default.removeItem(atPath: agentPlist)
    print("stopped and removed the launch agent")
    let config = ghosttyConfig()
    try? FileManager.default.removeItem(atPath: keybindFile(for: config))
    if configIncludes(config), let text = try? String(contentsOfFile: config, encoding: .utf8) {
        let kept = text.components(separatedBy: "\n").filter {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t != includeLine && t != "# Smooth scrolling (ghostty-smoothscroll)"
        }
        try kept.joined(separator: "\n").write(toFile: config, atomically: true, encoding: .utf8)
    }
    print("removed the keybinds from \(config). Reload Ghostty's config with ⌘⇧,.")
    print("You can also remove ghostty-smoothscroll from System Settings → Privacy & Security → Accessibility.")
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
    print("settings        \(Settings.path) \(FileManager.default.fileExists(atPath: Settings.path) ? "" : "(defaults)")")
}

func run() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)    // no Dock icon; the ⇅ menu bar item only
    let daemon = Daemon()
    daemon.start()
    withExtendedLifetime(daemon) { app.run() }
    exit(0)
}

let command = CommandLine.arguments.dropFirst().first ?? "help"
do {
    switch command {
    case "run": run()
    case "setup": try setup()
    case "uninstall": try uninstall()
    case "status": status()
    case "version", "--version": print(version)
    default:
        print("""
            ghostty-smoothscroll \(version): smooth, Vimium-style scrolling for Ghostty.

              setup      add the Ghostty keybinds and start in the background at login
              uninstall  undo setup
              status     show what is installed and running
              run        the background process itself (setup starts it for you)

            In Ghostty: ⌘O enters scroll mode. Hold j / k to scroll, d / u for a page,
            g / G for top / bottom, q or Esc to leave. In a Claude Code window ⌘O opens
            the transcript view and the same keys scroll it smoothly.
            """)
    }
} catch {
    FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
