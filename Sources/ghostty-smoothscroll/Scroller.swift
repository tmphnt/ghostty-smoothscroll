// The frame clock: moves the view one line per display refresh, in step with
// the screen the Ghostty window is on. Whole lines at a steady rhythm are what
// look smooth in a terminal; bursts of several lines per frame look choppy.

import Foundation
import CoreGraphics
import CoreVideo

/// Every event we post carries this tag, so our own key tap ignores it.
let eventMark: Int64 = 0x5C5C

enum ScrollTarget {
    /// Plain ↓ / ↑ arrow keys: Claude Code's transcript view scrolls a line per arrow.
    case arrows
    /// ⌃⌥⇧⌘ + Page Down / Page Up, which `smoothscroll.conf` binds to Ghostty's
    /// `scroll_page_lines:±1` (its own scrollback). Not ⌃⌥⇧⌘ + arrows: on macOS
    /// ⌃⌥⇧⌘↓ plays the system alert sound on every press.
    case ghostty
}

enum KeyCode {
    static let downArrow: CGKeyCode = 125, upArrow: CGKeyCode = 126
    static let pageDown: CGKeyCode = 121, pageUp: CGKeyCode = 116
    static let home: CGKeyCode = 115, end: CGKeyCode = 119
}

private let hyper: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
// A private source, and explicit modifiers on every event: with the shared
// .hidSystemState source the ⌃⌥⇧⌘ of the scrollback keys "stuck", and the plain
// arrows for Claude Code went out as ⌃⌥⇧⌘ + arrow.
private let eventSource = CGEventSource(stateID: .privateState)

func postKey(_ code: CGKeyCode, hyper useHyper: Bool) {
    for down in [true, false] {
        guard let ev = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: down) else { continue }
        ev.flags = useHyper ? hyper : []
        ev.setIntegerValueField(.eventSourceUserData, value: eventMark)
        ev.post(tap: .cghidEventTap)
    }
}

final class Scroller {
    private let lock = NSLock()
    private var link: CVDisplayLink?
    private var displayID = CGMainDisplayID()

    // Shared with the display-link thread; guarded by `lock`.
    private var target = ScrollTarget.arrows
    private var dir = 0, held = false, minLeft = 0
    private var paging = false, pageTotal = 0, pageSent = 0
    private var pageStart = 0.0, pageDuration = 0.4

    init() { makeLink() }

    // MARK: Commands (main thread)

    /// Sync to this display's refresh rate.
    func setDisplay(_ id: CGDirectDisplayID) {
        guard id != displayID else { return }
        displayID = id
        if let link, CVDisplayLinkSetCurrentCGDisplay(link, id) == kCVReturnSuccess { return }
        makeLink()
    }

    /// Start scrolling one line per frame until `release()`, and at least `tapLines` lines.
    func press(dir d: Int, tapLines: Int, target t: ScrollTarget) {
        lock.lock(); paging = false; dir = d; held = true; minLeft = tapLines; target = t; lock.unlock()
        start()
    }

    func release() {
        lock.lock(); held = false; lock.unlock()
    }

    /// Animate a signed number of lines with ease-in-out.
    func page(lines: Int, seconds: Double, target t: ScrollTarget) {
        lock.lock()
        var add = lines
        let remaining = paging ? pageTotal - pageSent : 0
        // Same direction: fold what's left into the new scroll. Opposite: replace it.
        if remaining != 0 && (remaining > 0) == (add > 0) { add += remaining }
        dir = 0; paging = true; pageTotal = add; pageSent = 0; target = t
        pageStart = now(); pageDuration = max(0.05, seconds)
        lock.unlock()
        start()
    }

    func stop() {
        lock.lock(); paging = false; dir = 0; held = false; lock.unlock()
    }

    /// Ghostty scrollback only: jump to the top or bottom.
    func jump(toTop: Bool) {
        stop()
        postKey(toTop ? KeyCode.home : KeyCode.end, hyper: true)
    }

    /// After sleep the old display link can be stale; build a fresh one.
    func reset() {
        stop()
        makeLink()
    }

    // MARK: Frame clock

    private func now() -> Double { ProcessInfo.processInfo.systemUptime }

    private func makeLink() {
        if let link { CVDisplayLinkStop(link) }
        link = nil
        if CVDisplayLinkCreateWithCGDisplay(displayID, &link) != kCVReturnSuccess || link == nil {
            displayID = CGMainDisplayID()
            CVDisplayLinkCreateWithCGDisplay(displayID, &link)
        }
        guard let link else { return }
        CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
            self?.frame()
            return kCVReturnSuccess
        }
    }

    private func start() {
        if let link, CVDisplayLinkIsRunning(link) { return }
        if let link, CVDisplayLinkStart(link) == kCVReturnSuccess { return }
        makeLink()
        if let link { CVDisplayLinkStart(link) }
    }

    private func frame() {
        let t = now()
        lock.lock()
        var lines = 0
        if paging {
            let x = min(1, (t - pageStart) / pageDuration)
            let eased = (1 - cos(Double.pi * x)) / 2
            let goal = Int((Double(pageTotal) * eased).rounded())
            lines += goal - pageSent
            pageSent = goal
            if x >= 1 { paging = false }
        }
        if dir != 0 {
            if held || minLeft > 0 {
                lines += dir
                minLeft = max(0, minLeft - 1)
            } else {
                dir = 0
            }
        }
        let tgt = target
        let idle = !paging && dir == 0
        lock.unlock()

        if lines != 0 {
            let code: CGKeyCode
            switch tgt {
            case .arrows: code = lines > 0 ? KeyCode.downArrow : KeyCode.upArrow
            case .ghostty: code = lines > 0 ? KeyCode.pageDown : KeyCode.pageUp
            }
            for _ in 0..<abs(lines) { postKey(code, hyper: tgt == .ghostty) }
        }
        if idle { DispatchQueue.main.async { self.stopIfIdle() } }
    }

    private func stopIfIdle() {
        lock.lock(); let idle = !paging && dir == 0; lock.unlock()
        if idle, let link, CVDisplayLinkIsRunning(link) { CVDisplayLinkStop(link) }
    }
}
