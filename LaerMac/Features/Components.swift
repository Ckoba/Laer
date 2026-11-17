import LaerCore
import SwiftUI

/// Freshness for one collection, shown only when something is not normal:
/// refreshing, failed, partial, or older than the freshness threshold.
struct FreshnessLine: View {
    let state: CollectionState
    static let staleAfter: TimeInterval = 5 * 60

    private var isStale: Bool {
        guard let date = state.lastSuccess else { return false }
        return Date().timeIntervalSince(date) > Self.staleAfter
    }

    /// A refresh over cached content shows nothing: what's on screen is already the answer.
    private var isQuietRefresh: Bool { state.phase == .loading && state.lastSuccess != nil }

    /// The normal state takes no space, so nothing sits above a page's first row.
    private var hasContent: Bool {
        if isQuietRefresh { return false }
        return state.phase != .idle || state.isIncomplete || isStale
    }

    var body: some View {
        if hasContent {
            HStack(spacing: Space.s6) {
                switch state.phase {
                case .loading:
                    Spinner()
                case .failed(let message):
                    ErrorLine(state.lastSuccess == nil ? message : "\(message) Showing the saved copy.")
                case .idle:
                    if state.isIncomplete {
                        Text("Partial list").font(Type.t11).foregroundStyle(Color.textMuted)
                    }
                    if isStale, let date = state.lastSuccess {
                        Text("Updated \(date.formatted(.relative(presentation: .named)))")
                            .font(Type.t11)
                            .foregroundStyle(Color.textMuted)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: Size.controlSmall, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }
}

/// What a list shows instead of rows. Unknown is not zero: an empty line only after a successful read.
struct EmptyState: View {
    let state: CollectionState
    let empty: String

    var body: some View {
        Group {
            switch state.phase {
            case .loading: Spinner()
            case .failed(let message): ErrorLine(message)
            case .idle:
                if state.lastSuccess != nil {
                    EmptyLine(empty)
                } else {
                    EmptyLine("Unavailable until the next refresh")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Space.s8)
    }
}

/// A page's title with an optional trailing control.
struct PageHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s8) {
            Text(title)
                .font(Type.t18)
                .foregroundStyle(Color.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Space.s8)
            trailing()
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// A bar across the top when the session has ended. Content below stays readable.
struct SessionBanner: View {
    @Environment(AppModel.self) private var model
    let message: String

    var body: some View {
        HStack(spacing: Space.s8) {
            Text(message)
                .font(Type.t13)
                .foregroundStyle(Color.text)
                .lineLimit(1)
            Spacer(minLength: Space.s8)
            TextButton("Sign in", role: .primary) { model.beginSignIn() }
        }
        .padding(.horizontal, Space.s12)
        .padding(.vertical, Space.s6)
        .background(Color.raised)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.borderStrong).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }
}

/// A plain text field on the design's tokens.
struct FieldBox: View {
    let label: String
    @Binding var text: String
    var onSubmit: () -> Void = {}

    var body: some View {
        TextField(label, text: $text)
            .textFieldStyle(.plain)
            .font(Type.t13)
            .foregroundStyle(Color.text)
            .padding(.horizontal, Space.s8)
            .frame(height: Size.control)
            .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Color.stage))
            .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).strokeBorder(Color.borderStrong, lineWidth: 1))
            .onSubmit(onSubmit)
            .accessibilityLabel(label)
    }
}

/// A scrolling page on `stage` with the page gutter.
struct PageScroll<Content: View>: View {
    /// 0 for a divided list, where rows meet at their hairlines.
    var spacing: CGFloat = Space.s4
    /// For long lists, so only the rows on screen are built. Forms stay eager, so fields keep focus.
    var lazy = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            Group {
                if lazy {
                    LazyVStack(alignment: .leading, spacing: spacing) { content() }
                } else {
                    VStack(alignment: .leading, spacing: spacing) { content() }
                }
            }
            .frame(maxWidth: Size.readingColumn, alignment: .leading)
            .padding(Space.s24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.stage)
    }
}

enum StudyDates {
    /// Tasks with a deadline come first, soonest first. A missing deadline stays missing.
    static func sorted(_ tasks: [StudyTask]) -> [StudyTask] {
        tasks.sorted { lhs, rhs in
            switch (usable(lhs.deadline), usable(rhs.deadline)) {
            case let (a?, b?): a < b
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }
    }

    static func deadline(_ date: Date?) -> String {
        guard let date = usable(date) else { return "No deadline" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// A compact deadline for a row: the time today, the weekday this week, else the date.
    static func shortDeadline(_ date: Date?, now: Date = Date()) -> String {
        guard let date = usable(date) else { return "No deadline" }
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if abs(date.timeIntervalSince(now)) < 6 * 24 * 3600 {
            return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    /// A task's status in words. The normal state, not started, shows nothing.
    static func statusText(_ status: String?) -> String? {
        switch status?.lowercased() {
        case "completed", "done": "Done"
        case "inprogress", "started": "In progress"
        case "submitted", "handedin": "Submitted"
        default: nil
        }
    }

    static func planRange(start: Date?, stop: Date?) -> String {
        switch (usable(start), usable(stop)) {
        case let (a?, b?): (a..<max(a, b)).formatted(.interval.day().month(.abbreviated).year())
        case let (a?, nil): "From \(a.formatted(date: .abbreviated, time: .omitted))"
        case let (nil, b?): "Until \(b.formatted(date: .abbreviated, time: .omitted))"
        case (nil, nil): "No dates"
        }
    }

    /// A far-future placeholder year is not a real date.
    static func usable(_ date: Date?) -> Date? {
        guard let date else { return nil }
        return Calendar(identifier: .gregorian).component(.year, from: date) >= 9000 ? nil : date
    }
}

extension String {
    /// True when the text is empty or only whitespace and newlines.
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
