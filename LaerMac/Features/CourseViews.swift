import LaerCore
import SwiftUI

enum CourseTab: Hashable, CaseIterable {
    case plans, updates, materials, calendar, participants, grades

    var title: String {
        switch self {
        case .updates: "Updates"
        case .materials: "Materials"
        case .plans: "Plans"
        case .calendar: "Calendar"
        case .grades: "Grades"
        case .participants: "Participants"
        }
    }

    var symbol: String {
        switch self {
        case .updates: Symbol.update
        case .materials: Symbol.folder
        case .plans: Symbol.plan
        case .calendar: Symbol.lecture
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
            VStack(alignment: .leading, spacing: Space.s16) {
                PageHeader(title: course.shortTitle) {
                    if let url = model.absoluteURL(course.url) {
                        IconButton(Symbol.open, label: "Open on the website") { NSWorkspace.shared.open(url) }
                    }
                }
                .padding(.horizontal, Space.s12)
                SectionTabs(
                    selection: navigation.tabBinding(for: course.courseId),
                    items: CourseTab.available(grades: grades.isAvailable(courseId: course.courseId, model: model)).map { ($0, $0.title, $0.symbol) })
            }
            // The tabs' own fill marks them, so no line runs under them. The page's gutter is
            // trimmed by the rows' inner padding, so tab text and row text line up.
            .padding(.horizontal, Space.s24 - Space.s12)
            .padding(.top, Space.s24)
            .padding(.bottom, Space.s4)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle(course.shortTitle)
        .focusedSceneValue(\.courseTab, navigation.tabBinding(for: course.courseId))
        .task { await grades.probe(courseId: course.courseId, using: model) }
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
        DisclosureRow(isExpanded: $isExpanded) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s8) {
                Text(update.publishedBy?.fullName ?? "Unknown author")
                    .font(Type.t13.weight(.semibold))
                    .foregroundStyle(Color.text)
                    .lineLimit(1)
                    .layoutPriority(1)
                if !isExpanded {
                    Text(RichTextCache.plainText(html))
                        .font(Type.t13)
                        .foregroundStyle(Color.textMuted)
                        .lineLimit(1)
                }
            }
        } trailing: {
            if let date = update.published {
                Text(date.formatted(.relative(presentation: .named)))
                    .font(Type.t11)
                    .foregroundStyle(Color.textMuted)
                    .monospacedDigit()
                    .help(date.formatted(date: .abbreviated, time: .shortened))
            }
        } children: {
            RichTextView(html: html)
                .padding(.horizontal, Space.s8)
        }
        .contextMenu {
            if let url = model.absoluteURL(update.url) {
                Button("Open on the website") { NSWorkspace.shared.open(url) }
            }
        }
    }
}

/// A course's plans: the next lecture as a card on top, later ones below, earlier ones collapsed.
struct PlansView: View {
    @Environment(AppModel.self) private var model
    let course: Course
    @State private var showsPrevious = false
    @State private var memo = Memo<[PlanPreview], PlanSections>()

    var body: some View {
        let items = model.plans[course.courseId] ?? []
        let state = model.plansState[course.courseId] ?? CollectionState()
        let sections = memo.value(for: items) { PlanOrder.sections(items, now: Date()) }
        PageScroll(spacing: 0, lazy: true) {
            FreshnessLine(state: state)
            if items.isEmpty {
                EmptyState(state: state, empty: "No plans")
            }
            if let next = sections.next {
                NextLectureCard(plan: next, courseId: course.courseId, note: model.lectureNote(for: next, course: course))
                    .padding(.bottom, Space.s16)
            }
            if !sections.upcoming.isEmpty {
                SectionLabel("Later", first: sections.next == nil)
                ForEach(sections.upcoming) { plan in PlanRow(plan: plan, courseId: course.courseId, note: model.lectureNote(for: plan, course: course)) }
            }
            if !sections.undated.isEmpty {
                SectionLabel("Without dates", first: sections.next == nil && sections.upcoming.isEmpty)
                ForEach(sections.undated) { plan in PlanRow(plan: plan, courseId: course.courseId, note: nil) }
            }
            if !sections.previous.isEmpty {
                Disclosure(title: "Previous lectures", count: sections.previous.count, isExpanded: $showsPrevious)
                    .padding(.top, Space.s16)
                if showsPrevious {
                    ForEach(sections.previous) { plan in PlanRow(plan: plan, courseId: course.courseId, note: model.lectureNote(for: plan, course: course)) }
                }
            }
        }
        .dividedRows()
        .task {
            await model.loadPlans(courseId: course.courseId)
        }
    }
}

/// A muted label over a group inside a page. Never repeats the page's title.
struct SectionLabel: View {
    private let title: String
    private let first: Bool
    /// `first` drops the space above, for the label at the top of a page.
    init(_ title: String, first: Bool = false) {
        self.title = title
        self.first = first
    }

    var body: some View {
        Text(title)
            .font(Type.t12)
            .foregroundStyle(Color.textMuted)
            .padding(.horizontal, Space.s8)
            .padding(.top, first ? 0 : Space.s24)
            .padding(.bottom, Space.s4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A row that shows or hides a group, with a count.
struct Disclosure: View {
    let title: String
    let count: Int
    @Binding var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RowButton(action: { withMotion(Motion.base, reduceMotion: reduceMotion) { isExpanded.toggle() } }) {
            HStack(spacing: Space.s6) {
                DisclosureTitle(title: title, font: Type.t12, isExpanded: isExpanded)
                Text(count.formatted()).font(Type.t11).monospacedDigit().foregroundStyle(Color.textMuted)
                Spacer(minLength: 0)
            }
        }
        .undividedRows()
        .accessibilityLabel(isExpanded ? "Hide \(title.lowercased())" : "Show \(title.lowercased())")
    }
}

/// The next lecture as a large card: when, what, its brief, and its files one click away.
private struct NextLectureCard: View {
    let plan: PlanPreview
    let courseId: Int
    let note: LectureNote?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            VStack(alignment: .leading, spacing: Space.s4) {
                HStack(spacing: Space.s6) {
                    Image(systemName: Symbol.lecture)
                        .font(.system(size: 12, weight: .regular))
                        .accessibilityHidden(true)
                    Text("Next lecture")
                    Text(StudyDates.planRange(start: plan.start, stop: plan.stop))
                }
                .font(Type.t12)
                .foregroundStyle(Color.textMuted)
                Text(plan.name ?? "Untitled plan")
                    .font(Type.t18)
                    .foregroundStyle(Color.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            if let text = plan.planDescription, !text.isEmpty {
                RichTextView(html: text)
            }
            if let note, note.brief != nil || note.status == .noTeaching {
                BriefBlock(note: note)
            }
            if let elements = plan.elements, !elements.isEmpty {
                VStack(alignment: .leading, spacing: Space.s2) {
                    ForEach(elements) { element in
                        PlanElementRow(element: element, courseId: courseId)
                    }
                }
                .undividedRows()
                .environment(\.rowSurface, .raised)
                .padding(.horizontal, -Space.s8)
            }
        }
        .padding(Space.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).fill(Color.raised))
        .accessibilityElement(children: .contain)
    }
}

/// Any other plan: a divided row whose chevron opens its description and files.
private struct PlanRow: View {
    let plan: PlanPreview
    let courseId: Int
    let note: LectureNote?
    @State private var isExpanded = false

    var body: some View {
        DisclosureRow(isExpanded: $isExpanded) {
            Text(plan.name ?? "Untitled plan")
                .font(Type.t13)
                .foregroundStyle(Color.text)
                .lineLimit(2)
        } trailing: {
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
                Text(StudyDates.planRange(start: plan.start, stop: plan.stop))
            }
            .font(Type.t11)
            .foregroundStyle(Color.textMuted)
        } children: {
            if let text = plan.planDescription, !text.isEmpty {
                RichTextView(html: text)
                    .padding(.horizontal, Space.s8)
                    .padding(.bottom, Space.s4)
            }
            if let note, note.brief != nil || note.status == .noTeaching {
                BriefBlock(note: note)
                    .padding(.horizontal, Space.s8)
                    .padding(.bottom, Space.s4)
            }
            ForEach(plan.elements ?? []) { element in
                PlanElementRow(element: element, courseId: courseId)
            }
        }
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

    var body: some View {
        RowButton(action: open) {
            HStack(spacing: Space.s6) {
                Image(systemName: element.isFolder == true ? Symbol.folder : Symbol.material)
                    .font(.system(size: 12, weight: .regular))
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
                } else if model.savedAssets[resource.id] != nil {
                    Image(systemName: Symbol.saved)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color.textMuted)
                        .help("Saved on this Mac")
                        .accessibilityLabel("Saved")
                } else if opensInApp {
                    Image(systemName: Symbol.save)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color.textMuted)
                        .help("Opens here after saving")
                        .accessibilityHidden(true)
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

    private func open() {
        if opensInApp {
            isOpening = true
            Task {
                await model.open(element, courseId: courseId)
                isOpening = false
            }
        } else if let url = model.absoluteURL(element.url) {
            NSWorkspace.shared.open(url)
        }
    }
}

struct UpcomingView: View {
    @Environment(AppModel.self) private var model
    @State private var openAssignment: StudyTask?
    @State private var onlyActive = true
    @State private var showsUndated = false
    @State private var memo = Memo<UpcomingKey, UpcomingSections>()

    var body: some View {
        if let task = openAssignment, let elementId = task.elementId {
            if task.opensAssignment {
                AssignmentView(elementId: elementId, title: task.title) { openAssignment = nil }
            } else {
                PageReaderView(resource: task.pageResource(elementId: elementId)) { openAssignment = nil }
            }
        } else {
            list
        }
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
        return VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Upcoming") {
                if model.archivedCourses.isEmpty == false {
                    HStack(spacing: Space.s4) {
                        Chip("Active courses", isSelected: onlyActive) { onlyActive = true }
                        Chip("All courses", isSelected: !onlyActive) { onlyActive = false }
                    }
                }
            }
            .padding(.horizontal, Space.s24)
            .padding(.top, Space.s16)
            PageScroll(spacing: 0, lazy: true) {
                FreshnessLine(state: state)
                if groups.allSatisfy({ $0.1.isEmpty }), sections.noDeadline.isEmpty {
                    EmptyState(state: state, empty: "No upcoming tasks")
                }
                ForEach(Array(groups.filter { !$0.1.isEmpty }.enumerated()), id: \.element.0) { index, group in
                    let (title, tasks) = group
                    SectionLabel(title, first: index == 0)
                    ForEach(tasks) { task in
                        TaskRow(task: task, isOverdue: title == "Overdue") { openAssignment = task }
                    }
                }
                if !sections.noDeadline.isEmpty {
                    Disclosure(title: "No deadline", count: sections.noDeadline.count, isExpanded: $showsUndated)
                        .padding(.top, Space.s16)
                    if showsUndated {
                        ForEach(sections.noDeadline) { task in
                            TaskRow(task: task) { openAssignment = task }
                        }
                    }
                }
            }
        }
        .dividedRows()
        .navigationTitle("Upcoming")
        .task { await model.loadTasks() }
    }
}

private struct TaskRow: View {
    @Environment(AppModel.self) private var model
    let task: StudyTask
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

    var body: some View {
        switch primary {
        case .open: RowButton(action: onOpen) { content }.contextMenu { menu }
        case .website(let url): RowButton(action: { NSWorkspace.shared.open(url) }) { content }.contextMenu { menu }
        case .none: content.plainRow().contextMenu { menu }
        }
    }

    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s12) {
            VStack(alignment: .leading, spacing: Space.s2) {
                Text(task.title)
                    .font(Type.t13)
                    .foregroundStyle(Color.text)
                    .lineLimit(2)
                if let title = model.courses.first(where: { $0.courseId == task.courseId })?.shortTitle ?? task.courseTitle {
                    Text(title)
                        .font(Type.t11)
                        .foregroundStyle(Color.textMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Space.s8)
            VStack(alignment: .trailing, spacing: Space.s2) {
                if StudyDates.usable(task.deadline) != nil {
                    Text(StudyDates.shortDeadline(task.deadline))
                        .font(Type.t12)
                        .foregroundStyle(isOverdue ? Color.danger : Color.text)
                        .monospacedDigit()
                        .help(StudyDates.deadline(task.deadline))
                }
                if let status = StudyDates.statusText(task.status) {
                    Text(status)
                        .font(Type.t11)
                        .foregroundStyle(Color.textMuted)
                }
                if action.isRunning { Spinner() }
                if case .failed(let message) = action.phase { ErrorLine(message) }
            }
        }
        .accessibilityElement(children: .combine)
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
