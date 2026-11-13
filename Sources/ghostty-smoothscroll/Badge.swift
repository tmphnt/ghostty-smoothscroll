// The SCROLL badge: a small label in the bottom-right corner of the Ghostty
// window while plain-terminal scroll mode is on. It's a separate see-through
// window that floats over Ghostty and ignores the mouse. (Claude Code's
// transcript view shows its own header, so it isn't used there.)

import AppKit

final class Badge {
    private var panel: NSPanel?
    private let inset: CGFloat = 12

    /// Show the badge over a window. `frame` is in global coordinates with the
    /// origin at the top-left of the main display (as Accessibility reports it).
    func show(over frame: CGRect) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = panel.frame.size
        // Cocoa puts the origin at the bottom-left of the main display.
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let origin = NSPoint(x: frame.maxX - size.width - inset,
                             y: mainHeight - frame.maxY + inset)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    private func makePanel() -> NSPanel {
        let label = NSTextField(labelWithString: "SCROLL")
        label.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.sizeToFit()

        let padX: CGFloat = 9, padY: CGFloat = 4
        let size = NSSize(width: label.frame.width + 2 * padX, height: label.frame.height + 2 * padY)
        let box = NSView(frame: NSRect(origin: .zero, size: size))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        box.layer?.cornerRadius = size.height / 2
        label.setFrameOrigin(NSPoint(x: padX, y: padY))
        box.addSubview(label)

        let panel = NSPanel(contentRect: box.frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.contentView = box
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        return panel
    }
}
