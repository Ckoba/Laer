import SwiftUI

// One primitive per control. Rules: docs/ui-reference.md.

// MARK: - Spinner

/// 12pt, one turn per 800ms, linear. Shows only after 180ms so fast loads never flash it.
struct Spinner: View {
    @State private var isVisible = false

    var body: some View {
        TimelineView(.animation(paused: !isVisible)) { context in
            let turn = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: Motion.loopDuration) / Motion.loopDuration
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Color.textMuted, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(turn * 360))
        }
        .frame(width: Size.iconSmall, height: Size.iconSmall)
        .opacity(isVisible ? 1 : 0)
        .task {
            try? await Task.sleep(for: Motion.spinnerDelay)
            isVisible = true
        }
        .accessibilityElement()
        .accessibilityLabel("Loading")
    }
}

// MARK: - Buttons

/// An icon alone, for common actions with a known shape. Always labelled and tooltipped: the
/// tooltip is `help` when given (a longer or fuller phrase), else the label.
struct IconButton: View {
    private let symbol: String
    private let label: String
    private let help: String?
    private let symbolSize: CGFloat
    private let action: () -> Void

    init(_ symbol: String, label: String, help: String? = nil, symbolSize: CGFloat = 13, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.help = help
        self.symbolSize = symbolSize
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: symbolSize, weight: .regular))
                .frame(width: max(Size.icon, symbolSize + 6), height: max(Size.icon, symbolSize + 2))
        }
        .buttonStyle(IconButtonStyle())
        .focusEffectDisabled()
        .help(help ?? label)
        .accessibilityLabel(label)
    }
}

private struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ControlChrome(isPressed: configuration.isPressed, idle: .clear, foreground: nil, mutedAtRest: true) {
            configuration.label
                .frame(minWidth: Size.controlSmall, minHeight: Size.controlSmall)
        }
    }
}

/// An external-link icon (open on the website, open in another app), labelled and tooltipped.
struct IconLinkButton: View {
    private let label: String
    private let action: () -> Void

    init(label: String, action: @escaping () -> Void) {
        self.label = label
        self.action = action
    }

    var body: some View {
        IconButton(Symbol.open, label: label, action: action)
    }
}

/// A navigation link inside a page ("All assignments ›"): accent text, a small trailing chevron.
struct InlineLink: View {
    private let title: String
    private let action: () -> Void
    @State private var isHovering = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    /// The same link, with the label spelled out: `InlineLink(title: "Show older") { … }`.
    init(title: String, action: @escaping () -> Void) {
        self.init(title, action: action)
    }

    var body: some View {
        Button(action: action) {
            // On the text's baseline, so beside a heading the words share its baseline.
            HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                Text(title)
                    .font(Type.t13)
                    .lineLimit(1)
                Image(systemName: Symbol.disclosure)
                    .font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Color.accent)
            .opacity(isHovering ? 0.75 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering in
            if hovering {
                isHovering = true
            } else {
                hoverEnded { isHovering = false }
            }
        }
    }
}

/// A quiet button for leaving Laer for the website ("Open in itslearning", "School links"): the
/// arrow-out icon and the words, in the secondary colour. In-app navigation uses `InlineLink`.
struct WebsiteLink: View {
    private let title: String
    private let action: () -> Void
    @State private var isHovering = false

    init(title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    init(_ title: String, action: @escaping () -> Void) {
        self.init(title: title, action: action)
    }

    var body: some View {
        Button(action: action) {
            // No padding: the link's last pixel is the content column's trailing edge. Its
            // baseline is the words' baseline, so beside a title or heading they share one.
            HStack(alignment: .firstTextBaseline, spacing: Space.s4) {
                Image(systemName: Symbol.website)
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
                Text(title)
                    .font(Type.t13)
                    .lineLimit(1)
            }
            .foregroundStyle(isHovering ? Color.text : Color.textMuted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering in
            if hovering {
                isHovering = true
            } else {
                hoverEnded { isHovering = false }
            }
        }
        .help(title)
    }
}

/// A word, for actions that commit, destroy, or have no shape that says them.
struct TextButton: View {
    enum Role { case normal, primary, danger }

    private let title: String
    private let role: Role
    private let fullWidth: Bool
    private let action: () -> Void

    init(_ title: String, role: Role = .normal, fullWidth: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.role = role
        self.fullWidth = fullWidth
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).font(Type.t13).lineLimit(1)
        }
        .buttonStyle(TextButtonStyle(role: role, fullWidth: fullWidth))
        .focusEffectDisabled()
    }
}

private struct TextButtonStyle: ButtonStyle {
    let role: TextButton.Role
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        ControlChrome(
            isPressed: configuration.isPressed,
            idle: role == .primary ? .accentFill : .raised,
            foreground: foreground,
            edged: role != .primary,
            isPrimary: role == .primary,
            mutedAtRest: false
        ) {
            configuration.label
                .padding(.horizontal, Space.s12)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .frame(height: Size.control)
        }
    }

    private var foreground: Color {
        switch role {
        case .normal: .text
        case .primary: .onAccent
        case .danger: .danger
        }
    }
}

/// Shared hover, pressed, focus and disabled treatment for buttons.
private struct ControlChrome<Label: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var isHovering = false

    let isPressed: Bool
    let idle: Color
    /// Nil means muted at rest and full text colour on hover.
    let foreground: Color?
    var edged = false
    /// A disabled primary button takes the native disabled look: a quaternary grey fill with a
    /// tertiary label, never pale accent.
    var isPrimary = false
    let mutedAtRest: Bool
    @ViewBuilder let label: () -> Label

    private var isDisabledPrimary: Bool { isPrimary && !isEnabled }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
        label()
            .foregroundStyle(isDisabledPrimary ? Color.disabledLabel : foreground ?? (isHovering || isPressed ? Color.text : Color.textMuted))
            .background(ZStack { shape.fill(isDisabledPrimary ? Color.disabledFill : idle); shape.fill(overlay) })
            .overlay(edged ? shape.strokeBorder(Color.border, lineWidth: 1) : nil)
            .overlay(
                isFocused
                    ? RoundedRectangle(cornerRadius: Radius.m + 2, style: .continuous)
                        .strokeBorder(Color.accent, lineWidth: 2)
                        .padding(-4)
                    : nil
            )
            .contentShape(shape)
            .opacity(isEnabled || isDisabledPrimary ? 1 : 0.4)
            .onHover { hovering in
                // In at once, out over `fast`.
                if hovering {
                    isHovering = true
                } else {
                    hoverEnded { isHovering = false }
                }
            }
    }

    private var overlay: Color {
        guard isEnabled else { return .clear }
        if isPressed { return .pressed }
        return isHovering ? .hover : .clear
    }
}

// MARK: - Lines

/// One line in the danger colour, placed beside what failed. Full text in the tooltip.
struct ErrorLine: View {
    private let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        // The session banner already asks the person to sign in; one place is enough.
        if text != AppModel.signedOutMessage {
            Text(text)
                .font(Type.t12)
                .foregroundStyle(Color.danger)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(text)
        }
    }
}

/// One muted line for an empty state. No illustration, no box.
struct EmptyLine: View {
    private let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Type.t13)
            .foregroundStyle(Color.textMuted)
            .lineLimit(1)
    }
}

// MARK: - Section tabs

/// The course tabs, drawn like a native segmented control: a neutral track and a lifted neutral
/// pill for the chosen segment, never an accent fill. Icon and short label. Each segment's
/// accessibility identifier is `tab.<title>` unless `identifier` gives another, so a tab can be
/// renamed on screen without changing its identifier: `identifier: { "tab.\($0.rawName)" }`.
struct SectionTabs<T: Hashable>: View {
    @Binding private var selection: T
    private let items: [(T, String, String?)]
    private let identifier: ((T) -> String)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(selection: Binding<T>, items: [(T, String)], identifier: ((T) -> String)? = nil) {
        _selection = selection
        self.items = items.map { ($0.0, $0.1, nil) }
        self.identifier = identifier
    }

    init(selection: Binding<T>, items: [(T, String, String?)], identifier: ((T) -> String)? = nil) {
        _selection = selection
        self.items = items
        self.identifier = identifier
    }

    var body: some View {
        // Icons alone when the labels don't fit, rather than cutting a word.
        ViewThatFits(in: .horizontal) {
            row(showsLabels: true)
            row(showsLabels: false)
        }
        .accessibilityElement(children: .contain)
    }

    private func row(showsLabels: Bool) -> some View {
        HStack(spacing: Space.s2) {
            ForEach(items, id: \.0) { item in
                SectionTab(
                    title: item.1, symbol: item.2, showsLabel: showsLabels || item.2 == nil,
                    isSelected: item.0 == selection, identifier: identifier?(item.0) ?? "tab.\(item.1)"
                ) {
                    withMotion(Motion.fast, reduceMotion: reduceMotion) { selection = item.0 }
                }
            }
        }
        .padding(Space.s2)
        .background(RoundedRectangle(cornerRadius: Radius.m + Space.s2, style: .continuous).fill(Color.accentTint))
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct SectionTab: View {
    let title: String
    let symbol: String?
    var showsLabel = true
    let isSelected: Bool
    let identifier: String
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
        Button(action: action) {
            HStack(spacing: Space.s6) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .regular))
                        .accessibilityHidden(true)
                }
                if showsLabel {
                    Text(title)
                        .font(Type.t13)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isSelected || isHovering ? Color.text : Color.textMuted)
            .padding(.horizontal, Space.s12)
            .frame(height: Size.controlSmall)
            .background {
                if isSelected {
                    shape.fill(Color.segmentSelected).shadow(color: Color.shadowPopup, radius: 1, y: 0.5)
                } else if isHovering {
                    shape.fill(Color.hover)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .overlay(isFocused ? shape.strokeBorder(Color.accent, lineWidth: 2).padding(-Space.s2) : nil)
        .onHover { hovering in
            if hovering {
                isHovering = true
            } else {
                hoverEnded { isHovering = false }
            }
        }
        .help(showsLabel ? "" : title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Rows

/// Hover and selected fills for a row that is not itself a button. Rows the user clicks to
/// choose something use `RowButton` instead, which also has a pressed state and keyboard focus.
struct RowBackground: ViewModifier {
    var selected: Bool
    @State private var isHovering = false

    func body(content: Content) -> some View {
        RowSurface(fill: selected ? .selected : isHovering ? .hover : nil, isFocused: false) { content }
            .onHover { hovering in
                if hovering {
                    isHovering = true
                } else {
                    hoverEnded { isHovering = false }
                }
            }
    }
}

/// A row that is a button: hover, selected, pressed and a keyboard focus ring.
struct RowButton<Label: View>: View {
    private let selected: Bool
    private let action: () -> Void
    private let label: Label

    init(selected: Bool = false, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.selected = selected
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(action: action) { label }
            .buttonStyle(RowButtonStyle(selected: selected))
            .focusEffectDisabled()
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct RowButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        RowChrome(isPressed: configuration.isPressed, selected: selected) { configuration.label }
    }
}

private struct RowChrome<Label: View>: View {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.rowSelectedFill) private var selectedFill
    @Environment(\.rowHoverFill) private var hoverFill
    @State private var isHovering = false
    let isPressed: Bool
    let selected: Bool
    @ViewBuilder let label: () -> Label

    var body: some View {
        RowSurface(fill: fill, isFocused: isFocused, label: label)
            .onHover { hovering in
                if hovering {
                    isHovering = true
                } else {
                    hoverEnded { isHovering = false }
                }
            }
    }

    private var fill: Color? {
        if isPressed { return .pressed }
        if selected { return selectedFill }
        return isHovering ? hoverFill : nil
    }
}

/// The shared row body. In a divided list (`dividedRows()`) a hairline runs under each row and
/// a filled row grows over the line above and its own, so a rounded fill never sits on a line.
private struct RowSurface<Label: View>: View {
    @Environment(\.rowsDivided) private var divided
    @Environment(\.rowDividerHidden) private var dividerHidden
    @Environment(\.rowSurface) private var surface
    @Environment(\.rowsCompact) private var compact
    @Environment(\.rowIsListRow) private var isListRow
    @Environment(\.rowVerticalPadding) private var verticalPadding
    let fill: Color?
    let isFocused: Bool
    @ViewBuilder let label: () -> Label

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
        label()
            .padding(.horizontal, Space.s8)
            // A `ListRow` sets its own height (44 minimum) and draws its own hairline.
            .padding(.vertical, isListRow ? 0 : verticalPadding ?? (compact ? Space.s6 : divided ? Space.s12 : Space.s8))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if let fill {
                    // Opaque, so the lines it covers don't show through.
                    ZStack { shape.fill(surface); shape.fill(fill) }
                        .padding(.top, divided ? -1 : 0)
                }
            }
            .background(alignment: .bottom) {
                if divided, !dividerHidden, !isListRow {
                    Rectangle().fill(Color.border).frame(height: 1).padding(.horizontal, Space.s8)
                }
            }
            .overlay(isFocused ? shape.strokeBorder(Color.accent, lineWidth: 2) : nil)
            .contentShape(shape)
    }
}

extension View {
    /// A list row: radius m, with hover, selected and pressed fills.
    func laerRow(selected: Bool = false) -> some View {
        modifier(RowBackground(selected: selected))
    }

    /// A row that does nothing on click: the same padding and divider, no hover.
    func plainRow() -> some View {
        RowSurface(fill: nil, isFocused: false) { self }
    }

    /// Rows inside get a hairline between them, and their hover covers it. `surface` is the colour behind the list.
    func dividedRows(on surface: Color = .stage) -> some View {
        environment(\.rowsDivided, true).environment(\.rowSurface, surface)
    }

    /// Rows inside sit apart with no lines, as in the sidebar.
    func undividedRows() -> some View {
        environment(\.rowsDivided, false)
    }
}

extension EnvironmentValues {
    @Entry var rowsDivided = false
    /// Source-list density: with a 16pt symbol and a 13pt label a row is 28pt tall.
    @Entry var rowsCompact = false
    @Entry var rowSurface: Color = .stage
    /// The selected and hover fills of rows in this container; the source list sets its own, stronger pair.
    @Entry var rowSelectedFill: Color = .selected
    @Entry var rowHoverFill: Color = .hover
    /// For an open row whose children sit under it: the line moves below the children.
    @Entry var rowDividerHidden = false
    /// Set by `ListRow` around its own `RowButton`/`RowBackground`.
    @Entry var rowIsListRow = false
    /// Overrides a row's vertical padding (the sidebar's 26pt rows).
    @Entry var rowVerticalPadding: CGFloat? = nil
    /// Set by `ListGroup`: its `ListRow`s draw their hairline.
    @Entry var listGroupActive = false
    /// The space above a page's first content. A course page sets 20 so every tab starts the same distance under the tab bar.
    @Entry var pageTopInset: CGFloat = Size.contentInset
}

// MARK: - List rows and groups

/// A page's section heading: 15pt semibold in the primary label colour, 20pt above and 8pt below,
/// with an optional count after the title in secondary colour, regular weight ("Due 5"),
/// and an optional trailing accessory. Rows go below it in a `ListGroup` or any other stack.
struct SectionHeader<Trailing: View>: View {
    private let title: String
    private let count: Int?
    private let trailing: Trailing

    init(title: String, count: Int? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.count = count
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s8) {
            titleText
                .lineLimit(1)
                // Bold type sits about 1pt inside its frame; pulled back so the heading lines up
                // with the edge of the avatars and icons under it, not 1pt to their right.
                .offset(x: -1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Space.s8)
            trailing
        }
        .padding(.top, Space.s16 + Space.s4)
        .padding(.bottom, Space.s8)
    }

    private var titleText: Text {
        let head = Text(title).font(Type.group).foregroundStyle(Color.text)
        guard let count else { return head }
        return head + Text(" \(count)").font(Type.groupCount).foregroundStyle(Color.textMuted)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, count: Int? = nil) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

/// A small status word ("Overdue", "Submitted"): 11pt medium in the tone's colour, as Reminders
/// marks an overdue date, with no tag behind it. At most one per row, placed in `RowTrailing`.
struct StatusLabel: View {
    enum Tone { case critical, neutral, positive }

    private let text: String
    private let tone: Tone

    init(_ text: String, tone: Tone) {
        self.text = text
        self.tone = tone
    }

    private var color: Color {
        switch tone {
        case .critical: .danger
        case .neutral: .textMuted
        case .positive: .success
        }
    }

    var body: some View {
        Text(text)
            .font(Type.t11)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }
}

/// A `ListRow`'s one trailing column, on one line: [status] date [chevron]. The chevron
/// shows only on rows that navigate, after the date and never after the title.
struct RowTrailing: View {
    private let date: String?
    private let status: StatusLabel?
    private let chevron: Bool
    private let isOverdue: Bool

    /// `isOverdue` draws the date in `Color.danger`; there is no "Overdue" word or badge.
    init(date: String?, status: StatusLabel? = nil, chevron: Bool = false, isOverdue: Bool = false) {
        self.date = date
        self.status = status
        self.chevron = chevron
        self.isOverdue = isOverdue
    }

    var body: some View {
        HStack(spacing: Space.s8) {
            if let status { status }
            if let date {
                Text(date)
                    .font(.system(size: 12))
                    .foregroundStyle(isOverdue ? Color.danger : Color.textMuted)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // A long date or sender shortens here; it never makes the row wider than its
                    // pane. Short dates keep their full width.
                    .frame(maxWidth: 220, alignment: .trailing)
                    .layoutPriority(1)
            }
            if chevron {
                Image(systemName: Symbol.disclosure)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.textFaint)
                    .accessibilityHidden(true)
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        // A first baseline even when there is only a chevron or a status, so a row can put the
        // column on its title's first line.
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + Self.baselineBelowCenter }
    }

    /// How far a 12pt line's baseline sits below its centre.
    static let baselineBelowCenter: CGFloat = 4.5
}

/// The trailing mark of a row that opens on the website, where other rows have the chevron.
struct WebsiteMark: View {
    var body: some View {
        Image(systemName: Symbol.website)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.textFaint)
            .help("Opens on the website")
            .accessibilityLabel("Opens on the website")
    }
}

/// One row of a list: optional leading accessory, a 13pt title (medium when `emphasised`), an
/// optional 12pt secondary subtitle that can start with a course dot, a right-aligned 12pt
/// metadata column. At least 44pt tall. With an `action` the
/// whole width is a button with the `RowButton` hover, selected and focus states.
///
/// Put rows inside a `ListGroup`, which adds the hairlines. Pass the closures by label:
/// `ListRow(title: …, meta: { Text(date) })`.
struct ListRow<Leading: View, Meta: View>: View {
    /// The leading accessory's column: icons and 8pt dots centre in it.
    static var leadingWidth: CGFloat { 20 }

    private let title: String
    private let emphasised: Bool
    private let subtitle: String?
    private let subtitleDot: Color?
    private let selected: Bool
    private let action: (() -> Void)?
    private let leading: Leading
    private let meta: Meta
    /// Width of the leading column; 20 for icons and dots, 28 for avatars.
    private let leadingColumn: CGFloat
    @Environment(\.listGroupActive) private var inGroup

    init(
        title: String,
        emphasised: Bool = false,
        subtitle: String? = nil,
        subtitleDot: Color? = nil,
        selected: Bool = false,
        action: (() -> Void)? = nil,
        leadingWidth: CGFloat = ListRow.leadingWidth,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder meta: () -> Meta
    ) {
        self.leadingColumn = leadingWidth
        self.title = title
        self.emphasised = emphasised
        self.subtitle = subtitle
        self.subtitleDot = subtitleDot
        self.selected = selected
        self.action = action
        self.leading = leading()
        self.meta = meta()
    }

    private var hasLeading: Bool { Leading.self != EmptyView.self }

    var body: some View {
        Group {
            if let action {
                RowButton(selected: selected, action: action) { content }
            } else {
                content.laerRow(selected: selected)
            }
        }
        .environment(\.rowIsListRow, true)
        .overlay(alignment: .bottom) {
            if inGroup {
                Rectangle()
                    .fill(Color.border)
                    .frame(height: 1)
                    .padding(.leading, Space.s8 + (hasLeading ? leadingColumn + Space.s8 : 0))
                    .padding(.trailing, Space.s8)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var content: some View {
        // The leading accessory centres on the whole row; the date, status and chevron sit on the
        // title's first line, so a two-line row keeps them beside its title, not between its lines.
        HStack(alignment: .center, spacing: Space.s8) {
            if hasLeading {
                leading
                    .frame(width: leadingColumn)
                    .accessibilityHidden(true)
            }
            HStack(alignment: .firstTextBaseline, spacing: Space.s8) {
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text(title)
                        .font(emphasised ? Type.t13 : Type.body)
                        .foregroundStyle(Color.text)
                        .lineLimit(2)
                    if let subtitle {
                        HStack(spacing: Space.s6) {
                            if let subtitleDot {
                                Circle().fill(subtitleDot).frame(width: 6, height: 6).accessibilityHidden(true)
                            }
                            Text(subtitle)
                                .font(Type.t12)
                                .foregroundStyle(Color.textMuted)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: Space.s8)
                if Meta.self != EmptyView.self {
                    VStack(alignment: .trailing, spacing: Space.s2) { meta }
                        .font(Type.t12)
                        .foregroundStyle(Color.textMuted)
                        .lineLimit(1)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .padding(.vertical, Space.s8)
        .frame(minHeight: Size.listRow)
    }
}

extension ListRow where Leading == EmptyView {
    init(
        title: String, emphasised: Bool = false, subtitle: String? = nil, subtitleDot: Color? = nil,
        selected: Bool = false, action: (() -> Void)? = nil,
        @ViewBuilder meta: () -> Meta
    ) {
        self.init(
            title: title, emphasised: emphasised, subtitle: subtitle, subtitleDot: subtitleDot,
            selected: selected, action: action, leading: { EmptyView() }, meta: meta
        )
    }
}

/// A titled group of `ListRow`s: the `SectionHeader`, then the rows with a hairline inset to
/// the text under each one except the last. Rows and header text line up with the page title;
/// the hover fill reaches 8pt into the gutter.
struct ListGroup<Trailing: View, Content: View>: View {
    private let title: String?
    private let count: Int?
    private let trailing: Trailing
    private let content: Content

    init(title: String? = nil, count: Int? = nil, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title
        self.count = count
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                SectionHeader(title: title, count: count) { trailing }
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .environment(\.listGroupActive, true)
                // The last row's hairline is its bottom point: mask it off.
                .mask(Rectangle().padding(.bottom, 1))
                .padding(.horizontal, -Space.s8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension ListGroup where Trailing == EmptyView {
    init(title: String? = nil, count: Int? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, count: count, trailing: { EmptyView() }, content: content)
    }
}

/// The line under an open row's children, in a divided list.
struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Color.border).frame(height: 1).padding(.horizontal, Space.s8)
    }
}

/// A row in a divided list that opens to show children: the title's chevron turns, and the
/// children sit indented below with no lines of their own.
struct DisclosureRow<Title: View, Trailing: View, Children: View>: View {
    @Binding var isExpanded: Bool
    /// Off for rows that open an item in place (an update), where the row's hover says it can be clicked.
    var showsChevron = true
    @ViewBuilder var title: () -> Title
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var children: () -> Children
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RowButton(action: { withMotion(Motion.base, reduceMotion: reduceMotion) { isExpanded.toggle() } }) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s8) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.s6) {
                        title()
                        if showsChevron {
                            Image(systemName: Symbol.disclosure)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.textMuted)
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                .accessibilityHidden(true)
                        }
                    }
                    Spacer(minLength: Space.s8)
                    trailing()
                }
            }
            .environment(\.rowDividerHidden, isExpanded)
            .accessibilityAddTraits(isExpanded ? .isSelected : [])
            if isExpanded {
                VStack(alignment: .leading, spacing: Space.s2) {
                    children()
                }
                .undividedRows()
                .padding(.leading, Space.s16)
                .padding(.bottom, Space.s8)
                RowDivider()
            }
        }
    }
}

/// A row title with a chevron right after it that turns when the row is open.
struct DisclosureTitle: View {
    let title: String
    var font: Font = Type.t13
    let isExpanded: Bool
    /// The chevron shows at rest only when open; otherwise on hover.
    var showsChevronAtRest = true

    var body: some View {
        HStack(spacing: Space.s6) {
            Text(title)
                .font(font)
                .foregroundStyle(Color.text)
                .lineLimit(2)
            Image(systemName: Symbol.disclosure)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.textMuted)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .opacity(showsChevronAtRest || isExpanded ? 1 : 0)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Card

/// A raised surface. A card inside a card draws as plain content, so cards never nest.
struct Card<Content: View>: View {
    @Environment(\.isInsideCard) private var isInsideCard
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if isInsideCard {
            content
        } else {
            content
                .padding(Space.s16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).fill(Color.raised))
                .environment(\.isInsideCard, true)
        }
    }
}

private struct InsideCardKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    fileprivate var isInsideCard: Bool {
        get { self[InsideCardKey.self] }
        set { self[InsideCardKey.self] = newValue }
    }
}

// MARK: - Chip

/// A small toggle for a filter: radius m, never a pill. Selected sits on `selected` in `text`.
struct Chip: View {
    private let title: String
    private let isSelected: Bool
    private let action: () -> Void
    @State private var isHovering = false

    init(_ title: String, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
        Button(action: action) {
            Text(title)
                .font(Type.t11)
                .foregroundStyle(isSelected || isHovering ? Color.text : Color.textMuted)
                .lineLimit(1)
                .padding(.horizontal, Space.s8)
                .frame(height: Size.controlSmall - Space.s4)
                .background(shape.fill(isSelected ? Color.selected : isHovering ? Color.hover : Color.clear))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering in
            if hovering {
                isHovering = true
            } else {
                hoverEnded { isHovering = false }
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The box behind a plain text field: `stage` with a hairline, and the accent edge while it has focus,
/// since the plain style drops the system focus ring.
private struct FieldChrome: ViewModifier {
    let isFocused: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
        content
            .background(shape.fill(Color.stage))
            .overlay(shape.strokeBorder(isFocused ? Color.accent : Color.borderStrong, lineWidth: isFocused ? 2 : 1))
    }
}

extension View {
    func fieldChrome(focused: Bool) -> some View { modifier(FieldChrome(isFocused: focused)) }
}

/// A plain button that draws the accent ring when it has keyboard focus, for custom shapes that
/// turn the system focus effect off.
struct FocusRingButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = Radius.m

    func makeBody(configuration: Configuration) -> some View {
        FocusRing(cornerRadius: cornerRadius) { configuration.label }
    }
}

private struct FocusRing<Label: View>: View {
    @Environment(\.isFocused) private var isFocused
    let cornerRadius: CGFloat
    @ViewBuilder let label: () -> Label

    var body: some View {
        label().overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.accent, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }
}
