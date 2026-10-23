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
    /// The letter of a reading's script, as the website and the settings window show the
    /// languages (A 아 あ): what the list marks each reading with, no colour to learn.
    var readingGlyph: String {
        switch self {
        case .english, .mixed: return "A"
        case .korean: return "아"
        case .japanese: return "あ"
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

/// Araso's paper, as on the website and in the settings window: the card the readings and the
/// conversion candidates are drawn on, birch paper and navy ink, navy paper in the dark.
@MainActor enum Paper {
    static let background = dynamic(0xfaf8f4, 0x0d213b)
    static let ink = dynamic(0x0b2545, 0xf3f1ec)
    static let ink2 = dynamic(0x4a5b70, 0xa9b6c6)
    static let line = dynamic(0xe6e1d8, 0xf3f1ec, darkAlpha: 0.16)
    static let selection = dynamic(0xe1eef6, 0x16365a)
    static let accent = dynamic(0x006aa7, 0x4fa8e0)

    static let rowHeight: CGFloat = 22
    static let inset: CGFloat = 3
    static let radius: CGFloat = 7

    /// A card of `size`: the paper with a hairline round it, its rows laid out top-down in the
    /// view returned with it. The window it is put in casts the shadow.
    static func card(size: NSSize) -> (card: NSView, content: NSView) {
        let card = NSView(frame: NSRect(origin: .zero, size: size))
        card.wantsLayer = true
        card.layer?.cornerRadius = radius
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 1
        card.effectiveAppearance.performAsCurrentDrawingAppearance {
            card.layer?.backgroundColor = background.cgColor
            card.layer?.borderColor = line.cgColor
        }
        let content = FlippedView(frame: card.bounds)
        content.autoresizingMask = [.width, .height]
        card.addSubview(content)
        return (card, content)
    }

    /// A panel for a card: casting the shadow of what is drawn in it.
    static func panel() -> NSPanel {
        let panel = CaretPanel.make(size: .zero)
        panel.hasShadow = true
        return panel
    }

    /// The highlight under the chosen row.
    static func highlight(_ frame: NSRect) -> NSView {
        let view = NSView(frame: frame)
        view.wantsLayer = true
        view.layer?.cornerRadius = 5
        view.layer?.cornerCurve = .continuous
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = selection.cgColor
        }
        return view
    }

    static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private static func dynamic(_ light: UInt32, _ dark: UInt32, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(dark, alpha: darkAlpha) : rgb(light, alpha: 1)
        }
    }

    private static func rgb(_ hex: UInt32, alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
}

/// A reading's mark: its script letter (A 아 あ), and leaning on the letter's shoulder, as tall
/// as it, the icon of what the dictionary knows about it: a check for a remembered reading, a
/// pencil for one corrected once, a sparkle for Araso's own. Where they overlap, the letter is
/// cut away along the icon's outline, not in a disc, so both stay whole.
private final class MarkView: NSView {
    static let width: CGFloat = 26
    private let glyph: NSTextField
    private let halo = NSImageView()
    private let icon = NSImageView()
    private var accented = false
    private(set) var symbol: String?

    override var isFlipped: Bool { true }

    init(language: Language) {
        glyph = Paper.label(language.readingGlyph, size: 11.5, weight: .semibold)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Paper.rowHeight))
        let size = glyph.fittingSize
        glyph.frame = NSRect(x: 1, y: (Paper.rowHeight - size.height) / 2 + 1, width: ceil(size.width) + 1, height: size.height)
        addSubview(glyph)
        // Over the letter's top right, its top a little above the letter's.
        let box = NSRect(x: glyph.frame.minX + ceil(size.width) - 1, y: 2, width: 12, height: 12)
        halo.frame = box.insetBy(dx: -1, dy: -1)
        icon.frame = box
        for view in [halo, icon] {
            view.imageScaling = .scaleProportionallyDown
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { nil }

    /// Shows `symbol` (nil: the letter alone), in the accent colour or the quiet ink.
    func set(_ symbol: String?, accented: Bool) {
        self.symbol = symbol
        self.accented = accented
        icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
        // The same shape drawn heavier in the paper's colour, under the icon: the cut-out.
        halo.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .black))
        icon.contentTintColor = accented ? Paper.accent : Paper.ink2
    }

    /// The row is the chosen one: the letter takes the accent, the cut-out the highlight's colour.
    func color(on: Bool) {
        glyph.textColor = on ? Paper.accent : Paper.ink2
        halo.contentTintColor = on ? Paper.selection : Paper.background
    }

    /// The icon gives way to `symbol`, the old one fading as the new comes up from below.
    func swap(to symbol: String, accented: Bool) {
        let old = NSImageView(frame: icon.frame)
        old.image = icon.image
        old.contentTintColor = icon.contentTintColor
        old.imageScaling = .scaleProportionallyDown
        addSubview(old)
        set(symbol, accented: accented)
        let final = icon.frame
        icon.alphaValue = 0
        icon.setFrameOrigin(NSPoint(x: final.minX, y: final.minY + 5))
        animate(0.2, CAMediaTimingFunction(controlPoints: 0.6, 0, 0.2, 1), {
            old.animator().alphaValue = 0
            old.animator().setFrameOrigin(NSPoint(x: final.minX, y: final.minY - 5))
            self.icon.animator().alphaValue = 1
            self.icon.animator().setFrameOrigin(final.origin)
        }) { old.removeFromSuperview() }
    }
}

private extension InputSession.Readings {
    /// The icon the list puts on reading `index`: remembered, else corrected once, else Araso's own.
    func mark(_ index: Int) -> (symbol: String, accented: Bool)? {
        if index == remembered { return ("checkmark", true) }
        if index == once { return ("pencil", true) }
        if index == own { return ("sparkles", false) }
        return nil
    }
}

/// The readings a switch key goes through for the word it changed, a card dropped under the
/// word with each reading marked by its script letter and the one on screen highlighted, until
/// the next key (`InputSession.readings`). Rows fall in one after another; on the next switch the
/// highlight springs to its row, and only the highlight moves: the readings stay still, so fast
/// presses leave them readable. Everything is over in about 0.2 s, and the next key cuts it short:
/// the user is in the middle of typing, unless that key made the dictionary take the correction
/// (`InputSession.learned`): then the card folds to the chosen row, which says what happened.
@MainActor enum ReadingsHUD {
    private static var panel: NSPanel?
    private static var shown: InputSession.Readings?
    private static var highlight: NSView?
    private static var rows: [(view: NSView, mark: MarkView, text: NSTextField)] = []
    /// Bumped on every show and hide, so a fade left from before stops.
    private static var generation = 0
    private static var hiding = false
    /// Folded to the chosen row and saying what the correction did; the keys typed meanwhile
    /// don't put it away.
    private static var settling = false
    /// The card is above the word, near the bottom of the screen: it folds toward its bottom.
    private static var above = false

    private static let rowHeight = Paper.rowHeight
    private static let inset = Paper.inset
    private static let gap: CGFloat = 4
    private static let textX: CGFloat = 5 + MarkView.width + 3
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
            build(texts: readings.texts, languages: readings.languages, selected: readings.selected,
                  marks: readings.texts.indices.map { readings.mark($0) }, caret: caret)
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

    /// The correction the dictionary just took: the card still up folds to the chosen row, its
    /// icon turning to what happened and its reading to the word for it: a pencil and "Once"
    /// after the first correction, a check and "Remembered" once learned for good, Araso's
    /// sparkle and "Automatic" when a switch back to Araso's own reading forgot the word. Without
    /// a card up (`word`, the word's line, places it) a row like it shows on its own.
    static func settle(_ learned: InputSession.Learned, word: NSRect) {
        let index: Int
        if let panel, panel.isVisible, !hiding, !settling, let shown, rows.indices.contains(shown.selected) {
            index = shown.selected
        } else {
            guard word != .zero else { return }
            build(texts: [learned.text], languages: [learned.language], selected: 0, marks: [nil], caret: word)
            index = 0
        }
        guard let panel else { return }
        generation += 1
        let current = generation
        settling = true
        shown = nil
        let (symbol, accented, text) = switch learned.learning {
        case .once: ("pencil", true, L("Once"))
        case .forGood: ("checkmark", true, L("Remembered"))
        case .forgot: ("sparkles", false, L("Automatic"))
        }
        let spoken = switch learned.learning {
        case .once: L("%@ → %@, once", learned.text, learned.language.displayName)
        case .forGood: L("%@ → always %@", learned.text, learned.language.displayName)
        case .forgot: L("%@, back to automatic", learned.text)
        }
        panel.contentView?.setAccessibilityLabel(spoken)

        let row = rows[index]
        let outcome = Paper.label(text, size: 13, weight: .semibold)
        outcome.textColor = Paper.ink
        outcome.frame = NSRect(x: row.text.frame.minX, y: (rowHeight - outcome.fittingSize.height) / 2,
                               width: ceil(outcome.fittingSize.width) + 2, height: outcome.fittingSize.height)

        // The other rows go and the card closes in on the chosen one, keeping the edge by the
        // word, as wide as the outcome needs.
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
        }) { panel.invalidateShadow() }

        // Then the row says it: its icon turns, its reading gives way to the outcome.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard current == generation else { return }
            row.mark.swap(to: symbol, accented: accented)
            outcome.alphaValue = 0
            outcome.setFrameOrigin(NSPoint(x: outcome.frame.minX, y: outcome.frame.minY + 6))
            row.view.addSubview(outcome)
            animate(0.2, ease, {
                row.text.animator().alphaValue = 0
                row.text.animator().setFrameOrigin(NSPoint(x: row.text.frame.minX, y: row.text.frame.minY - 6))
                outcome.animator().alphaValue = 1
                outcome.animator().setFrameOrigin(NSPoint(x: outcome.frame.minX, y: outcome.frame.minY - 6))
            })
        }
        // The highlight lets go, and the row reads as the card's own.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            guard current == generation else { return }
            animate(0.26, nil, { highlight?.animator().alphaValue = 0 }) {
                guard current == generation else { return }
                row.mark.color(on: false)
            }
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

    private static func build(texts: [String], languages: [Language], selected: Int,
                              marks: [(symbol: String, accented: Bool)?], caret: NSRect) {
        hiding = false
        let panel = panel ?? Paper.panel()
        self.panel = panel

        let labels = texts.map { Paper.label($0, size: 13.5) }
        // Measured in the semibold the chosen row takes, so no reading outgrows its row.
        let textWidth = min(texts.map { Paper.label($0, size: 13.5, weight: .semibold).fittingSize.width }.max() ?? 0, 240)
        let rowWidth = max(textX + ceil(textWidth) + 10, 80)
        let size = NSSize(width: rowWidth + inset * 2, height: CGFloat(texts.count) * rowHeight + inset * 2)
        let (card, content) = Paper.card(size: size)

        let highlight = Paper.highlight(rowFrame(selected, width: rowWidth))
        content.addSubview(highlight)
        self.highlight = highlight

        rows = zip(languages, labels).enumerated().map { index, pair in
            let (language, text) = pair
            let row = NSView(frame: rowFrame(index, width: rowWidth))
            row.wantsLayer = true
            let mark = MarkView(language: language)
            mark.setFrameOrigin(NSPoint(x: 5, y: 0))
            mark.set(marks[index]?.symbol, accented: marks[index]?.accented ?? false)
            mark.setAccessibilityElement(true)
            let spoken = switch marks[index]?.symbol {
            case "checkmark": L("Remembered")
            case "pencil": L("Corrected once")
            case "sparkles": L("Araso's choice")
            default: language.displayName
            }
            mark.setAccessibilityLabel(spoken)
            text.frame = NSRect(x: textX, y: (rowHeight - text.fittingSize.height) / 2,
                                width: ceil(textWidth) + 2, height: text.fittingSize.height)
            row.addSubview(mark)
            row.addSubview(text)
            content.addSubview(row)
            return (row, mark, text)
        }
        card.setAccessibilityRole(.list)
        card.setAccessibilityLabel(L("Readings, %@ selected", texts[selected]))
        panel.contentView = card
        color(selected: selected)
        let origin = CaretPanel.origin(for: size, caret: caret, gap: gap, centered: false)
        above = origin.y > caret.minY
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.invalidateShadow()
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

    /// The chosen row's reading in semibold, its letter in the accent.
    private static func color(selected: Int) {
        for (i, row) in rows.enumerated() {
            let on = i == selected
            row.text.textColor = Paper.ink
            row.text.font = .systemFont(ofSize: 13.5, weight: on ? .semibold : .regular)
            row.mark.color(on: on)
        }
    }
}

/// The kana→kanji candidates (`InputSession.conversion`) on the same paper card as the readings,
/// under the clause being converted with the candidates' text starting where the clause does:
/// a page of nine, numbered for the digit keys, the chosen one highlighted, the reading and the
/// page under them. A click chooses a candidate too.
@MainActor enum CandidatesHUD {
    private static var panel: NSPanel?
    private static var highlight: NSView?
    private static var rows: [(view: NSView, number: NSTextField, text: NSTextField)] = []
    private static var shown: (candidates: [String], page: Int)?
    private static var choose: ((Int) -> Void)?

    private static let pageSize = InputSession.Conversion.pageSize
    private static let rowHeight = Paper.rowHeight
    private static let inset = Paper.inset
    private static let numberWidth: CGFloat = 14
    private static let textX: CGFloat = 8 + numberWidth + 4
    private static let footerHeight: CGFloat = 19

    /// `caret` is where the clause starts; `choose` commits candidate `index` of the whole list.
    static func show(_ conversion: InputSession.Conversion, caret: NSRect, choose: @escaping (Int) -> Void) {
        self.choose = choose
        let texts = conversion.candidates.map(\.text)
        let page = conversion.selected / pageSize
        if let panel, panel.isVisible, let shown, shown.candidates == texts, shown.page == page {
            select(conversion.selected % pageSize)
        } else {
            build(conversion, page: page, caret: caret, keepOrigin: shown?.candidates == texts && panel?.isVisible == true)
        }
        shown = (texts, page)
    }

    static func hide() {
        shown = nil
        panel?.orderOut(nil)
    }

    private static func rowFrame(_ index: Int, width: CGFloat) -> NSRect {
        NSRect(x: inset, y: inset + CGFloat(index) * rowHeight, width: width, height: rowHeight)
    }

    private static func build(_ conversion: InputSession.Conversion, page: Int, caret: NSRect, keepOrigin: Bool) {
        let panel = panel ?? {
            let panel = Paper.panel()
            panel.ignoresMouseEvents = false
            return panel
        }()
        self.panel = panel
        let start = page * pageSize
        let items = Array(conversion.candidates[start..<min(start + pageSize, conversion.candidates.count)])
        let pages = (conversion.candidates.count + pageSize - 1) / pageSize
        // As wide as the widest candidate of every page, so turning a page doesn't resize it.
        let textWidth = min(conversion.candidates.map { Paper.label($0.text, size: 14, weight: .semibold).fittingSize.width }.max() ?? 0, 320)
        let rowWidth = max(textX + ceil(textWidth) + 12, 120)
        let size = NSSize(width: rowWidth + inset * 2, height: CGFloat(items.count) * rowHeight + footerHeight + inset * 2)
        let (card, content) = Paper.card(size: size)
        let click = ClickView(frame: card.bounds) { point in
            let row = Int((point.y - inset) / rowHeight)
            guard (0..<items.count).contains(row) else { return }
            choose?(start + row)
        }
        click.autoresizingMask = [.width, .height]

        let selected = conversion.selected - start
        let highlight = Paper.highlight(rowFrame(selected, width: rowWidth))
        content.addSubview(highlight)
        self.highlight = highlight
        rows = items.enumerated().map { index, candidate in
            let row = NSView(frame: rowFrame(index, width: rowWidth))
            let number = Paper.label("\(index + 1)", size: 10.5, weight: .medium)
            number.alignment = .center
            number.frame = NSRect(x: 8, y: (rowHeight - number.fittingSize.height) / 2, width: numberWidth, height: number.fittingSize.height)
            let text = Paper.label(candidate.text, size: 14)
            text.frame = NSRect(x: textX, y: (rowHeight - text.fittingSize.height) / 2,
                                width: ceil(textWidth) + 2, height: text.fittingSize.height)
            row.addSubview(number)
            row.addSubview(text)
            content.addSubview(row)
            return (row, number, text)
        }
        // The reading and the page, under a hairline.
        let footerY = inset + CGFloat(items.count) * rowHeight
        let rule = NSView(frame: NSRect(x: 8, y: footerY + 2, width: rowWidth - 10, height: 1))
        rule.wantsLayer = true
        rule.effectiveAppearance.performAsCurrentDrawingAppearance { rule.layer?.backgroundColor = Paper.line.cgColor }
        content.addSubview(rule)
        let reading = Paper.label(conversion.kana, size: 10.5)
        reading.textColor = Paper.ink2
        reading.frame = NSRect(x: 10, y: footerY + 4, width: rowWidth - 60, height: reading.fittingSize.height)
        content.addSubview(reading)
        if pages > 1 {
            let count = Paper.label("\(page + 1)/\(pages)", size: 10.5)
            count.textColor = Paper.ink2
            count.alignment = .right
            count.frame = NSRect(x: rowWidth - 50, y: footerY + 4, width: 46, height: count.fittingSize.height)
            content.addSubview(count)
        }
        card.addSubview(click)
        card.setAccessibilityRole(.list)
        card.setAccessibilityLabel(L("Candidates, %@ selected", conversion.current.text))
        panel.contentView = card
        select(selected)

        // Under the clause, the candidates' text where the clause's starts.
        var origin = CaretPanel.origin(for: size, caret: caret, gap: 4, centered: false)
        origin.x -= inset + textX
        if keepOrigin { origin = NSPoint(x: panel.frame.minX, y: panel.frame.maxY - size.height) }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.invalidateShadow()
    }

    private static func select(_ index: Int) {
        guard rows.indices.contains(index), let highlight else { return }
        animate(0.16, springy, { highlight.animator().frame = rowFrame(index, width: highlight.frame.width) })
        for (i, row) in rows.enumerated() {
            let on = i == index
            row.text.textColor = Paper.ink
            row.text.font = .systemFont(ofSize: 14, weight: on ? .semibold : .regular)
            row.number.textColor = on ? Paper.accent : Paper.ink2
            row.number.font = .systemFont(ofSize: 10.5, weight: on ? .bold : .medium)
        }
    }
}

/// Takes a click on the candidates (the panel never takes focus) and says where, top-down.
private final class ClickView: NSView {
    private let clicked: (NSPoint) -> Void
    init(frame: NSRect, clicked: @escaping (NSPoint) -> Void) {
        self.clicked = clicked
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { clicked(convert(event.locationInWindow, from: nil)) }
}
