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

/// Araso's mark (the menu bar icon) as a gauge of what Araso knows about a reading: gray for
/// the reading it picks by itself, or filled from the bottom in the accent color as far as the
/// user's corrections taught it, half after one and full once learned for good.
@MainActor final class MarkIcon: NSView {
    /// The menu bar icon; nil outside an app bundle (development), where no mark is drawn.
    static let image: NSImage? = Bundle.main.url(forResource: "Araso", withExtension: "tiff").flatMap(NSImage.init(contentsOf:))

    private let empty = CALayer()
    private let level = CALayer()
    private let fill = CALayer()
    private var fraction: CGFloat = 0

    init?(size: NSSize) {
        guard let image = Self.image,
              let cg = (image.representations.compactMap { $0 as? NSBitmapImageRep }.max { $0.pixelsWide < $1.pixelsWide })?.cgImage
        else { return nil }
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        for layer in [empty, fill] {
            let mask = CALayer()
            mask.contents = cg
            mask.contentsGravity = .resizeAspect
            mask.frame = bounds
            layer.frame = bounds
            layer.mask = mask
        }
        level.frame = NSRect(x: 0, y: 0, width: size.width, height: 0)
        level.masksToBounds = true
        level.addSublayer(fill)
        layer?.addSublayer(empty)
        layer?.addSublayer(level)
    }

    required init?(coder: NSCoder) { nil }

    /// `own`: Araso's own reading (all gray); otherwise `fraction` of the mark filled with `color`
    /// over a faint empty mark. `animated` fills it from where it was.
    func show(own: Bool, fraction: CGFloat, color: NSColor, emptyColor: NSColor, animated: Bool) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            empty.backgroundColor = (own ? color : emptyColor).cgColor
            fill.backgroundColor = color.cgColor
            CATransaction.commit()
        }
        self.fraction = own ? 0 : fraction
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated && !reduceMotion ? 0.45 : 0)
        CATransaction.setAnimationTimingFunction(springy)
        CATransaction.setDisableActions(!(animated && !reduceMotion))
        level.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height * self.fraction)
        CATransaction.commit()
    }
}

/// The readings a switch key goes through for the word it changed, a list dropped under the
/// word with each reading's language and the one on screen highlighted, until the next key
/// (`InputSession.readings`). Rows fall in one after another; on the next switch the highlight
/// springs to its row and the reading there unscrambles into place. Everything is over in
/// about 0.2 s, and the next key cuts it short: the user is in the middle of typing.
@MainActor enum ReadingsHUD {
    private static var panel: NSPanel?
    private static var shown: InputSession.Readings?
    private static var highlight: NSView?
    private static var rows: [(view: NSView, tag: NSTextField, text: NSTextField)] = []
    /// Araso's mark on the readings it knows about: its own reading in gray, the one the keys
    /// were corrected to once half filled, the one learned for good (or added by hand) full.
    private static var marks: [(row: Int, view: MarkIcon, own: Bool, fraction: CGFloat)] = []
    private static let markSize = NSSize(width: 17, height: 13.6)
    /// Bumped on every show and hide, so a fade or a scramble left from before stops.
    private static var generation = 0
    private static var hiding = false
    private static var scramble: Timer?

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
        scramble?.invalidate()
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
        scramble?.invalidate()
        hiding = false
        let panel = panel ?? CaretPanel.make(size: .zero)
        self.panel = panel

        let tags = readings.languages.map { label($0.readingTag, size: 11) }
        let texts = readings.texts.map { label($0, size: 14) }
        let tagWidth = tags.map(\.fittingSize.width).max() ?? 0
        let textWidth = min(texts.map(\.fittingSize.width).max() ?? 0, 240)
        // One mark a row, the user's record over Araso's own: a reading both learned and Araso's
        // shows the record.
        var wanted: [Int: (own: Bool, fraction: CGFloat, name: String)] = [:]
        if let row = readings.own { wanted[row] = (true, 0, L("Araso's own reading")) }
        if let row = readings.once { wanted[row] = (false, 0.5, L("Corrected once")) }
        if let row = readings.remembered { wanted[row] = (false, 1, L("Remembered")) }
        wanted = wanted.filter { readings.texts.indices.contains($0.key) }
        if MarkIcon.image == nil { wanted = [:] }
        let rowWidth = max(8 + ceil(tagWidth) + 6 + ceil(textWidth) + (wanted.isEmpty ? 10 : 12 + ceil(markSize.width)), 96)
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
            tag.frame = NSRect(x: 8, y: (rowHeight - tag.fittingSize.height) / 2, width: ceil(tagWidth), height: tag.fittingSize.height)
            text.frame = NSRect(x: 8 + ceil(tagWidth) + 6, y: (rowHeight - text.fittingSize.height) / 2,
                                width: ceil(textWidth) + 2, height: text.fittingSize.height)
            row.addSubview(tag)
            row.addSubview(text)
            content.addSubview(row)
            return (row, tag, text)
        }
        marks = wanted.compactMap { row, mark in
            guard let view = MarkIcon(size: markSize) else { return nil }
            view.setFrameOrigin(NSPoint(x: rowWidth - 8 - markSize.width, y: (rowHeight - markSize.height) / 2))
            view.setAccessibilityElement(true)
            view.setAccessibilityLabel(mark.name)
            rows[row].view.addSubview(view)
            return (row, view, mark.own, mark.fraction)
        }
        color(selected: readings.selected)

        background.setAccessibilityRole(.list)
        background.setAccessibilityLabel(L("Readings, %@ selected", readings.texts[readings.selected]))
        panel.contentView = background
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

    /// The next switch: the highlight springs to its row and the reading there unscrambles.
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
        unscramble(rows[index].text)
    }

    private static func color(selected: Int) {
        for (i, row) in rows.enumerated() {
            row.text.textColor = i == selected ? .alternateSelectedControlTextColor : .labelColor
            row.tag.textColor = i == selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
        }
        for mark in marks {
            let on = mark.row == selected
            mark.view.show(own: mark.own, fraction: mark.fraction,
                           color: on ? .alternateSelectedControlTextColor : mark.own ? .secondaryLabelColor : .controlAccentColor,
                           emptyColor: on ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.35) : .tertiaryLabelColor,
                           animated: false)
        }
    }

    /// Letters, jamo-built syllables and kana a reading flickers through.
    private static let pool = Array("abcdefghkmnrstuvz가나다라마바사아자하あいうえおかきくけこ")

    /// The reading flickers through random letters for about 0.1 s, settling from the left:
    /// a new reading decoded, not just swapped. Four frames, the same length as the reading, so
    /// the row doesn't change width.
    private static func unscramble(_ label: NSTextField) {
        scramble?.invalidate()
        let target = Array(label.stringValue)
        guard !reduceMotion, !target.isEmpty else { return }
        let current = generation
        var frame = 0
        func step() {
            frame += 1
            let settled = target.count * frame / 4
            label.stringValue = String(target.indices.map { $0 < settled ? target[$0] : pool.randomElement()! })
        }
        step()
        scramble = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard current == generation, frame < 4 else {
                    timer.invalidate()
                    label.stringValue = String(target)
                    return
                }
                step()
            }
        }
    }

    private static func label(_ text: String, size: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size)
        label.lineBreakMode = .byTruncatingTail
        return label
    }
}

/// A correction the dictionary just took (`InputSession.learned`): Araso's mark drops onto the
/// end of the word and fills, to half after the first correction and to full when the word is
/// learned for good, as the switch key's list shows it. It sits in the gap above the line, so
/// the text typed on doesn't run under it; the input menu lists the word and takes it back.
@MainActor enum LearnedHUD {
    private static var panel: NSPanel?
    private static var shown = 0
    private static let size = NSSize(width: 20, height: 16)

    static func show(_ learned: InputSession.Learned, caret: NSRect) {
        guard caret != .zero, let mark = MarkIcon(size: size) else { return }
        let panel = panel ?? CaretPanel.make(size: size)
        self.panel = panel
        panel.contentView = mark
        mark.setAccessibilityElement(true)
        mark.setAccessibilityLabel(learned.forGood ? L("%@ → always %@", learned.text, learned.language.displayName)
                                                   : L("%@ → %@, once", learned.text, learned.language.displayName))

        // Over the word's last letter, just above its line; below the line only where the
        // line is at the top of the screen.
        var origin = NSPoint(x: caret.minX - 14, y: caret.maxY + 1)
        if let visible = (NSScreen.screens.first { $0.frame.contains(caret.origin) } ?? NSScreen.main)?.visibleFrame,
           origin.y + size.height > visible.maxY {
            origin.y = caret.minY - size.height - 1
        }
        let landed = NSRect(origin: origin, size: size)
        panel.setFrame(reduceMotion ? landed : landed.offsetBy(dx: 0, dy: 8), display: true)
        panel.alphaValue = reduceMotion ? 1 : 0
        panel.orderFrontRegardless()
        let from: CGFloat = learned.forGood ? 0.5 : 0
        mark.show(own: false, fraction: from, color: .controlAccentColor, emptyColor: .tertiaryLabelColor, animated: false)
        animate(0.2, springy, {
            panel.animator().setFrame(landed, display: true)
            panel.animator().alphaValue = 1
        })

        shown += 1
        let current = shown
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0 : 0.18)) {
            guard current == shown else { return }
            mark.show(own: false, fraction: learned.forGood ? 1 : 0.5, color: .controlAccentColor,
                      emptyColor: .tertiaryLabelColor, animated: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            guard current == shown else { return }
            animate(0.25, nil, { panel.animator().alphaValue = 0 }) {
                if current == shown { panel.orderOut(nil) }
            }
        }
    }

    static func hide() {
        shown += 1
        panel?.orderOut(nil)
    }
}
