// The background process: watches keys in Ghostty and drives the Scroller.
//
// Scroll mode, per Ghostty window:
//   ⌘O in a Claude Code window   Claude Code opens its transcript view (⌘O is
//                                sent on as Ctrl+O); j/k/d/u then scroll it
//                                smoothly. q, Esc, Ctrl+C or ⌘O leave it.
//   ⌘O in any other window       scroll mode for Ghostty's own scrollback. g / G
//                                go to the top / bottom. q, Esc or ⌘O leave it;
//                                typing anything else leaves it and types.
//   hold j / k                   scroll one line per frame until released
//   d / u                        one page down / up, eased
// While it's on, ⇅ shows in the menu bar.

import AppKit

enum Mode { case claude, shell }

final class Daemon {
    private let scroller = Scroller()
    private var tap: CFMachPort?
    private var active: [CGWindowID: Mode] = [:]
    private var indicator: NSStatusItem?

    private var heldKey: String?
    private var heldLastSeen = 0.0
    private var holdWatch: Timer?
    // If the key-up never arrives (focus moved mid-hold), let go once the key
    // has been quiet for longer than the key-repeat delay.
    private let holdTimeout = NSEvent.keyRepeatDelay + 0.25

    private let lineKeys = ["j": 1, "k": -1]
    private let pageKeys = ["d": 1, "u": -1]
    /// Keys Claude Code's transcript view uses; any other letter means we lost track.
    private let transcriptKeys: Set<String> = ["j", "k", "d", "u", "g", "b", "q", "space"]

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            log("wake: fresh tap and frame clock")
            self?.releaseHold()
            self?.scroller.reset()
            self?.installTap()
        }
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if ghosttyIsFrontmost() {
                self.refreshIndicator(focusedGhosttyWindow().flatMap { self.active[$0.id] })
            } else {
                self.refreshIndicator(nil)
                self.stopAll()            // never keep pressing keys into another app
            }
        }
        // macOS switches off a tap it thinks is slow; the callback re-enables it,
        // and this catches anything that slips through.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let tap = self?.tap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
        }
        waitForAccessibility { [weak self] in self?.installTap() }
    }

    // MARK: Permission

    private func waitForAccessibility(then go: @escaping () -> Void) {
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(prompt) { go(); return }
        FileHandle.standardError.write("""
            ghostty-smoothscroll needs permission to read and send keys: \(permissionPane). \
            Waiting for it…\n
            """.data(using: .utf8)!)
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { timer in
            if AXIsProcessTrusted() { timer.invalidate(); go() }
        }
    }

    // MARK: Event tap

    private func installTap() {
        if let old = tap {
            CGEvent.tapEnable(tap: old, enable: false)
            CFMachPortInvalidate(old)
            tap = nil
        }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                           callback: { _, type, event, info in
            let daemon = Unmanaged<Daemon>.fromOpaque(info!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = daemon.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            return daemon.handle(type, event) ? nil : Unmanaged.passUnretained(event)
        }, userInfo: me) else {
            FileHandle.standardError.write("could not create the key tap\n".data(using: .utf8)!)
            return
        }
        tap = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        log("key tap installed")
    }

    /// Returns true to swallow the event.
    private func handle(_ type: CGEventType, _ ev: CGEvent) -> Bool {
        if ev.getIntegerValueField(.eventSourceUserData) == eventMark { return false }
        guard ghosttyIsFrontmost(), let win = focusedGhosttyWindow() else { return false }

        let key = KeyNames.name(UInt16(ev.getIntegerValueField(.keyboardEventKeycode))) ?? ""
        let f = ev.flags
        let cmd = f.contains(.maskCommand), ctrl = f.contains(.maskControl)
        let alt = f.contains(.maskAlternate), shift = f.contains(.maskShift)
        let fn = f.contains(.maskSecondaryFn)
        let down = type == .keyDown
        let rep = ev.getIntegerValueField(.keyboardEventAutorepeat) == 1
        let plain = !(cmd || ctrl || alt || shift || fn)
        let mode = active[win.id]
        let shell = mode == .shell
        refreshIndicator(mode)

        if key == "o" && (cmd || ctrl) && !(alt || shift) {
            if rep { return shell || (mode == nil && cmd && !win.runsClaudeCode) }
            if down {
                if mode != nil {
                    setMode(win, nil)
                    return shell                       // leaving shell mode: don't send Ctrl+O
                } else if win.runsClaudeCode {
                    setMode(win, .claude)
                    return false                       // let Claude Code open its transcript
                } else if cmd {
                    setMode(win, .shell)
                    return true                        // plain shell: ⌘O is ours
                }
            }
            return shell
        }

        if down && !rep && mode != nil {
            if plain && (key == "q" || key == "escape") {
                setMode(win, nil); return shell        // shell mode: don't type the q
            }
            if key == "c" && ctrl { setMode(win, nil); return false }
        }
        guard let mode else { return false }

        if shell && down && !rep && key == "g" && !(cmd || ctrl || alt) {
            releaseHold()
            scroller.jump(toTop: !shift)
            return true
        }

        if plain, let dir = lineKeys[key] {
            if down && !rep {
                press(key, dir: dir, mode: mode, win: win)
            } else if down && rep {
                if heldKey == key { heldLastSeen = now() }
            } else if heldKey == key {
                releaseHold()
            }
            return true
        }

        if plain, let dir = pageKeys[key] {
            if down && !rep { page(dir: dir, mode: mode, win: win) }
            return true
        }

        if shell {
            if down && !(cmd || ctrl || alt) { setMode(win, nil) }   // typing again: back to normal
            return false
        }
        if down && plain && key.count == 1 && !transcriptKeys.contains(key) {
            setMode(win, nil)                          // you're typing: lost track
        }
        return false
    }

    // MARK: Scrolling

    private func now() -> Double { ProcessInfo.processInfo.systemUptime }
    private func target(_ mode: Mode) -> ScrollTarget { mode == .shell ? .ghostty : .arrows }

    private func press(_ key: String, dir: Int, mode: Mode, win: GhosttyWindow) {
        if let d = win.displayID { scroller.setDisplay(d) }
        heldKey = key; heldLastSeen = now()
        log("press \(key) (\(mode))")
        scroller.press(dir: dir, tapLines: settings.tapLines, speed: settings.scrollSpeed, target: target(mode))
        holdWatch?.invalidate()
        holdWatch = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.heldKey != nil, self.now() - self.heldLastSeen > self.holdTimeout else { return }
            log("key-up lost, releasing")
            self.releaseHold()
        }
    }

    private func releaseHold() {
        heldKey = nil
        holdWatch?.invalidate(); holdWatch = nil
        scroller.release()
    }

    private func page(dir: Int, mode: Mode, win: GhosttyWindow) {
        releaseHold()
        if let d = win.displayID { scroller.setDisplay(d) }
        let rows = Int((win.frame.height - 28) / settings.cellHeight)
        let lines = mode == .shell ? max(4, rows - 1) : max(4, rows - settings.claudeChromeRows)
        log("page \(dir * lines) (\(mode))")
        scroller.page(lines: dir * lines, seconds: settings.pageDuration, target: target(mode))
    }

    private func stopAll() {
        heldKey = nil
        holdWatch?.invalidate(); holdWatch = nil
        scroller.stop()
    }

    // MARK: Mode and indicator

    private func setMode(_ win: GhosttyWindow, _ mode: Mode?) {
        log("mode \(String(describing: active[win.id])) -> \(String(describing: mode)) (\(win.title))")
        active[win.id] = mode
        if mode == nil { stopAll() } else { settings = Settings.load() }   // pick up edits
        refreshIndicator(mode)
    }

    private func refreshIndicator(_ mode: Mode?) {
        if let mode {
            if indicator == nil {
                indicator = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                indicator?.button?.title = "⇅"
            }
            indicator?.button?.toolTip = mode == .shell
                ? "Smooth scrolling on (terminal scrollback)"
                : "Smooth scrolling on (Claude Code transcript view)"
        } else if let item = indicator {
            NSStatusBar.system.removeStatusItem(item)
            indicator = nil
        }
    }
}
