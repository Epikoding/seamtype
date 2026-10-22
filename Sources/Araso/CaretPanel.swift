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

/// Lays its subviews out top-down, as the lists below are read.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private extension Language {
    /// The short tag a reading carries in the list.
    var readingTag: String {
        switch self {
        case .english: return L("EN")
        case .korean: return L("KO")
        case .japanese: return L("JA")
        case .mixed: return L("MIX")
        }
    }
}

/// Motion keeps out of the way of typing: each animation is short, and none when the user
/// asked the system for less motion.
@MainActor private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

@MainActor private func animate(_ duration: TimeInterval, _ curve: CAMediaTimingFunction? = nil,
                                _ changes: @escaping () -> Void, done: (() -> Void)? = nil) {
    NSAnimationContext.runAnimationGroup({ context in
        context.duration = reduceMotion ? 0 : duration
        context.timingFunction = curve
        context.allowsImplicitAnimation = true
        changes()
    }, completionHandler: { MainActor.assumeIsolated { done?() } })
}

/// A little past the target and back: things land rather than stop.
private let springy = CAMediaTimingFunction(controlPoints: 0.3, 1.4, 0.5, 1)

/// The readings a switch key goes through for the word it changed, a list dropped under the
/// word with each reading's language and the one on screen highlighted, until the next key
/// (`InputSession.readings`). Rows fall in one after another; on the next switch the highlight
/// springs to its row, and only the highlight moves: the readings stay still, so fast presses
/// leave them readable. Everything is over in about 0.2 s, and the next key cuts it short: the
/// user is in the middle of typing.
@MainActor enum ReadingsHUD {
    private static var panel: NSPanel?
    private static var shown: InputSession.Readings?
    private static var highlight: NSView?
    private static var rows: [(view: NSView, tag: NSTextField, text: NSTextField)] = []
    /// Marks on the readings' language tags: a filled pill under the one the keys go in as when
    /// left alone (Araso's own, or the dictionary's once it remembers one, and Araso's again after
    /// switching back), a dotted ring around one corrected once, which another correction moves the
    /// pill to. Shapes, not colours, so they read on the highlight too.
    private static var records: [(row: Int, layer: CAShapeLayer, pill: Bool)] = []
    /// Bumped on every show and hide, so a fade left from before stops.
    private static var generation = 0
    private static var hiding = false

    private static let rowHeight: CGFloat = 24
    private static let inset: CGFloat = 3
    private static let gap: CGFloat = 4

    /// `caret` is the word's line in screen coordinates; without one (`.zero`) nothing is shown,
    /// since a list away from the word says little.
    static func show(_ readings: InputSession.Readings, caret: NSRect) {
        guard caret != .zero else { return hide() }
        generation += 1
        if let panel, panel.isVisible, !hiding, let shown,
           shown.texts == readings.texts, shown.languages == readings.languages {
            select(readings.selected, from: shown.selected)
        } else {
            build(readings, caret: caret)
        }
        shown = readings
    }

    static func hide() {
        guard let panel, panel.isVisible, !hiding else { return }
        generation += 1
        let current = generation
        hiding = true
        shown = nil
        animate(0.08, CAMediaTimingFunction(name: .easeIn), { panel.animator().alphaValue = 0 }) {
            guard current == generation else { return }
            panel.orderOut(nil)
            hiding = false
        }
    }

    private static func rowFrame(_ index: Int, width: CGFloat) -> NSRect {
        NSRect(x: inset, y: inset + CGFloat(index) * rowHeight, width: width, height: rowHeight)
    }

    private static func build(_ readings: InputSession.Readings, caret: NSRect) {
        hiding = false
        let panel = panel ?? CaretPanel.make(size: .zero)
        self.panel = panel

        let tags = readings.languages.map { label($0.readingTag, size: 11) }
        let texts = readings.texts.map { label($0, size: 14) }
        // Measured in the semibold a pill's tag takes, so no tag outgrows its column.
        let tagWidth = readings.languages.map { language -> CGFloat in
            let bold = label(language.readingTag, size: 11)
            bold.font = .systemFont(ofSize: 11, weight: .semibold)
            return bold.fittingSize.width
        }.max() ?? 0
        let textWidth = min(texts.map(\.fittingSize.width).max() ?? 0, 240)
        var recorded: [Int: Bool] = [:] // row: pill (else the ring of a reading corrected once)
        if let row = readings.once { recorded[row] = false }
        if let row = readings.pick { recorded[row] = true }
        recorded = recorded.filter { readings.texts.indices.contains($0.key) }
        let rowWidth = max(8 + ceil(tagWidth) + 6 + ceil(textWidth) + 10, 96)
        let size = NSSize(width: rowWidth + inset * 2, height: CGFloat(texts.count) * rowHeight + inset * 2)

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.separatorColor.cgColor
        let content = FlippedView(frame: background.bounds)
        content.autoresizingMask = [.width, .height]
        background.addSubview(content)

        let highlight = NSView(frame: rowFrame(readings.selected, width: rowWidth))
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 5
        highlight.layer?.cornerCurve = .continuous
        highlight.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        content.addSubview(highlight)
        self.highlight = highlight

        rows = zip(tags, texts).enumerated().map { index, pair in
            let (tag, text) = pair
            let row = NSView(frame: rowFrame(index, width: rowWidth))
            row.wantsLayer = true
            // Centred in its column, with room to spare: at its exact width a centred label truncates.
            tag.alignment = .center
            tag.frame = NSRect(x: 6, y: (rowHeight - tag.fittingSize.height) / 2, width: ceil(tagWidth) + 4, height: tag.fittingSize.height)
            text.frame = NSRect(x: 8 + ceil(tagWidth) + 6, y: (rowHeight - text.fittingSize.height) / 2,
                                width: ceil(textWidth) + 2, height: text.fittingSize.height)
            row.addSubview(tag)
            row.addSubview(text)
            content.addSubview(row)
            return (row, tag, text)
        }
        records = recorded.map { row, pill in
            let tag = rows[row].tag
            // Around the tag's column, the row's height less a margin.
            let box = NSRect(x: tag.frame.minX - 0.5, y: (rowHeight - 16) / 2, width: tag.frame.width + 1, height: 16)
            let layer = CAShapeLayer()
            layer.path = CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil)
            layer.lineWidth = pill ? 0 : 1.3
            layer.lineCap = .round
            if !pill { layer.lineDashPattern = [0.01, 2.6] } // dots: round caps on near-empty dashes
            rows[row].view.layer?.insertSublayer(layer, at: 0)
            if pill { tag.font = .systemFont(ofSize: 11, weight: .semibold) }
            tag.setAccessibilityLabel("\(tag.stringValue), \(L(pill ? "Goes in as" : "Corrected once"))")
            return (row, layer, pill)
        }
        background.setAccessibilityRole(.list)
        background.setAccessibilityLabel(L("Readings, %@ selected", readings.texts[readings.selected]))
        panel.contentView = background
        color(selected: readings.selected)
        panel.setFrame(NSRect(origin: CaretPanel.origin(for: size, caret: caret, gap: gap, centered: false), size: size),
                       display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        dropIn()
    }

    /// The rows fall into place one after another, the highlight with its row.
    private static func dropIn() {
        guard !reduceMotion else { return }
        let current = generation
        highlight?.alphaValue = 0
        for (index, row) in rows.enumerated() {
            let final = row.view.frame
            row.view.alphaValue = 0
            row.view.setFrameOrigin(NSPoint(x: final.minX, y: final.minY - 6))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.035 * Double(index)) {
                guard current == generation else { return }
                animate(0.16, springy, {
                    row.view.animator().alphaValue = 1
                    row.view.animator().setFrameOrigin(final.origin)
                })
            }
        }
        animate(0.12, nil, { highlight?.animator().alphaValue = 1 })
    }

    /// The next switch: the highlight springs to its row.
    private static func select(_ index: Int, from previous: Int) {
        guard rows.indices.contains(index), let highlight else { return }
        // Rows still falling in land at once: a fast second press shouldn't wait for them.
        for (i, row) in rows.enumerated() {
            row.view.alphaValue = 1
            row.view.setFrameOrigin(rowFrame(i, width: row.view.frame.width).origin)
        }
        highlight.alphaValue = 1
        animate(0.22, springy, { highlight.animator().frame = rowFrame(index, width: highlight.frame.width) })
        color(selected: index)
        panel?.contentView?.setAccessibilityLabel(L("Readings, %@ selected", rows[index].text.stringValue))
    }

    private static func color(selected: Int) {
        for (i, row) in rows.enumerated() {
            row.text.textColor = i == selected ? .alternateSelectedControlTextColor : .labelColor
            row.tag.textColor = i == selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
        }
        guard let appearance = panel?.contentView?.effectiveAppearance else { return }
        appearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for record in records {
                let on = record.row == selected
                let ink = on ? NSColor.alternateSelectedControlTextColor : record.pill ? .controlAccentColor : .secondaryLabelColor
                if record.pill {
                    // The pill takes the ink and the tag turns to what's under it.
                    record.layer.fillColor = ink.cgColor
                    rows[record.row].tag.textColor = on ? .controlAccentColor : .alternateSelectedControlTextColor
                } else {
                    record.layer.fillColor = nil
                    record.layer.strokeColor = ink.cgColor
                }
            }
            CATransaction.commit()
        }
    }

    private static func label(_ text: String, size: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size)
        label.lineBreakMode = .byTruncatingTail
        return label
    }
}

/// A correction the dictionary just took (`InputSession.learned`), as a pill that pops up under
/// the word, where the switch key's list was, and goes after a moment: "Once" in a dotted ring
/// after the first correction, "Remembered" filled in the accent color once learned for good (the
/// list's marks, so the two read alike), and "Forgotten" struck through in gray, shrinking away,
/// when a switch back to Araso's own reading forgot the word.
@MainActor enum LearnedHUD {
    private static var panel: NSPanel?
    private static var shown = 0

    private static let height: CGFloat = 18
    /// Room around the pill for its shadow.
    private static let margin: CGFloat = 6
    private static let gap: CGFloat = 3

    /// `word` is the word's line in screen coordinates; the pill starts where the word does.
    static func show(_ learned: InputSession.Learned, word: NSRect) {
        guard word != .zero else { return }
        let text = switch learned.learning {
        case .once: L("Once")
        case .forGood: L("Remembered")
        case .forgot: L("Forgotten")
        }
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let pillSize = NSSize(width: ceil(textSize.width) + 14, height: height)
        let size = NSSize(width: pillSize.width + margin * 2, height: pillSize.height + margin * 2)
        let panel = panel ?? CaretPanel.make(size: size)
        self.panel = panel

        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.setAccessibilityElement(true)
        let spoken = switch learned.learning {
        case .once: L("%@ → %@, once", learned.text, learned.language.displayName)
        case .forGood: L("%@ → always %@", learned.text, learned.language.displayName)
        case .forgot: L("%@, forgotten", learned.text)
        }
        view.setAccessibilityLabel(spoken)
        // Grows from its top left corner, the word's side.
        let pill = CALayer()
        pill.anchorPoint = CGPoint(x: 0, y: 1)
        pill.bounds = CGRect(origin: .zero, size: pillSize)
        pill.position = CGPoint(x: margin, y: margin + pillSize.height)
        let shape = CAShapeLayer()
        shape.frame = pill.bounds
        let filled = learned.learning == .forGood
        // A ring's stroke stays inside the pill.
        shape.path = CGPath(roundedRect: pill.bounds.insetBy(dx: filled ? 0 : 0.65, dy: filled ? 0 : 0.65),
                            cornerWidth: 5, cornerHeight: 5, transform: nil)
        shape.shadowPath = shape.path
        shape.shadowOpacity = 0.18
        shape.shadowRadius = 3
        shape.shadowOffset = CGSize(width: 0, height: -1)
        let label = CATextLayer()
        label.contentsScale = NSScreen.screens.first { $0.frame.contains(word.origin) }?.backingScaleFactor ?? 2
        label.alignmentMode = .center
        label.frame = CGRect(x: 0, y: (height - ceil(textSize.height)) / 2, width: pillSize.width, height: ceil(textSize.height))
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            let ink: NSColor
            switch learned.learning {
            case .forGood:
                shape.fillColor = NSColor.controlAccentColor.cgColor
                ink = .alternateSelectedControlTextColor
            case .once:
                shape.fillColor = NSColor.controlBackgroundColor.cgColor
                shape.strokeColor = NSColor.controlAccentColor.cgColor
                shape.lineWidth = 1.3
                shape.lineCap = .round
                shape.lineDashPattern = [0.01, 2.6] // dots: round caps on near-empty dashes
                ink = .controlAccentColor
            case .forgot:
                shape.fillColor = NSColor.controlBackgroundColor.cgColor
                shape.strokeColor = NSColor.separatorColor.cgColor
                shape.lineWidth = 1
                ink = .secondaryLabelColor
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
            if learned.learning == .forgot { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            label.string = NSAttributedString(string: text, attributes: attributes)
        }
        pill.addSublayer(shape)
        pill.addSublayer(label)
        view.layer?.addSublayer(pill)
        panel.contentView = view

        var origin = CaretPanel.origin(for: size, caret: word, gap: gap - margin, centered: false)
        origin.x -= margin
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        if !reduceMotion {
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.6
            grow.toValue = 1
            grow.duration = 0.26
            grow.timingFunction = springy
            let appear = CABasicAnimation(keyPath: "opacity")
            appear.fromValue = 0
            appear.toValue = 1
            appear.duration = 0.12
            pill.add(grow, forKey: "grow")
            pill.add(appear, forKey: "appear")
        }

        shown += 1
        let current = shown
        let forgot = learned.learning == .forgot
        DispatchQueue.main.asyncAfter(deadline: .now() + (forgot ? 0.9 : 1.5)) {
            guard current == shown else { return }
            if forgot, !reduceMotion {
                // Shrinks back into the word's corner as it goes.
                let shrink = CABasicAnimation(keyPath: "transform.scale")
                shrink.fromValue = 1
                shrink.toValue = 0.5
                shrink.duration = 0.36
                shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
                shrink.fillMode = .forwards
                shrink.isRemovedOnCompletion = false
                pill.add(shrink, forKey: "shrink")
            }
            animate(forgot ? 0.36 : 0.4, nil, { panel.animator().alphaValue = 0 }) {
                if current == shown { panel.orderOut(nil) }
            }
        }
    }

    static func hide() {
        shown += 1
        panel?.orderOut(nil)
    }
}
