import LaerCore
import SwiftUI

enum CourseTab: Hashable, CaseIterable {
    case plans, updates, materials, calendar, participants, grades

    var title: String {
        switch self {
        case .updates: "Updates"
        case .materials: "Files"
        case .plans: "Plans"
        case .calendar: "Calendar"
        case .grades: "Grades"
        case .participants: "Participants"
        }
    }

    /// The accessibility identifier, from the tab's English name, so it stays when a label changes.
    var identifier: String {
        switch self {
        case .updates: "tab.Updates"
        case .materials: "tab.Files"
        case .plans: "tab.Plans"
        case .calendar: "tab.Calendar"
        case .grades: "tab.Grades"
        case .participants: "tab.Participants"
        }
    }

    var symbol: String {
        switch self {
        case .updates: Symbol.update
        case .materials: Symbol.folder
        case .plans: Symbol.brief
        case .calendar: Symbol.plan
        case .grades: Symbol.grades
        case .participants: Symbol.account
        }
    }

    /// Tabs whose routes are in use. Grades is last, so the other tabs keep their shortcuts
    /// whether or not the site allows it. See `ParityGate`.
    static func available(grades: Bool = false) -> [CourseTab] {
        allCases.filter { tab in
            switch tab {
            case .calendar: ParityGate.courseCalendar
            case .participants: ParityGate.participants
            case .grades: ParityGate.grades && grades
            default: true
            }
        }
    }
}

struct CourseDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigation.self) private var navigation
    let course: Course
    private var grades: GradesAvailability { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                CourseTabBar(
                    selection: navigation.tabBinding(for: course.courseId),
                    tabs: CourseTab.available(grades: grades.isAvailable(courseId: course.courseId, model: model)))
            }
            // The same full-width column as the tab content below (`PageScroll`): the title row, the
            // tab bar and the rows start 24pt from the leading edge and end 24pt from the trailing one.
            .pageColumn()
            .padding(.top, Space.s24)
            Group {
                switch navigation.tab(for: course.courseId) {
                case .updates:
                    if ParityGate.bulletins { BulletinsView(course: course) } else { UpdatesView(course: course) }
                case .materials: MaterialsView(course: course)
                case .plans: PlansView(course: course)
                case .calendar: CourseCalendarView(course: course)
                case .grades: GradesView(course: course)
                case .participants: ParticipantsView(course: course)
                }
            }
            // One 20pt gap from the tab bar to the first content on every tab.
            .environment(\.pageTopInset, Space.s16 + Space.s4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle(course.shortTitle)
        // The open search palette uses ⌘1–6 for its own tabs, so the course tabs step aside.
        .focusedSceneValue(\.courseTab, navigation.isPaletteOpen ? nil : navigation.tabBinding(for: course.courseId))
        .task { await grades.probe(courseId: course.courseId, using: model) }
    }

    /// The course's colour and name, with "Open in itslearning" at the column's trailing edge.
    /// The name truncates before the link gives way.
    private var header: some View {
        let url = model.absoluteURL(course.url)
        return PageHeader(title: course.shortTitle, dot: Color.course(course.courseId)) {
            if let url { WebsiteLink("Open in itslearning") { NSWorkspace.shared.open(url) }.fixedSize() }
        }
    }
}

/// The course's tabs as one segmented control on a neutral track: the chosen tab is a lifted
/// white pill, never an accent fill. Each tab keeps the identifier of its English name
/// (`tab.Plans`, `tab.Files`, ...), whatever its visible label says. A segmented `Picker` cannot
/// give each segment its own identifier, so this draws the same control with buttons.
private struct CourseTabBar: View {
    @Binding var selection: CourseTab
    let tabs: [CourseTab]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            ForEach(tabs, id: \.self) { tab in
                CourseTabButton(tab: tab, showsLabel: showsLabels, isSelected: tab == selection) {
                    withMotion(Motion.fast, reduceMotion: reduceMotion) { selection = tab }
                }
            }
        }
        .padding(Space.s2)
        .background(RoundedRectangle(cornerRadius: Radius.m + Space.s2, style: .continuous).fill(Color.accentTint))
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct CourseTabButton: View {
    let tab: CourseTab
    let showsLabel: Bool
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
        Button(action: action) {
            HStack(spacing: Space.s6) {
                if !showsLabel {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 12, weight: .regular))
                        .accessibilityHidden(true)
                } else {
                    Text(tab.title)
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
        .help(showsLabel ? "" : tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(tab.identifier)
    }
}

struct UpdatesView: View {
    @Environment(AppModel.self) private var model
    let course: Course

    var body: some View {
        let items = model.updates[course.courseId] ?? []
        let state = model.updatesState[course.courseId] ?? CollectionState()
        PageScroll(spacing: 0, lazy: true) {
            FreshnessLine(state: state)
            if items.isEmpty {
                EmptyState(state: state, empty: "No recent updates")
            }
            ForEach(items) { update in
                UpdateRow(update: update)
            }
        }
        .dividedRows()
        .task { await model.loadUpdates(courseId: course.courseId) }
    }
}

/// One update: author, a line of it and the date; the chevron opens the whole text.
private struct UpdateRow: View {
    @Environment(AppModel.self) private var model
    let update: CourseUpdate
    @State private var isExpanded = false

    private var html: String {
        update.lightBulletin?.text.flatMap { $0.isEmpty ? nil : $0 } ?? update.text ?? ""
    }

    var body: some View {
        DisclosureRow(isExpanded: $isExpanded, showsChevron: false) {
            HStack(alignment: .center, spacing: Space.s8) {
                Avatar(name: update.publishedBy?.fullName, imageURL: update.publishedBy?.imageURLString, size: 28)
                HStack(alignment: .firstTextBaseline, spacing: Space.s8) {
                    Text(update.publishedBy?.fullName ?? "Unknown author")
                        .font(Type.t13.weight(.semibold))
                        .foregroundStyle(Color.text)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if !isExpanded {
                        Text(RichTextCache.preview(html))
                            .font(Type.t13)
                            .foregroundStyle(Color.textMuted)
                            .lineLimit(1)
                    }
                }
            }
        } trailing: {
            if let date = update.published {
                Text(date.formatted(.relative(presentation: .named)))
                    .font(Type.t11)
                    .foregroundStyle(Color.textMuted)
                    .monospacedDigit()
                    .help("\(date.formatted(date: .abbreviated, time: .omitted)) \(StudyDates.time(date))")
            }
        } children: {
            RichTextView(html: html)
                .readingWidth()
                .padding(.horizontal, Space.s8)
        }
        .contextMenu {
            if let url = model.absoluteURL(update.url) {
                Button("Open on the website") { NSWorkspace.shared.open(url) }
            }
        }
    }
}

/// A course's plans. The current plan leads its topic, in the open topic; below it, plans group
/// under their topics when the course has any, otherwise later ones list first and earlier ones collapse.
struct PlansView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigation.self) private var navigation
    let course: Course
    @State private var showsPrevious = false
    /// Topic groups the person opened or closed; the others follow the current plan.
    @State private var topicExpansion: [String: Bool] = [:]
    @State private var memo = Memo<[PlanPreview], PlanSections>()
    @State private var groupMemo = Memo<TopicKey, [PlanTopicGroup]?>()

    /// How far plans sit in from their topic's leading edge: the one chevron column's width and gap.
    private static let topicIndent: CGFloat = 20

    private struct TopicKey: Equatable {
        var plans: [PlanPreview]
        var topics: [Topic]
        var minute: Date
    }

    var body: some View {
        let items = model.plans[course.courseId] ?? []
        let state = model.plansState[course.courseId] ?? CollectionState()
        let topics = model.topics[course.courseId] ?? []
        let sections = memo.value(for: items) { PlanOrder.sections(items, now: Date()) }
        let groups = groupMemo.value(for: TopicKey(plans: items, topics: topics, minute: currentMinute())) {
            PlanTopics.groups(items, topics: topics, now: Date())
        }
        PageScroll(spacing: 0, lazy: true) {
            FreshnessLine(state: state)
            if case .plan(let courseId, let planId) = navigation.searchTarget?.destination, courseId == course.courseId {
                if let plan = items.first(where: { $0.planId == planId }) {
                    PageHeader(title: plan.name ?? "Untitled plan")
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("search.plan.\(planId)")
                    PlanContents(plan: plan, courseId: courseId, note: model.lectureNote(for: plan, course: course))
                } else {
                    EmptyState(state: state, empty: "This plan is unavailable")
                }
            } else {
                if items.isEmpty { EmptyState(state: state, empty: "No plans") }
                if let groups {
                    topicGroups(groups, current: sections.next)
                } else {
                    if let next = sections.next {
                        CurrentPlan(
                            plan: next, courseId: course.courseId, note: model.lectureNote(for: next, course: course)
                        )
                        .padding(.bottom, Space.s8)
                    }
                    flatSections(sections)
                }
            }
        }
        .dividedRows()
        .task {
            async let plans: Void = model.loadPlans(courseId: course.courseId)
            async let topics: Void = model.loadTopics(courseId: course.courseId)
            _ = await (plans, topics)
        }
    }

    /// Each topic as a group that opens in place, in the course's topic order, then plans without one.
    /// The topic holding the current plan is open, with that plan first.
    @ViewBuilder private func topicGroups(_ groups: [PlanTopicGroup], current: PlanPreview?) -> some View {
        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
            let holdsCurrent = current.map { next in group.plans.contains { $0.planId == next.planId } } ?? false
            let isExpanded = Binding(
                get: { topicExpansion[group.id] ?? holdsCurrent },
                set: { topicExpansion[group.id] = $0 }
            )
            Disclosure(
                title: group.name ?? "Other plans", count: group.plans.count,
                isExpanded: isExpanded, isTopic: true
            )
            .padding(.horizontal, -Space.s8)
            .padding(.top, index == 0 ? 0 : Space.s8)
            if isExpanded.wrappedValue {
                // Everything starts under the topic's label, 20pt in from its chevron, so the nesting reads.
                let lead = holdsCurrent ? current : nil
                let rest = group.plans.filter { $0.planId != lead?.planId }
                if let lead {
                    CurrentPlan(
                        plan: lead, courseId: course.courseId, note: model.lectureNote(for: lead, course: course)
                    )
                    .padding(.leading, Self.topicIndent)
                    .padding(.bottom, rest.isEmpty ? 0 : Space.s8)
                }
                ForEach(rest) { plan in
                    PlanRow(
                        plan: plan, courseId: course.courseId, note: model.lectureNote(for: plan, course: course),
                        isLast: plan.id == rest.last?.id
                    )
                    .padding(.leading, Self.topicIndent - Space.s8)
                    .padding(.trailing, -Space.s8)
                }
            }
        }
    }

    /// A course without topics: later plans, plans without dates, and earlier ones collapsed.
    @ViewBuilder private func flatSections(_ sections: PlanSections) -> some View {
        // Row text starts at the page's inset, like the title: the rows reach 8pt into the gutter.
        if !sections.upcoming.isEmpty {
            PlanSectionHeader(title: "Later", count: sections.upcoming.count, first: sections.next == nil)
            ForEach(sections.upcoming) { plan in
                PlanRow(
                    plan: plan, courseId: course.courseId, note: model.lectureNote(for: plan, course: course),
                    isLast: plan.id == sections.upcoming.last?.id
                )
                .padding(.horizontal, -Space.s8)
            }
        }
        if !sections.undated.isEmpty {
            PlanSectionHeader(title: "Without dates", count: sections.undated.count, first: sections.next == nil && sections.upcoming.isEmpty)
            ForEach(sections.undated) { plan in
                PlanRow(plan: plan, courseId: course.courseId, note: nil, isLast: plan.id == sections.undated.last?.id)
                    .padding(.horizontal, -Space.s8)
            }
        }
        if !sections.previous.isEmpty {
            Disclosure(title: "Previous lectures", count: sections.previous.count, isExpanded: $showsPrevious)
                .padding(.horizontal, -Space.s8)
                .padding(.top, Space.s16)
            if showsPrevious {
                ForEach(sections.previous) { plan in
                    PlanRow(
                        plan: plan, courseId: course.courseId, note: model.lectureNote(for: plan, course: course),
                        isLast: plan.id == sections.previous.last?.id
                    )
                    .padding(.horizontal, -Space.s8)
                }
            }
        }
    }
}

extension PlanPreview {
    /// The plan's dates in the one week-range format Plans and Calendar share; "From" or "Until"
    /// when only one end is known, "No dates" when neither is.
    fileprivate var rangeText: String {
        if let start = StudyDates.usable(start), let stop = StudyDates.usable(stop) {
            return StudyDates.weekRange(start, stop)
        }
        return StudyDates.planRange(start: start, stop: stop)
    }
}

/// A section heading inside a course page: the shared `SectionHeader`, without its space above
/// when it is the first thing on the page.
private struct PlanSectionHeader: View {
    let title: String
    let count: Int
    let first: Bool

    var body: some View {
        SectionHeader(title: title, count: count)
            .padding(.top, first ? -(Space.s16 + Space.s4) : 0)
    }
}

/// A row that shows or hides a group, with a count.
struct Disclosure: View {
    let title: String
    var count: Int? = nil
    @Binding var isExpanded: Bool
    /// A topic heading over plans: a 15pt group header, its chevron 14pt wide so the
    /// plans below can start 20pt in, under its label.
    var isTopic = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RowButton(action: { withMotion(Motion.base, reduceMotion: reduceMotion) { isExpanded.toggle() } }) {
            // Expands in place: a leading triangle that turns, the count after the title.
            HStack(spacing: Space.s6) {
                Image(systemName: Symbol.disclosure)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.textMuted)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: isTopic ? 14 : Size.iconSmall)
                    .accessibilityHidden(true)
                Text(title)
                    .font(isTopic ? Type.group : Type.t12)
                    .foregroundStyle(Color.text)
                if let count {
                    Text(count.formatted()).font(isTopic ? Type.groupCount : Type.t11).monospacedDigit().foregroundStyle(Color.textMuted)
                }
                Spacer(minLength: 0)
            }
        }
        .undividedRows()
        .accessibilityLabel(isExpanded ? "Hide \(title.lowercased())" : "Show \(title.lowercased())")
    }
}

/// The current plan, leading its topic with no card behind it: its title (13pt semibold, under the 15pt topic header) with
/// its week trailing on the same line, its files 16pt in below it, then its brief.
private struct CurrentPlan: View {
    let plan: PlanPreview
    let courseId: Int
    let note: LectureNote?

    /// True while today falls inside the plan's dates.
    private var isCurrent: Bool {
        guard let start = plan.start else { return false }
        let now = Date()
        return start <= now && (plan.stop.map { now <= $0 } ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s8) {
                Text(plan.name ?? "Untitled plan")
                    .font(Type.t13.weight(.semibold))
                    .foregroundStyle(Color.text)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Space.s8)
                Text(isCurrent ? "This week" : plan.rangeText)
                    .font(Type.t12)
                    .foregroundStyle(Color.textMuted)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            if let text = plan.planDescription, !text.isEmpty {
                RichTextView(html: text)
                    .readingWidth()
            }
            if let elements = plan.elements, !elements.isEmpty {
                // Rows carry their own 8pt, so 8 more puts the files' icons 16pt in from the title.
                VStack(alignment: .leading, spacing: Space.s2) {
                    ForEach(elements) { element in
                        PlanElementRow(element: element, courseId: courseId)
                            .accessibilityIdentifier("plan.resource.\(element.id)")
                    }
                }
                .undividedRows()
                .padding(.leading, Space.s8)
                .padding(.trailing, -Space.s8)
            }
            if let note, note.brief != nil || note.status == .noTeaching {
                BriefBlock(note: note)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// Any other plan: a divided row that opens its description and files in place. The week range
/// and the chevron sit together at the trailing edge, never right after the title.
private struct PlanRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let plan: PlanPreview
    let courseId: Int
    let note: LectureNote?
    /// The last row of its group draws no hairline.
    var isLast = false
    @State private var isExpanded = false

    var body: some View {
        let range = plan.rangeText
        return VStack(alignment: .leading, spacing: 0) {
            RowButton(action: { withMotion(Motion.base, reduceMotion: reduceMotion) { isExpanded.toggle() } }) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s8) {
                    Text(plan.name ?? "Untitled plan")
                        .font(Type.t13)
                        .foregroundStyle(Color.text)
                        .lineLimit(2)
                    Spacer(minLength: Space.s8)
                    indicators
                    RowTrailing(date: range)
                }
            }
            .environment(\.rowDividerHidden, isExpanded || isLast)
            .accessibilityIdentifier("plan.row.\(plan.planId)")
            .accessibilityAddTraits(isExpanded ? .isSelected : [])
            if isExpanded {
                PlanContents(plan: plan, courseId: courseId, note: note)
                    .padding(.leading, Space.s16)
                if !isLast { RowDivider() }
            }
        }
    }

    /// A brief and the file count, quiet marks before the date.
    @ViewBuilder private var indicators: some View {
        HStack(spacing: Space.s12) {
            if note?.brief != nil {
                Image(systemName: Symbol.brief)
                    .font(.system(size: 11, weight: .regular))
                    .help("Brief")
                    .accessibilityLabel("Brief")
            }
            if let count = plan.elements?.count, count > 0 {
                HStack(spacing: Space.s4) {
                    Image(systemName: Symbol.material)
                        .font(.system(size: 11, weight: .regular))
                    Text(count.formatted()).monospacedDigit()
                }
                .help(count == 1 ? "1 file" : "\(count) files")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(count == 1 ? "1 file" : "\(count) files")
            }
        }
        .font(Type.t11)
        .foregroundStyle(Color.textMuted)
    }
}

private struct PlanContents: View {
    let plan: PlanPreview
    let courseId: Int
    let note: LectureNote?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            if let text = plan.planDescription, !text.isEmpty {
                RichTextView(html: text)
                    .readingWidth()
                    .padding(.horizontal, Space.s8)
                    .padding(.bottom, Space.s4)
            }
            ForEach(plan.elements ?? []) { element in
                PlanElementRow(element: element, courseId: courseId)
                    .accessibilityIdentifier("plan.resource.\(element.id)")
            }
            if let note, note.brief != nil || note.status == .noTeaching {
                BriefBlock(note: note)
                    .padding(.horizontal, Space.s8)
                    .padding(.top, Space.s8)
            }
        }
        .undividedRows()
        .padding(.bottom, Space.s8)
    }
}

/// A file in a plan opens in the right panel. Folders and links open on the website.
private struct PlanElementRow: View {
    @Environment(AppModel.self) private var model
    let element: PlanPreview.Element
    let courseId: Int
    @State private var isOpening = false

    private var opensInApp: Bool { element.isFolder != true && element.isResource != false }
    private var resource: Resource { Resource(planElement: element, courseId: courseId) }

    /// The symbol Files gives the same kind of item: folder, link, or the one glyph for the file's type.
    private var symbol: String {
        if element.isFolder == true { return Symbol.folder }
        if element.isResource == false { return Symbol.link }
        return Symbol.file(extension: ((element.title ?? "") as NSString).pathExtension)
    }

    var body: some View {
        RowButton(action: open) {
            HStack(spacing: Space.s6) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: Size.icon, height: Size.icon)
                    .foregroundStyle(Color.textMuted)
                    .accessibilityHidden(true)
                Text(element.title ?? "Untitled")
                    .font(Type.t13)
                    .foregroundStyle(Color.text)
                    .lineLimit(1)
                if element.isHomework == true {
                    Text("Homework")
                        .font(Type.t11)
                        .foregroundStyle(Color.textMuted)
                }
                Spacer(minLength: Space.s8)
                if isOpening || model.downloadStates[resource.id] == .downloading {
                    Spinner()
                } else if case .failed(let message)? = model.downloadStates[resource.id] {
                    ErrorLine(message)
                } else if isWebsiteOnly {
                    EmptyView()
                } else if model.savedAssets[resource.id] != nil {
                    Image(systemName: Symbol.saved)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color.textMuted)
                        .help("Saved on this Mac")
                        .accessibilityLabel("Saved")
                }
                // A file opens in the panel with no mark; the website gets its arrow, as in Files.
                if isWebsiteOnly {
                    WebsiteMark()
                }
            }
        }
        .accessibilityElement(children: .combine)
        .contextMenu {
            if let url = model.absoluteURL(element.url) {
                Button("Open on the website") { NSWorkspace.shared.open(url) }
            }
        }
    }

    private var isWebsiteOnly: Bool { !opensInApp || model.downloadStates[resource.id] == .websiteOnly }

    private func open() {
        if isWebsiteOnly, let url = model.absoluteURL(element.url) {
            NSWorkspace.shared.open(url)
        } else if opensInApp {
            isOpening = true
            Task {
                await model.open(element, courseId: courseId)
                isOpening = false
            }
        }
    }
}

struct UpcomingView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigation.self) private var navigation
    @State private var onlyActive = true
    @State private var memo = Memo<UpcomingKey, UpcomingSections>()

    /// In `Navigation`, so the open assignment is a history entry.
    private var openAssignment: StudyTask? {
        get { navigation.openTask }
        nonmutating set { navigation.openTask = newValue }
    }

    var body: some View {
        Group {
            if let task = openAssignment, let elementId = task.elementId {
                if task.opensAssignment {
                    AssignmentView(elementId: elementId, title: task.title) { openAssignment = nil }
                } else {
                    PageReaderView(resource: task.pageResource(elementId: elementId)) { openAssignment = nil }
                }
            } else if case .task(let id) = navigation.searchTarget?.destination {
                PageScroll {
                    if let task = model.tasks.first(where: { $0.taskId == id }) {
                        TaskRow(task: task) { openAssignment = task }
                    } else {
                        EmptyState(state: model.tasksState, empty: "This task is unavailable")
                    }
                }
            } else {
                list
            }
        }
        // Only for a result just opened from search, never one Back returns to, which keeps its own state.
        .task(id: navigation.searchArrival) {
            guard navigation.searchArrival != nil, case .task(let id) = navigation.searchTarget?.destination else { return }
            // The previously opened assignment must not obscure a new search target.
            navigation.settle { openAssignment = nil }
            await model.loadTasks()
            guard !Task.isCancelled, let task = model.tasks.first(where: { $0.taskId == id }), task.elementId != nil,
                  task.opensAssignment ? ParityGate.assignments : ParityGate.pages else { return }
            // Part of opening the result, not a move of its own.
            navigation.settle { openAssignment = task }
        }
    }

    /// `SectionHeader` carries 20pt above its title. The first group sits 20pt under the page
    /// header (whose own 16pt bottom space plus 4); later groups sit 24pt under the last row's
    /// text, which already has about 12pt of row padding below it.
    private static func groupTopAdjustment(isFirst: Bool) -> CGFloat {
        isFirst ? -Space.s16 : -Space.s8
    }

    private var list: some View {
        let state = model.tasksState
        let activeIds = onlyActive ? Set(model.activeCourses.map(\.courseId)) : []
        let tasks = model.tasks
        let now = currentMinute()
        let sections = memo.value(for: UpcomingKey(tasks: tasks, activeIds: activeIds, minute: now)) {
            UpcomingList.sections(tasks, activeCourseIds: activeIds, now: now, calendar: .current)
        }
        let groups: [(String, [StudyTask])] = [
            ("Overdue", sections.overdue), ("Today", sections.today),
            ("Next 7 days", sections.thisWeek), ("Later", sections.later),
        ]
        let firstGroup = groups.first { !$0.1.isEmpty }?.0 ?? (sections.noDeadline.isEmpty ? nil : "No deadline")
        // The header scrolls with the list, inside the one page inset, so nothing is reserved
        // between the title and the first heading: the first heading drops its space above.
        return PageScroll(spacing: 0, lazy: true) {
            PageHeader(title: "Assignments") {
                if model.archivedCourses.isEmpty == false {
                    HStack(spacing: Space.s4) {
                        Chip("Active courses", isSelected: onlyActive) { onlyActive = true }
                        Chip("All courses", isSelected: !onlyActive) { onlyActive = false }
                    }
                }
            }
            FreshnessLine(state: state)
            if groups.allSatisfy({ $0.1.isEmpty }), sections.noDeadline.isEmpty {
                EmptyState(state: state, empty: "No upcoming tasks")
            }
            ForEach(groups.filter { !$0.1.isEmpty }, id: \.0) { title, tasks in
                ListGroup(title: title, count: tasks.count) {
                    ForEach(tasks) { task in
                        TaskRow(
                            task: task,
                            isOverdue: StudyDates.usable(task.deadline).map { $0 < now } ?? false
                        ) { openAssignment = task }
                    }
                }
                .padding(.top, Self.groupTopAdjustment(isFirst: title == firstGroup))
            }
            if !sections.noDeadline.isEmpty {
                // A plain heading like the others; its rows are always shown.
                ListGroup(title: "No deadline", count: sections.noDeadline.count) {
                    ForEach(sections.noDeadline) { task in
                        TaskRow(task: task) { openAssignment = task }
                    }
                }
                .padding(.top, Self.groupTopAdjustment(isFirst: firstGroup == "No deadline"))
            }
        }
        .dividedRows()
        .navigationTitle("Assignments")
        .task { await model.loadTasks() }
    }
}

/// An assignment: title and course on the left, the status and deadline on one line on the right.
/// The Assignments screen and Home's Due section share it.
struct TaskRow: View {
    @Environment(AppModel.self) private var model
    let task: StudyTask
    /// Draws the date in `Color.danger`. There is no "Overdue" word or badge.
    var isOverdue = false
    let onOpen: () -> Void
    @State private var action = WriteAction()

    private var isAssignment: Bool { task.opensAssignment }

    /// Assignments open their details, other tasks with an element open as a page,
    /// and the website is the last resort.
    private enum Primary { case open, website(URL), none }

    private var primary: Primary {
        if task.elementId != nil, ParityGate.assignments || ParityGate.pages {
            if task.opensAssignment ? ParityGate.assignments : ParityGate.pages { return .open }
        }
        if let url = model.absoluteURL(task.url) { return .website(url) }
        return .none
    }

    private var canComplete: Bool { ParityGate.writes && task.elementId != nil }

    private var opens: (() -> Void)? {
        switch primary {
        case .open: return onOpen
        case .website(let url): return { NSWorkspace.shared.open(url) }
        case .none: return nil
        }
    }

    var body: some View {
        // A title may take two lines, so a long one never truncates beside its deadline.
        let course = model.courses.first(where: { $0.courseId == task.courseId })?.shortTitle ?? task.courseTitle
        ListRow(
            title: task.title,
            subtitle: StudyDates.taskSubtitle(course: course, status: task.status),
            subtitleDot: task.courseId.map { Color.course($0) },
            action: opens,
            meta: { meta }
        )
        .contextMenu { menu }
    }

    /// The date on one line, red when overdue. The submission state is on the subtitle line.
    /// No chevron: rows that open an item show it by hover; rows that leave for the website end in the arrow.
    @ViewBuilder private var meta: some View {
        let deadline = StudyDates.usable(task.deadline)
        let date = deadline.map { StudyDates.relative($0) }
        let leavesApp: Bool = { if case .website = primary { return true } else { return false } }()
        if date != nil || leavesApp {
            HStack(spacing: Space.s8) {
                RowTrailing(date: date, isOverdue: isOverdue)
                if leavesApp { WebsiteMark() }
            }
            .help(StudyDates.deadline(task.deadline))
        }
        if action.isRunning { Spinner() }
        if case .failed(let message) = action.phase { ErrorLine(message) }
    }

    @ViewBuilder private var menu: some View {
        if case .open = primary {
            Button("Open", action: onOpen)
        }
        if canComplete {
            Button("Mark complete") { Task { await markComplete() } }
        }
        if let url = model.absoluteURL(task.url) {
            Button("Open on the website") { NSWorkspace.shared.open(url) }
        }
    }

    private func markComplete() async {
        guard let elementId = task.elementId, case .ready(let person) = model.authState else { return }
        let assignment = isAssignment
        if await action.run({
            try await model.write {
                try await $0.setTaskStatus(elementId: elementId, personId: person.personId, status: .completed, isAssignment: assignment)
            }
        }) {
            await model.refreshTasks()
        }
    }
}

/// What the task groups depend on.
struct UpcomingKey: Equatable {
    var tasks: [StudyTask]
    var activeIds: Set<Int>
    var minute: Date
}

extension StudyTask {
    /// Assignment details read for LearningToolElement tasks and refuse CustomActivity ones with 403,
    /// so CustomActivity tasks such as reading lists open as a page and use the generic task route.
    var opensAssignment: Bool {
        guard let type = elementType else { return false }
        return ["Assignment", "LearningToolElement"].contains { type.caseInsensitiveCompare($0) == .orderedSame }
    }

    func pageResource(elementId: Int) -> Resource {
        Resource(elementId: elementId, elementType: elementType ?? "CustomActivity", title: title, courseId: courseId, url: url)
    }
}

extension FocusedValues {
    @Entry var courseTab: Binding<CourseTab>?
}
