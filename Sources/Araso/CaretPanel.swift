import ArasoCore
import Cocoa

/// A small panel under the caret that never takes focus or clicks: what PauseHUD, the readings
/// a switch key goes through and the note that a word was learned are shown in.
@MainActor enum CaretPanel {
    static func make(size: NSSize) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }

    /// Just under the caret's line (above it near the bottom of the screen), kept on screen:
    /// centered on the caret, or starting where it does. Without a caret, near the top of the
    /// screen the mouse is on.
    static func origin(for size: NSSize, caret: NSRect, gap: CGFloat, centered: Bool) -> NSPoint {
        let anchor = caret == .zero ? NSEvent.mouseLocation : caret.origin
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return anchor }
        var point: NSPoint
        if caret == .zero {
            point = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 40)
        } else {
            let x = centered ? caret.midX.rounded() - size.width / 2 : caret.minX.rounded()
            point = NSPoint(x: x, y: caret.minY - gap - size.height)
            if point.y < visible.minY { point.y = caret.maxY + gap }
        }
        point.x = min(max(point.x, visible.minX), visible.maxX - size.width)
        point.y = min(max(point.y, visible.minY), visible.maxY - size.height)
        return point
    }
}

/// The readings a switch key goes through for the word it changed, listed under the word with
/// the one on screen highlighted, until the next key (`InputSession.readings`): how many more
/// presses reach the one wanted.
@MainActor enum ReadingsHUD {
    private static var panel: NSPanel?
    private static let gap: CGFloat = 4

    /// `caret` is the word's line in screen coordinates; without one (`.zero`) nothing is shown,
    /// since a list away from the word says little.
    static func show(_ readings: InputSession.Readings, caret: NSRect) {
        guard caret != .zero else { return hide() }
        let panel = panel ?? CaretPanel.make(size: .zero)
        self.panel = panel
        let content = makeContent(readings)
        let size = content.fittingSize
        panel.contentView = content
        panel.setFrame(NSRect(origin: CaretPanel.origin(for: size, caret: caret, gap: gap, centered: false), size: size),
                       display: true)
        panel.orderFrontRegardless()
    }

    static func hide() { panel?.orderOut(nil) }

    private static func makeContent(_ readings: InputSession.Readings) -> NSView {
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.separatorColor.cgColor

        let stack = NSStackView(views: readings.texts.enumerated().map { index, text in
            item(text, selected: index == readings.selected)
        })
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        background.setAccessibilityRole(.list)
        background.setAccessibilityLabel(readings.texts.indices.contains(readings.selected)
                                         ? L("Readings, %@ selected", readings.texts[readings.selected]) : nil)
        return background
    }

    /// One reading; the one on screen in the accent color, as a selected row is.
    private static func item(_ text: String, selected: Bool) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14)
        label.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 5
        box.layer?.cornerCurve = .continuous
        box.layer?.backgroundColor = selected ? NSColor.controlAccentColor.cgColor : nil
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
        ])
        return box
    }
}

/// A word learned for good just now (`InputSession.learned`), said for a moment under the caret
/// in the system indicator's colors, as PauseHUD is: from here on it goes in that way, and the
/// input menu's undo takes it back.
@MainActor enum LearnedHUD {
    private static var panel: NSPanel?
    private static var label: NSTextField?
    private static var shown = 0
    private static let height: CGFloat = 23
    private static let gap: CGFloat = 4

    static func show(_ learned: InputSession.Learned, caret: NSRect) {
        guard caret != .zero else { return }
        let (panel, label) = make()
        label.stringValue = L("%@ → always %@", learned.text, learned.language.displayName)
        label.setAccessibilityLabel(label.stringValue)
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        panel.contentView?.layer?.backgroundColor = NSColor(displayP3Red: accent.redComponent, green: accent.greenComponent,
                                                            blue: accent.blueComponent, alpha: 1).cgColor
        let size = NSSize(width: ceil(label.intrinsicContentSize.width) + 24, height: height)
        panel.setFrame(NSRect(origin: CaretPanel.origin(for: size, caret: caret, gap: gap, centered: true), size: size),
                       display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        shown += 1
        let current = shown
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            guard current == shown else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 }) {
                MainActor.assumeIsolated { if current == shown { panel.orderOut(nil) } }
            }
        }
    }

    static func hide() {
        shown += 1
        panel?.orderOut(nil)
    }

    private static func make() -> (NSPanel, NSTextField) {
        if let panel, let label { return (panel, label) }
        let panel = CaretPanel.make(size: NSSize(width: 0, height: height))
        let capsule = NSView()
        capsule.wantsLayer = true
        capsule.layer?.cornerRadius = height / 2
        capsule.layer?.cornerCurve = .continuous
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        capsule.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: capsule.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
        ])
        panel.contentView = capsule
        self.panel = panel
        self.label = label
        return (panel, label)
    }
}
