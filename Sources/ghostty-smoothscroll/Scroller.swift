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
    private var speed = 60.0, frameCount = 0
    // Measured frame interval (seconds, smoothed). The reported refresh rate
    // isn't trusted: ProMotion and variable-refresh displays may report one rate
    // and run another.
    private var measuredInterval = 0.0, lastFrame = 0.0
    private var paging = false, pageTotal = 0, pageSent = 0
    private var pageStart = 0.0, pageDuration = 0.4

    init() { makeLink() }

    // MARK: Commands (main thread)

    /// Sync to this display's refresh rate.
    func setDisplay(_ id: CGDirectDisplayID) {
        guard id != displayID else { return }
        displayID = id
        lock.lock(); measuredInterval = 0; lock.unlock()
        if let link, CVDisplayLinkSetCurrentCGDisplay(link, id) == kCVReturnSuccess { return }
        makeLink()
    }

    /// Start scrolling at about `speed` lines per second until `release()`, and
    /// at least `tapLines` lines.
    func press(dir d: Int, tapLines: Int, speed: Double, target t: ScrollTarget) {
        lock.lock()
        let hz = currentRefresh()
        let c = Cadence(refresh: hz, speed: speed)
        paging = false; dir = d; held = true; minLeft = tapLines; target = t
        self.speed = speed
        frameCount = c.framesPerStep - 1     // the first line goes out on the next frame
        lock.unlock()
        log(String(format: "hold: %.0f Hz (%@), %d line(s) every %d frame(s) = %.0f lines/s",
                   hz, measuredInterval > 0 ? "measured" : "reported", c.linesPerStep, c.framesPerStep,
                   c.speed(refresh: hz)))
        start()
    }

    /// Frames per second: measured if we have it, else what the display reports. Call with `lock` held.
    private func currentRefresh() -> Double {
        if measuredInterval > 0 { return 1 / measuredInterval }
        guard let link else { return 60 }
        return Scroller.refreshRate(of: link)
    }

    static func refreshRate(of link: CVDisplayLink) -> Double {
        let t = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(link)
        guard t.flags & Int32(CVTimeFlags.isIndefinite.rawValue) == 0, t.timeValue > 0 else { return 60 }
        return Double(t.timeScale) / Double(t.timeValue)
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
        let gap = t - lastFrame
        lastFrame = t
        if gap > 0.003 && gap < 0.05 {       // ignore the gap across a stop
            measuredInterval = measuredInterval == 0 ? gap : measuredInterval * 0.9 + gap * 0.1
        }
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
                let cadence = Cadence(refresh: currentRefresh(), speed: speed)
                frameCount += 1
                if frameCount >= cadence.framesPerStep {
                    frameCount = 0
                    lines += dir * cadence.linesPerStep
                    minLeft = max(0, minLeft - cadence.linesPerStep)
                }
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

/// How a hold speed maps onto display frames. Smoothness needs a steady rhythm,
/// so the speed snaps to one that divides evenly into frames: one line every N
/// frames when slower than the refresh rate, N lines every frame when faster.
/// E.g. 60 lines/s is one line every 2nd frame at 120 Hz, every frame at 60 Hz.
struct Cadence {
    let framesPerStep: Int
    let linesPerStep: Int

    init(framesPerStep: Int, linesPerStep: Int) {
        self.framesPerStep = framesPerStep; self.linesPerStep = linesPerStep
    }

    init(refresh: Double, speed: Double) {
        let s = max(1, speed)
        if s >= refresh {
            self.init(framesPerStep: 1, linesPerStep: max(1, Int((s / refresh).rounded())))
        } else {
            self.init(framesPerStep: max(1, Int((refresh / s).rounded())), linesPerStep: 1)
        }
    }

    func speed(refresh: Double) -> Double { refresh * Double(linesPerStep) / Double(framesPerStep) }
}
