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

/// An icon alone, for common actions with a known shape. Always labelled and tooltipped.
struct IconButton: View {
    private let symbol: String
    private let label: String
    private let action: () -> Void

    init(_ symbol: String, label: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .frame(width: Size.icon, height: Size.icon)
        }
        .buttonStyle(IconButtonStyle())
        .focusEffectDisabled()
        .help(label)
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

/// A word, for actions that commit, destroy, or have no shape that says them.
struct TextButton: View {
    enum Role { case normal, primary, danger }

    private let title: String
    private let role: Role
    private let action: () -> Void

    init(_ title: String, role: Role = .normal, action: @escaping () -> Void) {
        self.title = title
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).font(Type.t13).lineLimit(1)
        }
        .buttonStyle(TextButtonStyle(role: role))
        .focusEffectDisabled()
    }
}

private struct TextButtonStyle: ButtonStyle {
    let role: TextButton.Role

    func makeBody(configuration: Configuration) -> some View {
        ControlChrome(
            isPressed: configuration.isPressed,
            idle: role == .primary ? .accentFill : .raised,
            foreground: foreground,
            edged: role != .primary,
            mutedAtRest: false
        ) {
            configuration.label
                .padding(.horizontal, Space.s12)
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
    let mutedAtRest: Bool
    @ViewBuilder let label: () -> Label

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
        label()
            .foregroundStyle(foreground ?? (isHovering || isPressed ? Color.text : Color.textMuted))
            .background(ZStack { shape.fill(idle); shape.fill(overlay) })
            .overlay(edged ? shape.strokeBorder(Color.border, lineWidth: 1) : nil)
            .overlay(
                isFocused
                    ? RoundedRectangle(cornerRadius: Radius.m + 2, style: .continuous)
                        .strokeBorder(Color.accent, lineWidth: 2)
                        .padding(-4)
                    : nil
            )
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.4)
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
        Text(text)
            .font(Type.t12)
            .foregroundStyle(Color.danger)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(text)
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

/// Replaces segmented pickers. Icon and short label; the selected one sits on a rounded `selected` fill.
struct SectionTabs<T: Hashable>: View {
    @Binding private var selection: T
    private let items: [(T, String, String?)]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(selection: Binding<T>, items: [(T, String)]) {
        _selection = selection
        self.items = items.map { ($0.0, $0.1, nil) }
    }

    init(selection: Binding<T>, items: [(T, String, String?)]) {
        _selection = selection
        self.items = items
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
        HStack(spacing: Space.s4) {
            ForEach(items, id: \.0) { item in
                SectionTab(title: item.1, symbol: item.2, showsLabel: showsLabels || item.2 == nil, isSelected: item.0 == selection) {
                    withMotion(Motion.fast, reduceMotion: reduceMotion) { selection = item.0 }
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct SectionTab: View {
    let title: String
    let symbol: String?
    var showsLabel = true
    let isSelected: Bool
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
            .frame(height: Size.control)
            .background(shape.fill(isSelected ? Color.selected : isHovering ? Color.hover : Color.clear))
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
        .accessibilityIdentifier("tab.\(title)")
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
        if selected { return .selected }
        return isHovering ? .hover : nil
    }
}

/// The shared row body. In a divided list (`dividedRows()`) a hairline runs under each row and
/// a filled row grows over the line above and its own, so a rounded fill never sits on a line.
private struct RowSurface<Label: View>: View {
    @Environment(\.rowsDivided) private var divided
    @Environment(\.rowDividerHidden) private var dividerHidden
    @Environment(\.rowSurface) private var surface
    let fill: Color?
    let isFocused: Bool
    @ViewBuilder let label: () -> Label

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
        label()
            .padding(.horizontal, Space.s8)
            .padding(.vertical, divided ? Space.s12 : Space.s8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if let fill {
                    // Opaque, so the lines it covers don't show through.
                    ZStack { shape.fill(surface); shape.fill(fill) }
                        .padding(.top, divided ? -1 : 0)
                }
            }
            .background(alignment: .bottom) {
                if divided, !dividerHidden {
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
    @Entry var rowSurface: Color = .stage
    /// For an open row whose children sit under it: the line moves below the children.
    @Entry var rowDividerHidden = false
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
                        Image(systemName: Symbol.disclosure)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.textMuted)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .accessibilityHidden(true)
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
