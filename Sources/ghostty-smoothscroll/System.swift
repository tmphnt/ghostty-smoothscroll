// Small wrappers around macOS APIs: the focused Ghostty window (Accessibility),
// the keyboard layout, and the settings file.

import AppKit
import ApplicationServices
import Carbon

let ghosttyBundleID = "com.mitchellh.ghostty"

// Private but long-stable (Hammerspoon, yabai and others rely on it).
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

struct GhosttyWindow {
    let id: CGWindowID
    let title: String
    /// Global coordinates, origin at the top-left of the main display.
    let frame: CGRect

    /// Claude Code sets the window title to start with ◐ / ◑ (working) or ✳ (idle).
    var runsClaudeCode: Bool {
        ["◐ ", "◑ ", "✳ "].contains { title.hasPrefix($0) }
    }

    /// The display the window is (mostly) on.
    var displayID: CGDirectDisplayID? {
        var id: CGDirectDisplayID = 0, count: UInt32 = 0
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard CGGetDisplaysWithPoint(center, 1, &id, &count) == .success, count > 0 else { return nil }
        return id
    }
}

func ghosttyIsFrontmost() -> Bool {
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ghosttyBundleID
}

/// The focused window of Ghostty, if Ghostty is the frontmost app.
func focusedGhosttyWindow() -> GhosttyWindow? {
    guard let app = NSWorkspace.shared.frontmostApplication,
          app.bundleIdentifier == ghosttyBundleID else { return nil }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(axApp, 0.2)   // never stall the key tap for long
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value) == .success,
          let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    let window = value as! AXUIElement

    var id: CGWindowID = 0
    _ = _AXUIElementGetWindow(window, &id)

    var title: CFTypeRef?
    AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)

    var origin = CGPoint.zero, size = CGSize.zero
    var pos: CFTypeRef?, sz: CFTypeRef?
    if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &pos) == .success, let pos {
        AXValueGetValue(pos as! AXValue, .cgPoint, &origin)
    }
    if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sz) == .success, let sz {
        AXValueGetValue(sz as! AXValue, .cgSize, &size)
    }
    return GhosttyWindow(id: id, title: (title as? String) ?? "", frame: CGRect(origin: origin, size: size))
}

// MARK: Keyboard layout

/// What a key types with no modifiers in the current layout ("j", "o", …), so
/// the j/k/d/u keys follow the letters on non-QWERTY layouts too.
enum KeyNames {
    private static var cache: [UInt16: String] = [:]
    private static var observer: NSObjectProtocol?

    static func name(_ code: UInt16) -> String? {
        switch code {
        case 53: return "escape"
        case 49: return "space"
        default: break
        }
        if observer == nil {
            observer = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                object: nil, queue: .main) { _ in cache.removeAll() }
        }
        if let hit = cache[code] { return hit }
        let s = translate(code)
        cache[code] = s ?? ""
        return s
    }

    private static func translate(_ code: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { buf -> OSStatus in
            guard let base = buf.baseAddress else { return OSStatus(paramErr) }
            return UCKeyTranslate(base.assumingMemoryBound(to: UCKeyboardLayout.self), code,
                                  UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys,
                                  chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: length)
        return s.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) ? s : nil
    }
}

// MARK: Settings

/// ~/.config/ghostty-smoothscroll/config, lines of `key = value`. All optional.
struct Settings {
    var scrollSpeed = 60.0      // lines per second while j / k is held (snaps to the display's rhythm)
    var tapLines = 3            // a quick tap of j / k scrolls at least this many lines
    var pageDuration = 0.4      // seconds a d / u page takes
    var cellHeight = 17.0       // points per terminal row (17 ≈ a 14 pt font)
    var claudeChromeRows = 8    // rows Claude Code keeps for its prompt and footer
    var debug = false           // log decisions to stderr

    static let path = NSString(string: "~/.config/ghostty-smoothscroll/config").expandingTildeInPath

    static let template = """
        # ghostty-smoothscroll settings. Changes apply the next time you press ⌘O.

        # Lines per second while j / k is held. It snaps to a speed that stays
        # smooth on each display: at 120 Hz, 60 = one line every 2nd frame; at
        # 60 Hz, 60 = one line every frame and 120 = two lines every frame.
        # `ghostty-smoothscroll status` shows the result for your displays.
        scroll-speed = 60

        # Lines a quick tap of j / k scrolls.
        tap-lines = 3

        # Seconds a d / u page takes.
        page-duration = 0.4

        # Points per terminal row, used to size a page: about 1.2 × your font size.
        cell-height = 17

        # Rows Claude Code keeps for its prompt and footer (not scrolled by a page).
        claude-chrome-rows = 8

        # Log decisions to ~/Library/Logs/ghostty-smoothscroll.log.
        debug = false

        """

    static func load() -> Settings {
        var s = Settings()
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return s }
        for raw in text.split(separator: "\n") {
            let line = raw.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "scroll-speed": s.scrollSpeed = Double(parts[1]) ?? s.scrollSpeed
            case "tap-lines": s.tapLines = Int(parts[1]) ?? s.tapLines
            case "page-duration": s.pageDuration = Double(parts[1]) ?? s.pageDuration
            case "cell-height": s.cellHeight = Double(parts[1]) ?? s.cellHeight
            case "claude-chrome-rows": s.claudeChromeRows = Int(parts[1]) ?? s.claudeChromeRows
            case "debug": s.debug = parts[1] == "true"
            default: break
            }
        }
        return s
    }
}

func log(_ message: @autoclosure () -> String) {
    guard settings.debug else { return }
    let t = String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
    FileHandle.standardError.write("\(t) \(message())\n".data(using: .utf8)!)
}
