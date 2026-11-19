import AppKit
import LaerCore
import SwiftUI

/// The surface course text sits on, which decides its colours.
enum RichTextTone: Hashable {
    /// The page or a neutral card.
    case page
    /// The accent fill of a message the signed-in person sent.
    case onAccent
}

/// Course text as one attributed string, so a single text view holds the whole body and selection,
/// ⌘A and copying run across every paragraph, list and heading. Built from `RichText` blocks only:
/// nothing here reads HTML, runs a web view or loads a resource.
@MainActor
enum RichTextLayout {
    static let bodySize: CGFloat = 13
    /// The indent per list level, and the column a list marker sits in.
    static let listIndent: CGFloat = 18
    static let markerColumn: CGFloat = 20

    struct Colors {
        var text: NSColor
        var muted: NSColor
        var fill: NSColor
        var rule: NSColor

        init(_ tone: RichTextTone) {
            switch tone {
            case .page:
                text = NSColor(Color.text)
                muted = NSColor(Color.textMuted)
                fill = NSColor(Color.raised)
                rule = NSColor(Color.borderStrong)
            case .onAccent:
                let ink = accentInkIsDark ? NSColor(white: 0.08, alpha: 1) : NSColor.white
                text = ink
                muted = ink.withAlphaComponent(0.8)
                fill = ink.withAlphaComponent(0.14)
                rule = ink.withAlphaComponent(0.45)
            }
        }
    }

    /// True when the person's accent is light enough (yellow, orange, green) that white text on it
    /// would be hard to read, so text on the accent fill turns near-black instead.
    nonisolated static var accentInkIsDark: Bool {
        guard let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) else { return false }
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(accent.redComponent) + 0.7152 * linear(accent.greenComponent) + 0.0722 * linear(accent.blueComponent)
        return luminance > 0.3
    }

    static func attributed(_ blocks: [RichBlock], tone: RichTextTone) -> NSAttributedString {
        let colors = Colors(tone)
        let output = NSMutableAttributedString()
        var quoteBlock: NSTextBlock?
        for (index, block) in blocks.enumerated() {
            let isLast = index == blocks.count - 1
            let next = isLast ? nil : blocks[index + 1]
            if case .quote = block {} else { quoteBlock = nil }
            switch block {
            case .heading(let level, let runs):
                let size: CGFloat = level <= 2 ? 15 : bodySize
                let style = paragraph(after: block, next: next)
                if index > 0 { style.paragraphSpacingBefore = Space.s4 }
                output.append(text(runs, base: .systemFont(ofSize: size, weight: .semibold), color: colors.text, style: style))
            case .paragraph(let runs):
                output.append(text(runs, base: body, color: colors.text, style: paragraph(after: block, next: next)))
            case .listItem(let ordered, let number, let depth, let runs):
                let style = paragraph(after: block, next: next)
                let indent = CGFloat(depth) * listIndent
                style.firstLineHeadIndent = indent
                style.headIndent = indent + markerColumn
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent + markerColumn)]
                let marker = ordered ? "\(number)." : ["\u{2022}", "\u{25E6}", "\u{25AA}"][min(depth, 2)]
                let line = NSMutableAttributedString(string: marker + "\t", attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: bodySize, weight: .regular),
                    .foregroundColor: colors.muted,
                    .paragraphStyle: style,
                ])
                line.append(text(runs, base: body, color: colors.text, style: style))
                output.append(line)
            case .quote(let runs):
                // Consecutive quote paragraphs share one block, so the bar runs down all of them.
                let block = quoteBlock ?? {
                    let made = fullWidthBlock()
                    made.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
                    made.setBorderColor(colors.rule, for: .minX)
                    made.setWidth(Space.s12, type: .absoluteValueType, for: .padding, edge: .minX)
                    return made
                }()
                quoteBlock = block
                let style = paragraph(after: .quote(runs), next: next)
                style.textBlocks = [block]
                if case .quote = next {} else if !isLast { block.setWidth(Space.s8, type: .absoluteValueType, for: .margin, edge: .maxY) }
                style.paragraphSpacing = { if case .quote = next { return Space.s8 } else { return 0 } }()
                output.append(text(runs, base: body, color: colors.muted, style: style))
            case .code(let code):
                let block = fullWidthBlock()
                block.backgroundColor = colors.fill
                block.setWidth(Space.s8, type: .absoluteValueType, for: .padding)
                if !isLast { block.setWidth(Space.s8, type: .absoluteValueType, for: .margin, edge: .maxY) }
                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]
                output.append(NSAttributedString(string: code, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: colors.text,
                    .paragraphStyle: style,
                ]))
            case .image(let source, let alt):
                // Images need the website's session, so they open there instead of loading here.
                let title = alt.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Image")
                output.append(linkLine(title: title, source: source, symbol: "photo", colors: colors, style: paragraph(after: block, next: next)))
            case .embed(let source):
                output.append(linkLine(title: String(localized: "Embedded content"), source: source, symbol: Symbol.link,
                                       colors: colors, style: paragraph(after: block, next: next)))
            case .table(let rows):
                output.append(table(rows, colors: colors, isLast: isLast))
                continue
            case .rule:
                let block = fullWidthBlock()
                block.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
                block.setBorderColor(colors.rule, for: .maxY)
                block.setWidth(Space.s4, type: .absoluteValueType, for: .margin, edge: .minY)
                if !isLast { block.setWidth(Space.s12, type: .absoluteValueType, for: .margin, edge: .maxY) }
                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]
                style.minimumLineHeight = 1
                style.maximumLineHeight = 1
                output.append(NSAttributedString(string: "\u{00A0}", attributes: [.font: NSFont.systemFont(ofSize: 1), .paragraphStyle: style]))
            }
            if !isLast {
                // The paragraph break carries its paragraph's style, so the block keeps its spacing.
                var attributes = output.length > 0 ? output.attributes(at: output.length - 1, effectiveRange: nil) : [:]
                attributes[.link] = nil
                attributes[.toolTip] = nil
                attributes[.attachment] = nil
                output.append(NSAttributedString(string: "\n", attributes: attributes))
            }
        }
        return output
    }

    private static var body: NSFont { .systemFont(ofSize: bodySize) }

    /// A text block across the whole width. Without a content width, TextKit lays the text out
    /// but draws none of the block's border, background or margins.
    private static func fullWidthBlock() -> NSTextBlock {
        let block = NSTextBlock()
        block.setContentWidth(100, type: .percentageValueType)
        return block
    }

    /// Space below a block: tight between items of one list, a paragraph's worth elsewhere.
    private static func paragraph(after block: RichBlock, next: RichBlock?) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = Type.bodyLineSpacing
        switch (block, next) {
        case (_, nil): style.paragraphSpacing = 0
        case (.listItem, .listItem?): style.paragraphSpacing = Space.s4
        case (.heading, _): style.paragraphSpacing = Space.s4
        default: style.paragraphSpacing = Space.s8
        }
        return style
    }

    private static func text(_ runs: [RichRun], base: NSFont, color: NSColor, style: NSParagraphStyle) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for run in runs {
            // A line break inside a block stays inside its paragraph, so it gets no paragraph spacing.
            let string = run.text.replacingOccurrences(of: "\n", with: "\u{2028}")
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font(for: run, base: base),
                .foregroundColor: color,
                .paragraphStyle: style,
            ]
            if run.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if run.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link {
                attributes[.link] = link
                attributes[.toolTip] = link
            }
            output.append(NSAttributedString(string: string, attributes: attributes))
        }
        return output
    }

    private static func font(for run: RichRun, base: NSFont) -> NSFont {
        if run.code { return .monospacedSystemFont(ofSize: base.pointSize - 1, weight: .regular) }
        var font = base
        if run.bold { font = .systemFont(ofSize: base.pointSize, weight: base.pointSize > bodySize ? .bold : .semibold) }
        if run.italic {
            font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: font.pointSize) ?? font
        }
        return font
    }

    private static func linkLine(title: String, source: String, symbol: String, colors: Colors, style: NSParagraphStyle) -> NSAttributedString {
        let line = NSMutableAttributedString()
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular)) {
            let attachment = NSTextAttachment()
            attachment.image = image
            line.append(NSAttributedString(attachment: attachment))
            line.append(NSAttributedString(string: " "))
        }
        line.append(NSAttributedString(string: title))
        line.addAttributes([
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: colors.muted,
            .paragraphStyle: style,
            .link: source,
            .toolTip: String(localized: "Open on the website"),
        ], range: NSRange(location: 0, length: line.length))
        return line
    }

    private static func table(_ rows: [[RichTableCell]], colors: Colors, isLast: Bool) -> NSAttributedString {
        let columns = rows.map(\.count).max() ?? 1
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setContentWidth(100, type: .percentageValueType)
        if !isLast { table.setWidth(Space.s8, type: .absoluteValueType, for: .margin, edge: .maxY) }
        let output = NSMutableAttributedString()
        for (rowIndex, row) in rows.enumerated() {
            for column in 0..<columns {
                let cell = column < row.count ? row[column] : RichTableCell(runs: [])
                let block = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setBorderColor(colors.rule)
                block.setWidth(Space.s6, type: .absoluteValueType, for: .padding)
                if cell.isHeader { block.backgroundColor = colors.fill }
                let style = NSMutableParagraphStyle()
                style.lineSpacing = Type.bodyLineSpacing
                style.textBlocks = [block]
                let base: NSFont = cell.isHeader ? .systemFont(ofSize: bodySize, weight: .semibold) : body
                output.append(text(cell.runs, base: base, color: colors.text, style: style))
                // Every cell is its own paragraph.
                output.append(NSAttributedString(string: "\n", attributes: [.font: base, .paragraphStyle: style]))
            }
        }
        return output
    }
}

/// A read-only text view that holds a whole body of course text.
final class RichNSTextView: NSTextView {
    /// The scroll view around the page scrolls; this view never does.
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func layout() {
        super.layout()
        // The container is as wide as the view and never clips: SwiftUI has already sized the
        // view to the text's full height.
        if let container = textContainer,
           container.size.width != bounds.width || container.size.height < CGFloat.greatestFiniteMagnitude / 2 {
            container.size = NSSize(width: bounds.width, height: .greatestFiniteMagnitude)
        }
    }

    /// Copies keep the author's formatting but not the theme's colours, so text pasted into a light
    /// document is not white from a dark-mode copy.
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let storage = textStorage else { return super.writeSelection(to: pboard, types: types) }
        let copy = NSMutableAttributedString()
        for range in selectedRanges.map(\.rangeValue) where range.length > 0 {
            if copy.length > 0 { copy.append(NSAttributedString(string: "\n")) }
            copy.append(storage.attributedSubstring(from: range))
        }
        guard copy.length > 0 else { return false }
        let whole = NSRange(location: 0, length: copy.length)
        copy.removeAttribute(.foregroundColor, range: whole)
        copy.removeAttribute(.backgroundColor, range: whole)
        copy.removeAttribute(.toolTip, range: whole)
        copy.mutableString.replaceOccurrences(of: "\u{2028}", with: "\n", options: [], range: whole)
        pboard.declareTypes([.rtf, .string], owner: nil)
        if let rtf = copy.rtf(from: NSRange(location: 0, length: copy.length), documentAttributes: [:]) {
            pboard.setData(rtf, forType: .rtf)
        }
        pboard.setString(copy.string, forType: .string)
        return true
    }
}

/// One `RichNSTextView` sized to its text for the width SwiftUI offers.
struct RichTextBody: NSViewRepresentable {
    let blocks: [RichBlock]
    let tone: RichTextTone
    /// True to take only as much width as the longest line, as a message bubble does.
    let hugsWidth: Bool
    let open: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> RichNSTextView {
        let view = RichNSTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.importsGraphics = false
        view.allowsUndo = false
        view.drawsBackground = false
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textContainerInset = .zero
        view.isAutomaticLinkDetectionEnabled = false
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.textContainer?.size = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: RichNSTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.open = open
        let key = Coordinator.Key(blocks: blocks, tone: tone, darkInk: tone == .onAccent && RichTextLayout.accentInkIsDark)
        guard coordinator.key != key else { return }
        coordinator.key = key
        let text = RichTextLayout.attributed(blocks, tone: tone)
        view.textStorage?.setAttributedString(text)
        coordinator.measure.setAttributedString(text)
        coordinator.heights = [:]
        let colors = RichTextLayout.Colors(tone)
        // Links read by underline, not hue.
        view.linkTextAttributes = [
            .foregroundColor: colors.text,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        // The system highlight would vanish on the accent fill.
        view.selectedTextAttributes = tone == .onAccent
            ? [.backgroundColor: colors.text.withAlphaComponent(0.3)]
            : [.backgroundColor: NSColor.selectedTextBackgroundColor]
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RichNSTextView, context: Context) -> CGSize? {
        // No width offered (an ideal size): lay out at the reading width and report what that needs.
        let offered = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let width = max(offered ?? Size.readingColumn, 60)
        let used = context.coordinator.size(forWidth: width)
        return CGSize(width: hugsWidth || offered == nil ? min(width, used.width) : width, height: used.height)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        struct Key: Equatable {
            var blocks: [RichBlock]
            var tone: RichTextTone
            var darkInk: Bool
        }

        var key: Key?
        var open: (String) -> Void = { _ in }
        var heights: [CGFloat: CGSize] = [:]
        /// A second layout stack for measuring, so asking for a size never disturbs what is on screen.
        let measure = NSTextStorage()
        private let manager = NSLayoutManager()
        private let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))

        override init() {
            super.init()
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            measure.addLayoutManager(manager)
        }

        func size(forWidth width: CGFloat) -> CGSize {
            let rounded = width.rounded(.down)
            if let hit = heights[rounded] { return hit }
            container.size = NSSize(width: rounded, height: .greatestFiniteMagnitude)
            manager.ensureLayout(for: container)
            var used = manager.usedRect(for: container)
            // A trailing newline (after a table) leaves an empty last line; it is not content.
            let extra = manager.extraLineFragmentUsedRect
            if measure.length > 0, !extra.isEmpty { used.size.height -= extra.height }
            let result = CGSize(width: ceil(used.width), height: ceil(max(used.height, 0)))
            heights[rounded] = result
            return result
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL { open(url.absoluteString) } else if let string = link as? String { open(string) }
            return true
        }
    }
}
