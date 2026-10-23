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
/// user is in the middle of typing, unless that key made the dictionary take the correction
/// (`InputSession.learned`): then the list folds to the chosen row, which says what happened.
@MainActor enum ReadingsHUD {
    private static var panel: NSPanel?
    private static var shown: InputSession.Readings?
    private static var highlight: NSView?
    private static var rows: [(view: NSView, tag: NSTextField, text: NSTextField, own: NSImageView?)] = []
    /// Marks on the readings' language tags: a filled pill under the one the dictionary
    /// remembers, which the keys go in as when left alone, a dotted ring around one corrected
    /// once, which another correction makes the pill. Shapes, not colours, so they read on the
    /// highlight too. Araso's own reading carries a sparkle at its end, whatever is remembered.
    private static var records: [(row: Int, layer: CAShapeLayer, pill: Bool)] = []
    /// Bumped on every show and hide, so a fade left from before stops.
    private static var generation = 0
    private static var hiding = false
    /// Folded to the chosen row and saying what the correction did; the keys typed meanwhile
    /// don't put it away.
    private static var settling = false
    /// The list is above the word, near the bottom of the screen: it folds toward its bottom.
    private static var above = false

    private static let rowHeight: CGFloat = 24
    private static let inset: CGFloat = 3
    private static let gap: CGFloat = 4
    private static let ownWidth: CGFloat = 12
    private static let ease = CAMediaTimingFunction(controlPoints: 0.6, 0, 0.2, 1)

    /// `caret` is the word's line in screen coordinates; without one (`.zero`) nothing is shown,
    /// since a list away from the word says little.
    static func show(_ readings: InputSession.Readings, caret: NSRect) {
        guard caret != .zero else { return hide(force: true) }
        generation += 1
        if let panel, panel.isVisible, !hiding, !settling, let shown,
           shown.texts == readings.texts, shown.languages == readings.languages {
            select(readings.selected, from: shown.selected)
        } else {
            settling = false
            build(Content(readings), caret: caret)
        }
        shown = readings
    }

    /// Puts the list away; one saying what a correction did stays its moment unless `force`d
    /// (the field lost focus, the input method paused).
    static func hide(force: Bool = false) {
        guard let panel, panel.isVisible, !hiding, force || !settling else { return }
        generation += 1
        let current = generation
        hiding = true
        settling = false
        shown = nil
        animate(0.08, CAMediaTimingFunction(name: .easeIn), { panel.animator().alphaValue = 0 }) {
            guard current == generation else { return }
            panel.orderOut(nil)
            hiding = false
        }
    }

    /// The correction the dictionary just took: the list still up folds to the chosen row, its
    /// tag turning to an icon and its reading to what happened: a pencil and "Once" after the
    /// first correction, a check and "Remembered" once learned for good, Araso's sparkle and
    /// "Automatic" when a switch back to Araso's own reading forgot the word. Without a list up
    /// (`word`, the word's line, places it) a row like it shows on its own.
    static func settle(_ learned: InputSession.Learned, word: NSRect) {
        let index: Int
        if let panel, panel.isVisible, !hiding, !settling, let shown, rows.indices.contains(shown.selected) {
            index = shown.selected
        } else {
            guard word != .zero else { return }
            build(Content(texts: [learned.text], languages: [learned.language], selected: 0), caret: word)
            index = 0
        }
        guard let panel else { return }
        generation += 1
        let current = generation
        settling = true
        shown = nil
        let (symbol, text) = switch learned.learning {
        case .once: ("pencil", L("Once"))
        case .forGood: ("checkmark", L("Remembered"))
        case .forgot: ("sparkles", L("Automatic"))
        }
        let spoken = switch learned.learning {
        case .once: L("%@ → %@, once", learned.text, learned.language.displayName)
        case .forGood: L("%@ → always %@", learned.text, learned.language.displayName)
        case .forgot: L("%@, back to automatic", learned.text)
        }
        panel.contentView?.setAccessibilityLabel(spoken)

        let row = rows[index]
        let outcome = label(text, size: 13)
        outcome.font = .systemFont(ofSize: 13, weight: .semibold)
        outcome.frame = NSRect(x: row.text.frame.minX, y: (rowHeight - outcome.fittingSize.height) / 2,
                               width: ceil(outcome.fittingSize.width) + 2, height: outcome.fittingSize.height)

        // The other rows go and the list closes in on the chosen one, keeping the edge by the word,
        // as wide as the outcome needs.
        let one = rowHeight + inset * 2
        let frame = panel.frame
        let width = max(row.view.frame.width, outcome.frame.maxX + 10)
        let folded = NSRect(x: frame.minX, y: above ? frame.minY : frame.maxY - one, width: width + inset * 2, height: one)
        animate(0.12, nil, {
            for (i, other) in rows.enumerated() where i != index { other.view.animator().alphaValue = 0 }
        })
        animate(0.22, ease, {
            panel.animator().setFrame(folded, display: true)
            row.view.animator().frame = rowFrame(0, width: width)
            highlight?.animator().frame = rowFrame(0, width: width)
        })

        // Then the row says it: the tag gives way to the icon, the reading to the outcome.
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)) ?? NSImage())
        icon.frame = NSRect(x: row.tag.frame.midX - 7, y: (rowHeight - 14) / 2, width: 14, height: 14)
        let on = highlight != nil
        icon.contentTintColor = on ? .alternateSelectedControlTextColor : .controlAccentColor
        outcome.textColor = on ? .alternateSelectedControlTextColor : .labelColor
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard current == generation else { return }
            for new in [icon, outcome] as [NSView] {
                new.alphaValue = 0
                new.setFrameOrigin(NSPoint(x: new.frame.minX, y: new.frame.minY + 6))
                row.view.addSubview(new)
            }
            let leaving: [NSView] = [row.tag, row.text] + (row.own.map { [$0] } ?? [])
            for record in records where record.row == index { record.layer.opacity = 0 }
            animate(0.2, ease, {
                for old in leaving {
                    old.animator().alphaValue = 0
                    old.animator().setFrameOrigin(NSPoint(x: old.frame.minX, y: old.frame.minY - 6))
                }
                for new in [icon, outcome] as [NSView] {
                    new.animator().alphaValue = 1
                    new.animator().setFrameOrigin(NSPoint(x: new.frame.minX, y: new.frame.minY - 6))
                }
            })
        }
        // The highlight lets go, and the row reads as the list's own colours.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            guard current == generation else { return }
            icon.contentTintColor = .controlAccentColor
            outcome.textColor = .labelColor
            animate(0.26, nil, { highlight?.animator().alphaValue = 0 })
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) {
            guard current == generation else { return }
            animate(0.22, nil, { panel.animator().alphaValue = 0 }) {
                guard current == generation else { return }
                panel.orderOut(nil)
                settling = false
            }
        }
    }

    private static func rowFrame(_ index: Int, width: CGFloat) -> NSRect {
        NSRect(x: inset, y: inset + CGFloat(index) * rowHeight, width: width, height: rowHeight)
    }

    /// What the list shows: the session's readings, or one reading for an outcome on its own.
    private struct Content {
        var texts: [String]
        var languages: [Language]
        var selected: Int
        var own: Int?
        var remembered: Int?
        var once: Int?

        init(texts: [String], languages: [Language], selected: Int) {
            self.texts = texts
            self.languages = languages
            self.selected = selected
        }

        init(_ readings: InputSession.Readings) {
            self.init(texts: readings.texts, languages: readings.languages, selected: readings.selected)
            own = readings.own
            remembered = readings.remembered
            once = readings.once
        }
    }

    private static func build(_ readings: Content, caret: NSRect) {
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
        if let row = readings.remembered { recorded[row] = true }
        recorded = recorded.filter { readings.texts.indices.contains($0.key) }
        let own = readings.own.flatMap { readings.texts.indices.contains($0) ? $0 : nil }
        let rowWidth = max(8 + ceil(tagWidth) + 6 + ceil(textWidth) + 10 + (own == nil ? 0 : ownWidth + 6), 96)
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
            var sparkle: NSImageView?
            if index == own {
                let image = NSImageView(image: NSImage(systemSymbolName: "sparkles", accessibilityDescription: L("Araso's choice"))?
                    .withSymbolConfiguration(.init(pointSize: 10, weight: .medium)) ?? NSImage())
                image.frame = NSRect(x: rowWidth - 10 - ownWidth, y: (rowHeight - ownWidth) / 2, width: ownWidth, height: ownWidth)
                row.addSubview(image)
                sparkle = image
            }
            content.addSubview(row)
            return (row, tag, text, sparkle)
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
            tag.setAccessibilityLabel("\(tag.stringValue), \(L(pill ? "Remembered" : "Corrected once"))")
            return (row, layer, pill)
        }
        background.setAccessibilityRole(.list)
        background.setAccessibilityLabel(L("Readings, %@ selected", readings.texts[readings.selected]))
        panel.contentView = background
        color(selected: readings.selected)
        let origin = CaretPanel.origin(for: size, caret: caret, gap: gap, centered: false)
        above = origin.y > caret.minY
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
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
            row.own?.contentTintColor = i == selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
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
