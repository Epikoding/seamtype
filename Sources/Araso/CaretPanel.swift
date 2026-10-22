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

/// A correction the dictionary just took (`InputSession.learned`), as a highlighter stroke under
/// the word: below the letters' baseline only, where the app's own underlines are (the line of text
/// being typed, a spelling mark), so it covers no letter. In the accent color, as the pause icon
/// under the caret is, whatever the language (the word's letters already show it): pale after the
/// first correction, full once learned for good, both drawn left to right; gray taken back from
/// the right when a switch back to Araso's own reading forgot the word.
@MainActor enum LearnedHUD {
    private static var panel: NSPanel?
    private static var shown = 0
    /// The ease of a pen stroke: quick to start, settling at the end.
    private static let stroke = CAMediaTimingFunction(controlPoints: 0.6, 0, 0.2, 1)

    /// `word` is the word's line in screen coordinates; `descent` how far its letters' baseline is
    /// above the line's bottom, the room the stroke takes. Without a width there is nothing to mark.
    static func show(_ learned: InputSession.Learned, word: NSRect, descent: CGFloat) {
        guard word != .zero, word.width >= 4 else { return }
        // From just below the baseline to the line's bottom, at least a few points to be seen.
        let height = min(max(descent - 1, 3), 8)
        let size = NSSize(width: ceil(word.width), height: height)
        let panel = panel ?? CaretPanel.make(size: size)
        self.panel = panel
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.setAccessibilityElement(true)
        let label = switch learned.learning {
        case .once: L("%@ → %@, once", learned.text, learned.language.displayName)
        case .forGood: L("%@ → always %@", learned.text, learned.language.displayName)
        case .forgot: L("%@, forgotten", learned.text)
        }
        view.setAccessibilityLabel(label)
        // A line as thick as the band, butt-ended, so drawing it is the band filling in.
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: height / 2))
        path.addLine(to: CGPoint(x: size.width, y: height / 2))
        let band = CAShapeLayer()
        band.path = path
        band.lineWidth = height
        band.lineCap = .butt
        band.fillColor = nil
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            let (color, alpha): (NSColor, CGFloat) = switch learned.learning {
            case .once: (.controlAccentColor, 0.35)
            case .forGood: (.controlAccentColor, 0.9)
            case .forgot: (.systemGray, 0.45)
            }
            band.strokeColor = color.withAlphaComponent(alpha).cgColor
        }
        view.layer?.addSublayer(band)
        panel.contentView = view

        var origin = NSPoint(x: word.minX, y: word.minY)
        if let visible = (NSScreen.screens.first { $0.frame.contains(word.origin) } ?? NSScreen.main)?.visibleFrame {
            origin.y = max(origin.y, visible.minY)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        var stay = 1.3
        if learned.learning == .forgot {
            // Down already, taken back from the right.
            band.strokeEnd = 0
            stay = 0.6
            if !reduceMotion {
                let back = drawn(from: 1, to: 0, duration: 0.42)
                back.beginTime = CACurrentMediaTime() + 0.12
                back.fillMode = .backwards
                band.add(back, forKey: "back")
            }
        } else if !reduceMotion {
            band.add(drawn(from: 0, to: 1, duration: 0.32), forKey: "draw")
        }

        shown += 1
        let current = shown
        DispatchQueue.main.asyncAfter(deadline: .now() + stay) {
            guard current == shown else { return }
            animate(0.5, nil, { panel.animator().alphaValue = 0 }) {
                if current == shown { panel.orderOut(nil) }
            }
        }
    }

    static func hide() {
        shown += 1
        panel?.orderOut(nil)
    }

    private static func drawn(from: CGFloat, to: CGFloat, duration: TimeInterval) -> CABasicAnimation {
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = from
        draw.toValue = to
        draw.duration = duration
        draw.timingFunction = stroke
        return draw
    }
}
