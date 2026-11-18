import LaerCore
import SwiftUI

/// The toolbar bell: unread count beside the icon, the newest notifications in a popover.
struct NotificationsButton: View {
    @Environment(AppModel.self) private var model
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
            NotificationList(loader: loader)
        }
        .task { await loader.load(using: model) }
    }
}

private struct NotificationList: View {
    @Environment(AppModel.self) private var model
    let loader: CollectionLoader<ParityNotification>
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
                    TextButton("Mark all read") { Task { await markRead(loader.records.filter { $0.isRead == false }.map(\.notificationId)) } }
                        .disabled(markAll.isRunning)
                }
                IconButton(Symbol.refresh, label: "Refresh") { Task { await loader.refresh(using: model) } }
            }
            .padding(.horizontal, Space.s8)
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
                    let anyPublisher = loader.records.contains { $0.isAnonymous != true && $0.publishedBy?.fullName?.isBlank == false }
                    ForEach(loader.records) { item in
                        NotificationRow(item: item, reservesAvatar: anyPublisher)
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
    @Environment(AppModel.self) private var model
    let item: ParityNotification
    /// True when other rows in the list show a picture, so text lines up down the list.
    var reservesAvatar = false

    /// The publisher, unless the site hides them.
    private var publisher: ParityPerson? { item.isAnonymous == true ? nil : item.publishedBy }

    var body: some View {
        RowButton(action: open) {
            HStack(alignment: .top, spacing: Space.s8) {
                if let publisher, publisher.fullName?.isBlank == false {
                    Avatar(name: publisher.fullName, imageURL: publisher.imageURLString, size: 28)
                } else if reservesAvatar {
                    Color.clear.frame(width: 28, height: 28)
                }
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text(RichTextCache.plainText(item.text ?? ""))
                        .font(item.isRead == false ? Type.t13.weight(.semibold) : Type.t13)
                        .foregroundStyle(Color.text)
                        .lineLimit(3)
                    HStack(spacing: Space.s6) {
                        if let name = publisher?.fullName {
                            Text(name).lineLimit(1)
                        }
                        if let date = item.published {
                            Text(StudyDates.relative(date))
                        }
                    }
                    .font(Type.t11)
                    .foregroundStyle(Color.textMuted)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.isRead == false ? "Unread" : "")
    }

    private func open() {
        if let url = model.absoluteURL(item.url) { NSWorkspace.shared.open(url) }
    }
}

/// A course's bulletins, used for the Updates tab once the bulletins route passes.
struct BulletinsView: View {
    @Environment(AppModel.self) private var model
    @State private var loader: CollectionLoader<Bulletin>
    @State private var openComments: Set<Int> = []

    init(course: Course) {
        let courseId = course.courseId
        _loader = State(initialValue: CollectionLoader(key: "bulletins-\(courseId)", coverage: .recentWindow) { client in
            try await client.bulletins(courseId: courseId)
        })
    }

    var body: some View {
        PageScroll(spacing: 0, lazy: true) {
            FreshnessLine(state: loader.state)
            if loader.records.isEmpty {
                EmptyState(state: loader.state, empty: "No recent updates")
            }
            ForEach(sorted) { bulletin in
                BulletinRow(bulletin: bulletin, isLast: bulletin.bulletinId == sorted.last?.bulletinId, showsComments: Binding(
                    get: { openComments.contains(bulletin.bulletinId) },
                    set: { if $0 { openComments.insert(bulletin.bulletinId) } else { openComments.remove(bulletin.bulletinId) } }
                ))
                // Row fills reach into the gutter so the text starts at the page title's x.
                .padding(.horizontal, -Space.s8)
            }
        }
        .dividedRows()
        .task { await loader.load(using: model) }
        .focusedSceneValue(\.refreshCurrent, RefreshAction { await loader.refresh(using: model) })
    }

    /// Pinned first, then newest first.
    private var sorted: [Bulletin] {
        loader.records.sorted { lhs, rhs in
            if (lhs.pinned == true) != (rhs.pinned == true) { return lhs.pinned == true }
            return (lhs.published ?? .distantPast) > (rhs.published ?? .distantPast)
        }
    }
}

/// One update: author, a line of it and the date; the trailing chevron opens the whole text and its comments.
private struct BulletinRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let bulletin: Bulletin
    let isLast: Bool
    @Binding var showsComments: Bool
    @State private var isExpanded = false

    private var preview: String { RichTextCache.plainText(bulletin.text ?? "") }

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
                                Text(preview)
                                    .font(Type.t13)
                                    .foregroundStyle(Color.text)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: Space.s8)
                        // Count, date and chevron share the trailing edge.
                        HStack(spacing: Space.s8) {
                            if count > 0 {
                                HStack(spacing: Space.s4) {
                                    Image(systemName: Symbol.comments).font(.system(size: 11, weight: .regular))
                                    Text(count.formatted()).monospacedDigit()
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(count == 1 ? "1 comment" : "\(count) comments")
                            }
                            if let date = bulletin.published {
                                Text(StudyDates.relative(date))
                                    .monospacedDigit()
                                    .help(date.formatted(date: .abbreviated, time: .shortened))
                            }
                            Image(systemName: Symbol.disclosure)
                                .font(.system(size: 10, weight: .semibold))
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                .accessibilityHidden(true)
                        }
                        .font(Type.t11)
                        .foregroundStyle(Color.textMuted)
                    }
                }
            }
            .environment(\.rowDividerHidden, isExpanded || isLast)
            .accessibilityAddTraits(isExpanded ? .isSelected : [])
            if isExpanded {
                VStack(alignment: .leading, spacing: Space.s4) {
                    RichTextView(html: bulletin.text ?? "")
                    if count > 0 || (ParityGate.writes && bulletin.allowComments == true) {
                        HStack(spacing: Space.s2) {
                            if ParityGate.writes, bulletin.allowComments == true {
                                IconButton(Symbol.comment, label: "Write a comment") { showsComments = true }
                            }
                            if count > 0 {
                                IconButton(Symbol.comments, label: showsComments ? "Hide comments" : "Show comments") { showsComments.toggle() }
                            }
                        }
                        .padding(.leading, -Space.s4)
                    }
                    if showsComments {
                        BulletinComments(bulletin: bulletin)
                    }
                }
                .padding(.horizontal, Space.s8)
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
