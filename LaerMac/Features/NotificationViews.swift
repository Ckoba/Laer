import AppKit
import LaerCore
import SwiftUI

/// The toolbar bell: unread count beside the icon, the newest notifications in a popover.
struct NotificationsButton: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigation.self) private var navigation
    @State private var isOpen = false
    @State private var loader = CollectionLoader<ParityNotification>(key: "notifications", coverage: .recentWindow) { client in
        PagedResult(items: try await client.notifications(), isComplete: true)
    }

    private var unread: Int { loader.records.filter { $0.isRead == false }.count }

    var body: some View {
        IconButton(Symbol.update, label: unread > 0 ? "Notifications, \(unread) unread" : "Notifications") {
            isOpen.toggle()
        }
        .help("Notifications")
        // A small accent capsule on the bell's top corner.
        .overlay(alignment: .topTrailing) {
            if unread > 0 {
                Text(unread > 99 ? "99+" : unread.formatted())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.onAccent)
                    .monospacedDigit()
                    .padding(.horizontal, 4)
                    .frame(minWidth: 14, minHeight: 14)
                    .background(Capsule().fill(Color.accentFill))
                    .offset(x: 0, y: 3)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            NotificationList(loader: loader) { item in
                isOpen = false
                if let url = navigation.openNotification(item) { NSWorkspace.shared.open(url) }
            }
        }
        .task { await loader.load(using: model) }
    }
}

private struct NotificationList: View {
    @Environment(AppModel.self) private var model
    let loader: CollectionLoader<ParityNotification>
    let onOpen: (ParityNotification) -> Void
    @State private var markAll = WriteAction()

    private func markRead(_ ids: [Int]) async {
        guard !ids.isEmpty else { return }
        if await markAll.run({ try await model.write { try await $0.markNotificationsRead(ids) } }) {
            await loader.refresh(using: model)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.s8) {
                Text("Notifications")
                    .font(Type.t13.weight(.semibold))
                    .foregroundStyle(Color.text)
                Spacer(minLength: Space.s8)
                if (loader.state.phase == .loading && loader.records.isEmpty) || markAll.isRunning { Spinner() }
                if ParityGate.writes, loader.records.contains(where: { $0.isRead == false }) {
                    QuietButton("Mark all read") { Task { await markRead(loader.records.filter { $0.isRead == false }.map(\.notificationId)) } }
                        .disabled(markAll.isRunning)
                }
                // The glyph, not the button's hover square, ends on the rows' trailing edge.
                IconButton(Symbol.refresh, label: "Refresh") { Task { await loader.refresh(using: model) } }
                    .padding(.trailing, -Space.s4)
            }
            .padding(.leading, Space.s8 + Space.s8 + Space.s6)
            .padding(.trailing, Space.s8)
            .padding(.vertical, Space.s4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if case .failed(let message) = loader.state.phase {
                        ErrorLine(message).padding(Space.s8)
                    }
                    if case .failed(let message) = markAll.phase {
                        ErrorLine(message).padding(Space.s8)
                    }
                    if loader.records.isEmpty, loader.state.phase != .loading {
                        EmptyState(state: loader.state, empty: "No notifications")
                            .padding(.horizontal, Space.s8)
                    }
                    ForEach(loader.records) { item in
                        NotificationRow(item: item, open: { onOpen(item) })
                            .contextMenu {
                                if ParityGate.writes, item.isRead == false {
                                    Button("Mark read") { Task { await markRead([item.notificationId]) } }
                                }
                            }
                    }
                }
            }
        }
        .padding(Space.s4)
        .frame(width: 360)
        .frame(maxHeight: 480)
        .background(Color.raised)
    }
}

private struct NotificationRow: View {
    let item: ParityNotification
    let open: () -> Void

    /// The publisher, unless the site hides them.
    private var publisher: ParityPerson? { item.isAnonymous == true ? nil : item.publishedBy }

    var body: some View {
        RowButton(action: open) {
            HStack(alignment: .top, spacing: Space.s6) {
                // Unread is the accent dot in a fixed gutter, kept on every row so the avatars line up.
                Circle()
                    .fill(item.isRead == false ? Color.accent : Color.clear)
                    .frame(width: 6, height: 6)
                    .frame(width: 8, height: 28)
                    .accessibilityHidden(true)
                // Initials when there is no picture; no person means a symbol, never an empty circle.
                if publisher?.fullName != nil || publisher?.imageURLString != nil {
                    Avatar(name: publisher?.fullName, imageURL: publisher?.imageURLString, size: 28)
                } else {
                    SymbolAvatar(symbol: symbol, size: 28)
                }
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text(RichTextCache.inline(item.text ?? ""))
                        .font(item.isRead == false ? Type.t13.weight(.semibold) : Type.t13)
                        .foregroundStyle(Color.text)
                        .lineLimit(3)
                    HStack(spacing: 0) {
                        if let name = publisher?.fullName {
                            Text(name).lineLimit(1)
                            if item.published != nil { Text(" · ").fixedSize() }
                        }
                        if let date = item.published {
                            Text(StudyDates.relative(date))
                                .monospacedDigit()
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .font(Type.t12.weight(.regular))
                    .foregroundStyle(Color.textMuted)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.isRead == false ? "Unread" : "")
    }

    private var symbol: String {
        let kind = "\(item.type ?? "") \(item.text ?? "")".lowercased()
        return kind.contains("plan") ? Symbol.plan : Symbol.update
    }
}

/// An avatar circle for an item with no person: a symbol in the same tinted circle.
private struct SymbolAvatar: View {
    let symbol: String
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Color.accent.opacity(0.2))
            Image(systemName: symbol)
                .font(.system(size: size * 0.43, weight: .medium))
                .foregroundStyle(Color.text.opacity(0.7))
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(Color.border, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// A plain labelled button: a word, optionally after a glyph, muted until hovered. No fill or edge.
private struct QuietButton: View {
    let title: String
    var symbol: String?
    let action: () -> Void
    @State private var isHovering = false

    init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s4) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .regular))
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(Type.t12)
                    .lineLimit(1)
            }
            .foregroundStyle(isHovering ? Color.text : Color.textMuted)
            .padding(.vertical, Space.s4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering in
            if hovering { isHovering = true } else { hoverEnded { isHovering = false } }
        }
    }
}

/// A course's bulletins, used for the Updates tab once the bulletins route passes.
struct BulletinsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigation.self) private var navigation
    private let courseId: Int
    @State private var loader: CollectionLoader<Bulletin>
    @State private var openComments: Set<Int> = []

    init(course: Course) {
        let courseId = course.courseId
        self.courseId = courseId
        _loader = State(initialValue: CollectionLoader(key: "bulletins-\(courseId)", coverage: .recentWindow) { client in
            try await client.bulletins(courseId: courseId)
        })
    }

    var body: some View {
        PageScroll(spacing: 0, lazy: true) {
            FreshnessLine(state: loader.state)
            if case .announcement(let course, let id) = navigation.searchTarget?.destination, course == courseId {
                Button("All announcements", systemImage: Symbol.back) { navigation.searchTarget = nil }
                    .padding(.bottom, Space.s8)
                if let bulletin = loader.records.first(where: { $0.bulletinId == id }) {
                    bulletinRow(bulletin, isLast: true, expanded: true).id(id)
                } else {
                    EmptyState(state: loader.state, empty: "This announcement is unavailable")
                }
            } else if loader.records.isEmpty {
                EmptyState(state: loader.state, empty: "No recent updates")
            } else {
                ForEach(sorted) { bulletin in
                    bulletinRow(bulletin, isLast: bulletin.bulletinId == sorted.last?.bulletinId, expanded: false)
                }
            }
        }
        .dividedRows()
        .task {
            let store = model.snapshots
            await loader.load(using: model)
            await model.indexBulletins(loader.records, courseId: courseId, store: store)
        }
        .focusedSceneValue(\.refreshCurrent, RefreshAction {
            let store = model.snapshots
            await loader.refresh(using: model)
            await model.indexBulletins(loader.records, courseId: courseId, store: store)
        })
    }

    private func bulletinRow(_ bulletin: Bulletin, isLast: Bool, expanded: Bool) -> some View {
        BulletinRow(bulletin: bulletin, isLast: isLast, showsComments: Binding(
            get: { openComments.contains(bulletin.bulletinId) },
            set: { if $0 { openComments.insert(bulletin.bulletinId) } else { openComments.remove(bulletin.bulletinId) } }
        ), isExpanded: expanded)
        .padding(.horizontal, -Space.s8)
    }

    /// Pinned first, then newest first.
    private var sorted: [Bulletin] {
        loader.records.sorted { lhs, rhs in
            if (lhs.pinned == true) != (rhs.pinned == true) { return lhs.pinned == true }
            return (lhs.published ?? .distantPast) > (rhs.published ?? .distantPast)
        }
    }
}

/// One update: author, a line of it and the date; a click opens the whole text and its comments.
private struct BulletinRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let bulletin: Bulletin
    let isLast: Bool
    @Binding var showsComments: Bool
    @State var isExpanded = false

    private var preview: String { RichTextCache.preview(bulletin.text ?? "") }

    var body: some View {
        let count = bulletin.commentsCount ?? 0
        VStack(alignment: .leading, spacing: 0) {
            RowButton(action: { withMotion(Motion.base, reduceMotion: reduceMotion) { isExpanded.toggle() } }) {
                HStack(alignment: .top, spacing: Space.s8) {
                    Avatar(name: bulletin.publishedBy?.fullName, imageURL: bulletin.publishedBy?.imageURLString, size: 28)
                    HStack(alignment: .firstTextBaseline, spacing: Space.s8) {
                        // Author on top, then the announcement itself, so the update reads before it opens.
                        VStack(alignment: .leading, spacing: Space.s4) {
                            HStack(spacing: Space.s6) {
                                Text(bulletin.publishedBy?.fullName ?? "Unknown author")
                                    .font(Type.t13.weight(.semibold))
                                    .foregroundStyle(Color.text)
                                    .lineLimit(1)
                                if bulletin.pinned == true {
                                    HStack(spacing: Space.s2) {
                                        Image(systemName: Symbol.pin)
                                            .font(.system(size: 10, weight: .regular))
                                            .accessibilityHidden(true)
                                        Text("Pinned").font(Type.t11)
                                    }
                                    .foregroundStyle(Color.textMuted)
                                }
                            }
                            if !isExpanded {
                                // The same font as the opened text, so opening only reveals more of it.
                                Text(preview)
                                    .font(Type.body)
                                    .foregroundStyle(Color.text)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                if count > 0 {
                                    Text(count == 1 ? "1 comment" : "\(count) comments")
                                        .font(Type.t12.weight(.regular))
                                        .foregroundStyle(Color.textMuted)
                                }
                            }
                        }
                        Spacer(minLength: Space.s8)
                        // The date alone sits at the trailing edge; the comment count is under the text.
                        if let date = bulletin.published {
                            Text(StudyDates.relative(date))
                                .font(Type.t12.weight(.regular))
                                .foregroundStyle(Color.textMuted)
                                .monospacedDigit()
                                .lineLimit(1)
                                .fixedSize()
                                .help(date.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                }
            }
            .environment(\.rowDividerHidden, isExpanded || isLast)
            .accessibilityAddTraits(isExpanded ? .isSelected : [])
            if isExpanded {
                VStack(alignment: .leading, spacing: Space.s4) {
                    RichTextView(html: bulletin.text ?? "")
                        .frame(maxWidth: Size.readingMax, alignment: .leading)
                    if count > 0 || (ParityGate.writes && bulletin.allowComments == true) {
                        HStack(spacing: Space.s12) {
                            if count > 0 {
                                QuietButton(count == 1 ? "1 comment" : "\(count) comments") { showsComments.toggle() }
                                    .accessibilityAddTraits(showsComments ? .isSelected : [])
                            }
                            if ParityGate.writes, bulletin.allowComments == true {
                                QuietButton("Comment", symbol: Symbol.comment) { showsComments = true }
                            }
                        }
                    }
                    if showsComments {
                        BulletinComments(bulletin: bulletin)
                    }
                }
                // Starts under the author's name: the row's inset, the 28pt avatar and its gap.
                .padding(.leading, Space.s8 + 28 + Space.s8)
                .padding(.trailing, Space.s8)
                // Pull up through the row's bottom padding so the text starts where the preview did.
                .padding(.top, Space.s4 - Space.s12)
                .padding(.bottom, Space.s8)
                if !isLast { RowDivider() }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// A course's gradebook columns with the signed-in person's results where the site shows them.
struct GradesView: View {
    @Environment(AppModel.self) private var model
    @State private var record: CollectionLoader<AssessmentRecord>
    @State private var results: CollectionLoader<PersonAssessments>

    init(course: Course) {
        let courseId = course.courseId
        _record = State(initialValue: CollectionLoader(key: "grades-\(courseId)") { client in
            PagedResult(items: [try await client.assessmentRecord(courseId: courseId)], isComplete: true)
        })
        _results = State(initialValue: CollectionLoader(key: "grade-results-\(courseId)") { client in
            try await client.personAssessments(courseId: courseId)
        })
    }

    var body: some View {
        let items = (record.records.first?.items ?? []) + (record.records.first?.finalItems ?? [])
        PageScroll(spacing: 0, lazy: true) {
            FreshnessLine(state: record.state)
            if items.isEmpty {
                EmptyState(state: record.state, empty: "Nothing is graded in this course yet")
            }
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: Space.s12) {
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Text(item.title ?? "Untitled")
                            .font(item.isFinal == true ? Type.t13.weight(.semibold) : Type.t13)
                            .foregroundStyle(Color.text)
                            .lineLimit(2)
                        if let deadline = StudyDates.usable(item.deadline) {
                            Text(deadline.formatted(date: .abbreviated, time: .omitted))
                                .font(Type.t11)
                                .foregroundStyle(Color.textMuted)
                        }
                    }
                    Spacer(minLength: Space.s8)
                    Text(resultText(for: item))
                        .font(Type.t13)
                        .foregroundStyle(Color.text)
                        .monospacedDigit()
                }
                .plainRow()
                .accessibilityElement(children: .combine)
            }
        }
        .dividedRows()
        .task {
            await record.load(using: model)
            await results.load(using: model)
        }
        .focusedSceneValue(\.refreshCurrent, RefreshAction {
            await record.refresh(using: model)
            await results.refresh(using: model)
        })
    }

    /// A score, a scale value, exempt, or "Not graded". Unknown is never shown as zero.
    private func resultText(for item: GradeItem) -> String {
        guard let result = myResults[item.gradeBookItemId], result.assessmentVisible != false else { return "Not graded" }
        if result.isExempt == true { return "Exempt" }
        if let scaleItem = result.overwrittenAssessmentItemId, let title = scaleTitles[scaleItem] { return title }
        if let score = result.overwrittenScore ?? result.score {
            let value = score.formatted(.number.precision(.fractionLength(0...2)))
            if let max = item.maxScore { return "\(value) / \(max.formatted(.number.precision(.fractionLength(0...2))))" }
            return value
        }
        return "Not graded"
    }

    private var myResults: [Int: PersonAssessments.Result] {
        guard case .ready(let person) = model.authState,
              let row = results.records.first(where: { $0.personId == person.personId }) ?? (results.records.count == 1 ? results.records.first : nil)
        else { return [:] }
        return Dictionary((row.results ?? []).map { ($0.gradeBookItemId, $0) }) { first, _ in first }
    }

    private var scaleTitles: [Int: String] {
        var titles: [Int: String] = [:]
        for scale in record.records.first?.scales ?? [] {
            for value in scale.values ?? [] { titles[value.assessmentItemId] = value.title }
        }
        return titles
    }
}
