import AppKit
import LaerCore
import Observation
import Quartz
import SwiftUI
import WebKit

/// The palette as it was when a result opened, so Back shows the same query, filters, results and row.
struct SearchReturnState {
    var text: String
    var scope: CommandPalette.ScopeChoice
    var kind: SearchKind?
    var fileType: String?
    var selectedID: String?
    var visibleCount: Int
    var localHits: [SearchHit]
    var onlineHits: [SearchHit]
    var onlineSummary: OnlineSearchSummary?
    var expandedDocuments: Set<String>
}

/// Where someone is inside a course's Materials: the folders they opened and the page they read.
struct FolderPlace: Equatable {
    var path: [Resource] = []
    var reading: Resource?
}

/// What Back and Forward compare and put back. Changing any of it, other than a file's bytes
/// arriving, is a move worth remembering.
struct Place: Equatable {
    var selection: AppModel.Selection?
    var courseTabs: [Int: CourseTab]
    var folders: [Int: FolderPlace]
    var openTask: StudyTask?
    var thread: Int?
    var searchTarget: SearchHit?
    var file: ViewerItem?

    /// The screen without what was opened inside it.
    var screen: AppModel.Selection? { selection ?? .home }

    var tab: CourseTab? {
        if case .course(let id) = selection { return courseTabs[id] ?? .plans }
        return nil
    }

    static func == (a: Place, b: Place) -> Bool {
        a.selection == b.selection && a.courseTabs == b.courseTabs && a.folders == b.folders
            && a.openTask == b.openTask && a.thread == b.thread && a.searchTarget?.id == b.searchTarget?.id
            // A file is the same place while its bytes arrive; only another file or page is a move.
            && a.file?.id == b.file?.id && a.file?.startPage == b.file?.startPage
    }
}

/// One step of history: the place, plus what is put back with it but never counts as a move.
struct HistoryEntry {
    var place: Place
    var expandedCourses: Set<Int>
    /// Set when a search result was opened from here; going back reopens the palette as it was.
    var search: SearchReturnState?
}

enum HistoryMove {
    case back, forward
}

/// Live progress of a two-finger trackpad history swipe, for the edge chevron indicator.
struct SwipeFeedback: Equatable {
    var direction: HistoryMove
    /// 0 at rest, 1 at full commit.
    var progress: CGFloat
}

/// Window-level view state that several screens share: the open course tab per course, what is
/// open inside a screen, which sidebar rows are expanded, the command palette, and Back and Forward.
///
/// History is recorded by watching `place`: every change the person makes is one entry, so screens
/// keep setting their state directly. Changes that follow on their own (a file's bytes arriving, a
/// search result settling in) fold into the entry they belong to, and refreshes never change a
/// place, so they never add one.
@MainActor
@Observable
final class Navigation {
    var courseTabs: [Int: CourseTab] = [:]
    var expandedCourses: Set<Int> = []
    var folders: [Int: FolderPlace] = [:]
    /// The assignment or page open on Assignments.
    var openTask: StudyTask?
    var selectedThread: Int?
    /// Unsent reply text per conversation, so checking another thread never loses what was typed.
    /// Kept for the window, not in history, and cleared with the account.
    var replyDrafts: [Int: String] = [:]
    var isArchiveOpen = false
    var isPaletteOpen = false
    /// A kind the palette starts filtered to, such as materials from the New tab's Resources. Read once.
    var paletteKind: SearchKind?
    var searchTarget: SearchHit?
    /// New each time a search result opens. Screens that finish opening a result themselves, such
    /// as Assignments, wait for it; history never restores it, so Back never reopens anything.
    private(set) var searchArrival: UUID?
    /// The palette state to show when the palette opens from history. Nil for a fresh search.
    var paletteRestore: SearchReturnState?
    /// New for each palette history shows, so one already open is rebuilt with the entry's state.
    private(set) var paletteID = UUID()
    /// A compose view on screen holds unsent text or files.
    var hasDraft = false
    /// A move waiting for the person to confirm leaving their draft.
    var pendingMove: HistoryMove?
    /// Active two-finger trackpad swipe progress, nil at rest.
    var swipeFeedback: SwipeFeedback?

    private(set) var history = NavigationHistory<HistoryEntry>(limit: 50)
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var current: HistoryEntry?
    @ObservationIgnored private var account: ObjectIdentifier?
    @ObservationIgnored private var settlesUntil = Date.distantPast
    /// A search result's file may take a while to arrive; the first file to open by then is the result's.
    @ObservationIgnored private var resultFileUntil = Date.distantPast

    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }

    func tab(for courseId: Int) -> CourseTab { courseTabs[courseId] ?? .plans }

    /// Drops search results that came from recognized text once that text is removed, so going back to search
    /// can't reopen them.
    func forgetRecognizedText() {
        searchReturn?.localHits.removeAll { $0.document?.recognizedText == true }
        if searchTarget?.document?.recognizedText == true { searchTarget = nil }
    }

    func tabBinding(for courseId: Int) -> Binding<CourseTab> {
        Binding(get: { self.tab(for: courseId) }, set: { self.courseTabs[courseId] = $0 })
    }

    func folder(for courseId: Int) -> FolderPlace { folders[courseId] ?? FolderPlace() }

    func place(_ model: AppModel) -> Place {
        Place(
            selection: model.selection, courseTabs: courseTabs, folders: folders.filter { $0.value != FolderPlace() },
            openTask: openTask, thread: selectedThread, searchTarget: searchTarget, file: model.viewerItem
        )
    }

    /// Kept for the palette, which clears it when the results it saved stop existing: forgets every saved search.
    var searchReturn: SearchReturnState? {
        get { current?.search }
        set {
            guard newValue == nil else { return }
            current?.search = nil
            history.update { $0.search = nil }
        }
    }

    // MARK: Recording

    /// Starts history for the window, and again whenever the account changes: nothing from
    /// another account is kept, open or reachable with Back.
    func start(_ model: AppModel) {
        self.model = model
        folders = [:]
        openTask = nil
        selectedThread = nil
        replyDrafts = [:]
        searchTarget = nil
        searchArrival = nil
        isPaletteOpen = false
        reset()
    }

    /// Called whenever `place` changes.
    func record() {
        guard let model else { return }
        let place = place(model)
        guard var leaving = current, account == model.snapshots.map(ObjectIdentifier.init) else {
            start(model)
            return
        }
        guard place != leaving.place, Date() >= settlesUntil, !isResultFile(place, after: leaving.place) else {
            current?.place = place
            return
        }
        leaving.expandedCourses = expandedCourses
        leaving.place.file = withShownPage(leaving.place.file)
        history.push(leaving)
        if place.screen != leaving.place.screen || place.tab != leaving.place.tab {
            leave(leaving.place)
        }
        current = HistoryEntry(place: self.place(model), expandedCourses: expandedCourses)
    }

    /// For changes that finish a move already recorded, such as a search result opening its assignment.
    func settle(_ change: () -> Void) {
        change()
        if let model { current?.place = place(model) }
    }

    /// Opens a search result as one entry. Back from it reopens the palette in `search`.
    func arrive(at hit: SearchHit, from search: SearchReturnState, _ change: () -> Void) {
        if var leaving = current {
            leaving.expandedCourses = expandedCourses
            leaving.place.file = withShownPage(leaving.place.file)
            leaving.search = search
            history.push(leaving)
        }
        searchTarget = hit
        searchArrival = UUID()
        change()
        if let model { current = HistoryEntry(place: place(model), expandedCourses: expandedCourses) }
        // The result's file opens a moment later; that belongs to this entry, not a new one.
        settlesUntil = Date().addingTimeInterval(1.5)
        resultFileUntil = Date().addingTimeInterval(10)
    }

    /// Opens one plan on its course's Plans tab as one entry, the same view a plan search result opens.
    func open(_ plan: PlanPreview, courseId: Int) {
        guard let model else { return }
        if var leaving = current {
            leaving.place = place(model)
            leaving.expandedCourses = expandedCourses
            leaving.place.file = withShownPage(leaving.place.file)
            history.push(leaving)
        }
        searchTarget = SearchHit(
            id: "plan-\(courseId)-\(plan.planId)", kind: .plan, title: plan.name ?? "Plan",
            courseId: courseId, date: plan.start, url: plan.url,
            destination: .plan(courseId: courseId, planId: plan.planId)
        )
        searchArrival = nil
        courseTabs[courseId] = .plans
        model.selection = .course(courseId)
        current = HistoryEntry(place: place(model), expandedCourses: expandedCourses)
    }

    /// Uses the notification's page URL first, then its embedded content URL.
    /// Returns a browser fallback only when neither points to a native destination.
    func openNotification(_ notification: ParityNotification) -> URL? {
        guard let model else { return nil }
        let urls = [notification.url, notification.contentUrl].compactMap(model.absoluteURL)
        for url in urls {
            if openSiteLink(url, courseId: nil, courseTab: .updates) { return nil }
        }
        return urls.first
    }

    func open(_ task: StudyTask) {
        visit(.upcoming) { openTask = task }
    }

    @discardableResult
    func openSiteLink(_ url: URL, courseId: Int? = nil) -> Bool {
        openSiteLink(url, courseId: courseId, courseTab: .plans)
    }

    private func openSiteLink(_ url: URL, courseId: Int?, courseTab: CourseTab) -> Bool {
        guard let model, let origin = model.site?.baseURL, AvatarSession.sameOrigin(url, origin),
              let link = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return false }

        func value(_ key: String) -> String? {
            link.queryItems?.first { $0.name.caseInsensitiveCompare(key) == .orderedSame }?.value
        }

        func id(_ key: String) -> Int? { value(key).flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil } }

        let path = link.path.lowercased()
        let segments = path.split(separator: "/")
        if segments.count == 5, segments[0] == "plans", segments[1] == "courses", segments[3] == "plan",
           let course = Int(segments[2]), let plan = Int(segments[4]), plan > 0 {
            return visitCourse(course, tab: .plans, target: SearchHit(
                id: "plan-\(course)-\(plan)", kind: .plan, title: "Plan", courseId: course,
                destination: .plan(courseId: course, planId: plan)
            ))
        }

        switch path {
        case "/main.aspx", "/course/course.aspx", "/contentarea/contentarea.aspx", "/resources",
             "/learningtoolelement/viewlearningtoolelement.aspx", "/customactivity/customactivityoverview.aspx":
            break
        default:
            return false
        }
        if path == "/contentarea/contentarea.aspx", value("LocationType") != "1" { return false }
        let linkedCourse = id("CourseId") ?? (path == "/contentarea/contentarea.aspx" ? id("LocationId") : nil)
        let course = linkedCourse ?? courseId
        if let course, let bulletin = id("LightBulletinId") ?? id("BulletinId") {
            return visitCourse(course, tab: .updates, target: SearchHit(
                id: "announcement-\(course)-\(bulletin)", kind: .announcement, title: "Announcement", courseId: course,
                destination: .announcement(courseId: course, bulletinId: bulletin)
            ))
        }

        let learningTool = id("LearningToolElementId")
        let activity = id("CustomActivityId")
        let element = id("ElementId") ?? learningTool ?? activity
        let elementType: String? = switch value("ElementType")?.lowercased() {
        // Website links use numeric element types, while the API models use names.
        case "4": "folder"
        case "131072": "learningtoolelement"
        case "524288": "customactivity"
        case let type?: type
        case nil: learningTool != nil ? "learningtoolelement" : (activity != nil ? "customactivity" : nil)
        }
        if let course, let folder = id("FolderId") ?? (elementType == "folder" ? element : nil) {
            let resource = linkedResource(folder, type: "folder", courseId: course, model: model)
                ?? Resource(elementId: folder, elementType: "Folder", title: "Folder", courseId: course)
            return visitCourse(course, tab: .materials) { self.folders[course] = FolderPlace(path: [resource]) }
        }
        if let element {
            if let task = model.tasks.first(where: {
                $0.elementId == element && (course == nil || $0.courseId == course)
                    && (elementType == nil || $0.elementType?.lowercased() == elementType)
            }), task.opensAssignment ? ParityGate.assignments : ParityGate.pages {
                open(task)
                return true
            }
            if let course, let resource = linkedResource(element, type: elementType, courseId: course, model: model),
               !resource.isFolder, FileAcquirer.canAttempt(resource), model.downloadStates[resource.id] != .websiteOnly {
                guard visitCourse(course, tab: .materials) else { return false }
                var hit = SearchHit(resource: resource, courseId: course, context: nil)
                hit.url = url.absoluteString
                model.open(hit)
                return true
            }
            return false
        }
        guard let linkedCourse, ["/main.aspx", "/course/course.aspx", "/contentarea/contentarea.aspx"].contains(path) else {
            return false
        }
        return visitCourse(linkedCourse, tab: courseTab)
    }

    private func linkedResource(_ id: Int, type: String?, courseId: Int, model: AppModel) -> Resource? {
        let prefix = AppModel.folderKeyPrefix(courseId: courseId)
        let matches = model.resources.lazy.filter { $0.key.hasPrefix(prefix) }.flatMap(\.value).filter {
            $0.elementId == id && (type == nil || $0.elementType.lowercased() == type)
        }
        return matches.first
    }

    private func visitCourse(_ course: Int, tab: CourseTab, target: SearchHit? = nil, _ change: () -> Void = {}) -> Bool {
        guard model?.courses.contains(where: { $0.courseId == course }) == true else { return false }
        visit(.course(course), tab: tab, target: target, change)
        return true
    }

    private func visit(_ selection: AppModel.Selection, tab: CourseTab? = nil, target: SearchHit? = nil, _ change: () -> Void) {
        guard let model else { return }
        let previous = place(model)
        var leaving = current ?? HistoryEntry(place: previous, expandedCourses: expandedCourses)
        leaving.place = previous
        leaving.place.file = withShownPage(previous.file)
        leaving.expandedCourses = expandedCourses
        if previous.screen != selection || previous.tab != tab { leave(previous) }
        model.selection = selection
        if case .course(let course) = selection { courseTabs[course] = tab }
        searchTarget = target
        searchArrival = nil
        model.viewerItem = nil
        model.viewerIsFull = false
        change()
        let destination = place(model)
        guard destination != previous else { return }
        history.push(leaving)
        current = HistoryEntry(place: destination, expandedCourses: expandedCourses)
        settlesUntil = .distantPast
        resultFileUntil = .distantPast
    }

    private func isResultFile(_ place: Place, after previous: Place) -> Bool {
        guard Date() < resultFileUntil, place.file != nil else { return false }
        var same = place
        same.file = previous.file
        guard same == previous else { return false }
        resultFileUntil = .distantPast
        return true
    }

    /// Closing the palette without opening a result leaves a plain place, so Back never reopens it there.
    func closePalette() {
        paletteRestore = nil
        isPaletteOpen = false
        current?.search = nil
    }

    // MARK: Moving

    func goBack() { move(.back) }
    func goForward() { move(.forward) }

    /// A draft on screen is never dropped silently: the person confirms first, then `confirmed` moves.
    func move(_ direction: HistoryMove, confirmed: Bool = false) {
        guard let model, var leaving = current else { return }
        guard direction == .back ? canGoBack : canGoForward else { return }
        if hasDraft && !confirmed {
            pendingMove = direction
            return
        }
        pendingMove = nil
        leaving.place = place(model)
        leaving.place.file = withShownPage(leaving.place.file)
        leaving.expandedCourses = expandedCourses
        guard let target = direction == .back ? history.goBack(from: leaving) : history.goForward(from: leaving) else { return }
        apply(target, model: model)
    }

    private func apply(_ entry: HistoryEntry, model: AppModel) {
        let place = entry.place
        searchArrival = nil
        model.selection = place.selection
        courseTabs = place.courseTabs
        folders = place.folders
        openTask = place.openTask
        selectedThread = place.thread
        searchTarget = place.searchTarget
        expandedCourses = entry.expandedCourses
        if let file = place.file {
            model.viewerItem = file
        } else if model.viewerItem != nil {
            // Hides the reader and keeps its tabs, so Forward brings the file back where it was.
            model.viewerItem = nil
            model.viewerIsFull = false
        }
        paletteRestore = entry.search
        if entry.search != nil { paletteID = UUID() }
        isPaletteOpen = entry.search != nil
        current = HistoryEntry(place: self.place(model), expandedCourses: expandedCourses, search: entry.search)
        settlesUntil = .distantPast
        resultFileUntil = .distantPast
    }

    /// What a screen had open stays in its entry; the next visit starts at the top, as before history.
    private func leave(_ place: Place) {
        searchTarget = nil
        searchArrival = nil
        switch place.selection {
        case .course(let id): folders[id] = nil
        case .upcoming: openTask = nil
        case .messages: selectedThread = nil
        default: break
        }
    }

    private func reset() {
        history.reset()
        pendingMove = nil
        swipeFeedback = nil
        paletteRestore = nil
        settlesUntil = .distantPast
        resultFileUntil = .distantPast
        account = model?.snapshots.map(ObjectIdentifier.init)
        current = model.map { HistoryEntry(place: place($0), expandedCourses: expandedCourses) }
    }

    private func withShownPage(_ file: ViewerItem?) -> ViewerItem? {
        guard var file, let model, let page = model.viewerPage(for: file),
              // The first page of a file opened without one stays plain, with no page badge.
              page != 0 || file.startPage != nil else { return file }
        file.startPage = page
        return file
    }
}

/// Back and Forward for the Go menu, from the focused window.
struct HistoryActions {
    var canGoBack: Bool
    var canGoForward: Bool
    let back: @MainActor () -> Void
    let forward: @MainActor () -> Void
}

extension FocusedValues {
    @Entry var history: HistoryActions?
}

/// True while any compose view on screen holds text or files that have not been sent.
struct UnsentDraftKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

extension View {
    /// Marks unsent work, so Back and Forward ask before leaving it.
    func unsentDraft(_ isUnsent: Bool) -> some View {
        preference(key: UnsentDraftKey.self, value: isUnsent)
    }
}

/// Mouse back/forward buttons, AppKit's three-finger page swipe, and Safari-style two-finger
/// trackpad swipes when "Swipe between pages" allows scroll events, in this window only.
struct HistoryEventMonitor: NSViewRepresentable {
    let canGoBack: Bool
    let canGoForward: Bool
    let isSuspended: Bool
    let onBack: () -> Void
    let onForward: () -> Void
    let onSwipeProgress: (SwipeFeedback?) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: MonitorView) {
        view.canGoBack = canGoBack
        view.canGoForward = canGoForward
        view.isSuspended = isSuspended
        view.onBack = onBack
        view.onForward = onForward
        view.onSwipeProgress = onSwipeProgress
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

    final class MonitorView: NSView {
        var canGoBack = false
        var canGoForward = false
        var isSuspended = false
        var onBack: () -> Void = {}
        var onForward: () -> Void = {}
        var onSwipeProgress: (SwipeFeedback?) -> Void = { _ in }
        private var token: Any?
        private var scrollState: ScrollSwipeState = .idle

        private enum ScrollSwipeState {
            case idle
            case deciding(dx: CGFloat, dy: CGFloat)
            case tracking
            case ignored
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            token = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .swipe, .scrollWheel]) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func stop() {
            if let token { NSEvent.removeMonitor(token) }
            token = nil
            if case .tracking = scrollState { onSwipeProgress(nil) }
            scrollState = .idle
        }

        private func isBlocked(in window: NSWindow) -> Bool {
            if isSuspended || window.attachedSheet != nil || NSApp.modalWindow != nil { return true }
            if window.childWindows?.contains(where: { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }) == true {
                return true
            }
            return false
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window else { return event }
            if event.type == .scrollWheel {
                return handleScroll(event, in: window)
            }
            switch event.type {
            case .otherMouseDown where event.buttonNumber == 3: onBack()
            case .otherMouseDown where event.buttonNumber == 4: onForward()
            case .swipe where event.deltaX > 0: onBack()
            case .swipe where event.deltaX < 0: onForward()
            default: return event
            }
            return nil
        }

        private func handleScroll(_ event: NSEvent, in window: NSWindow) -> NSEvent? {
            guard NSEvent.isSwipeTrackingFromScrollEventsEnabled,
                  event.hasPreciseScrollingDeltas,
                  event.momentumPhase.isEmpty else {
                if event.phase == .ended || event.phase == .cancelled, case .deciding = scrollState {
                    scrollState = .idle
                }
                return event
            }

            if case .tracking = scrollState {
                // Let AppKit's active trackSwipeEvent session receive subsequent gesture events.
                return event
            }

            if event.phase == .ended || event.phase == .cancelled {
                scrollState = .idle
                return event
            }

            if event.phase == .began {
                guard !isBlocked(in: window),
                      canGoBack || canGoForward,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      !isHorizontallyScrollableTarget(at: event.locationInWindow, in: window) else {
                    scrollState = .ignored
                    return event
                }
                scrollState = .deciding(dx: 0, dy: 0)
            }

            guard event.phase == .began || event.phase == .changed,
                  case .deciding(let accumulatedX, let accumulatedY) = scrollState else {
                return event
            }

            let dx = accumulatedX + event.scrollingDeltaX
            let dy = accumulatedY + event.scrollingDeltaY
            let magnitude = max(abs(dx), abs(dy))
            guard magnitude >= 3 else {
                scrollState = .deciding(dx: dx, dy: dy)
                return event
            }

            // Require a clearly horizontal gesture before handing off to AppKit's fluid swipe tracker.
            guard abs(dx) > abs(dy) * 1.5 else {
                scrollState = .ignored
                return event
            }

            // With natural scrolling off the deltas are flipped; fingers moving right always mean Back.
            let fingersRight = event.isDirectionInvertedFromDevice ? dx > 0 : dx < 0
            let direction: HistoryMove = fingersRight ? .back : .forward
            guard direction == .back ? canGoBack : canGoForward else {
                scrollState = .ignored
                return event
            }

            scrollState = .tracking
            // AppKit reports the gesture amount in scroll terms: positive while the deltas are.
            let sign: CGFloat = (dx > 0) ? 1 : -1
            let minThreshold: CGFloat = sign < 0 ? -1 : 0
            let maxThreshold: CGFloat = sign > 0 ? 1 : 0
            event.trackSwipeEvent(
                options: [.lockDirection, .clampGestureAmount],
                dampenAmountThresholdMin: minThreshold,
                max: maxThreshold
            ) { [weak self] gestureAmount, phase, isComplete, stop in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.handleSwipeTracking(
                        gestureAmount: gestureAmount,
                        phase: phase,
                        isComplete: isComplete,
                        direction: direction,
                        sign: sign
                    ) {
                        stop.pointee = true
                    }
                }
            }
            return nil
        }

        /// Follows the fingers, and moves the moment they lift past AppKit's threshold (phase
        /// `.ended`) rather than after the settle animation. Returns true to stop tracking.
        private func handleSwipeTracking(
            gestureAmount: CGFloat, phase: NSEvent.Phase, isComplete: Bool, direction: HistoryMove, sign: CGFloat
        ) -> Bool {
            guard case .tracking = scrollState else { return true }
            if phase == .ended || isComplete {
                scrollState = .idle
                onSwipeProgress(nil)
                if phase == .ended {
                    switch direction {
                    case .back where canGoBack: onBack()
                    case .forward where canGoForward: onForward()
                    default: break
                    }
                }
                return true
            }
            let progress = max(gestureAmount * sign, 0)
            onSwipeProgress(SwipeFeedback(direction: direction, progress: min(progress, 1)))
            return false
        }

        private func isHorizontallyScrollableTarget(at locationInWindow: NSPoint, in window: NSWindow) -> Bool {
            guard let contentView = window.contentView else { return false }
            let hitPoint = contentView.superview?.convert(locationInWindow, from: nil) ?? locationInWindow
            var current = contentView.hitTest(hitPoint)
            while let view = current {
                if let textView = view as? NSTextView, textView.isEditable { return true }
                if let textField = view as? NSTextField, textField.isEditable { return true }
                if view is NSSlider || view is NSComboBox || view is QLPreviewView || view is WKWebView { return true }
                if let scrollView = view as? NSScrollView, let document = scrollView.documentView {
                    if document.bounds.width > scrollView.documentVisibleRect.width + 2 { return true }
                }
                current = view.superview
            }
            return false
        }
    }
}

/// Observes `navigation.swipeFeedback` in isolation so trackpad frames never re-render `MainView`.
struct HistorySwipeOverlay: View {
    @Environment(Navigation.self) private var navigation

    var body: some View {
        if let feedback = navigation.swipeFeedback {
            HistorySwipeIndicator(feedback: feedback)
        }
    }
}

/// A small chevron in a circle sliding in from the leading or trailing edge during a two-finger swipe.
private struct HistorySwipeIndicator: View {
    let feedback: SwipeFeedback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let diameter: CGFloat = Size.control + Space.s8

    var body: some View {
        let t = feedback.progress
        let isReady = t >= 0.5
        let isBack = feedback.direction == .back
        let travel = Self.diameter + Space.s16
        let offsetX: CGFloat = if reduceMotion {
            isBack ? Space.s16 : -Space.s16
        } else {
            isBack ? (-Self.diameter + t * travel) : (Self.diameter - t * travel)
        }
        ZStack(alignment: isBack ? .leading : .trailing) {
            Color.clear
            Image(systemName: isBack ? Symbol.back : Symbol.forward)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isReady ? Color.onAccent : Color.text)
                .frame(width: Self.diameter, height: Self.diameter)
                .background(Circle().fill(isReady ? Color.accentFill : Color.raised))
                .overlay(Circle().strokeBorder(isReady ? Color.accentFill : Color.borderStrong, lineWidth: 1))
                .shadow(color: Color.shadowPopup, radius: 6, y: 2)
                .offset(x: offsetX)
                .opacity(min(t * 4, 1))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .transaction { $0.animation = nil }
    }
}

/// Moves the page with the fingers during a two-finger history swipe, observed on its own so
/// trackpad frames never re-render the page itself.
struct HistorySwipeShift: ViewModifier {
    @Environment(Navigation.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far the page travels at full progress.
    private static let travel: CGFloat = 120

    func body(content: Content) -> some View {
        let shift: CGFloat = if let feedback = navigation.swipeFeedback, !reduceMotion {
            (feedback.direction == .back ? 1 : -1) * feedback.progress * Self.travel
        } else {
            0
        }
        content
            .offset(x: shift)
            .transaction { $0.animation = nil }
    }
}

/// Shown above Archived while a new version is out. One click starts the update; the popover shows its progress.
struct UpdateRailButton: View {
    @Environment(Updater.self) private var updater
    @State private var isOpen = false

    var body: some View {
        IconButton(Symbol.appUpdate, label: label) {
            isOpen = true
            updater.update()
        }
        .frame(width: Size.control + Space.s4, height: Size.control + Space.s4)
        .overlay { ring }
        .overlay(alignment: .topTrailing) {
            if case .available = updater.phase {
                Circle().fill(Color.accentFill).frame(width: 7, height: 7).offset(x: -3, y: 3)
            }
        }
        .accessibilityIdentifier("rail.update")
        .popover(isPresented: $isOpen, arrowEdge: .trailing) {
            UpdateProgressView()
        }
    }

    private var label: String {
        switch updater.phase {
        case .available(let version): "Update to Laer \(version)"
        case .failed: "Update failed"
        default: "Updating Laer"
        }
    }

    /// Progress drawn round the icon, so it reads even with the popover closed.
    @ViewBuilder private var ring: some View {
        if let fraction = UpdateProgressView.fraction(updater.phase) {
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Color.accentFill, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(3)
                .animation(.linear(duration: 0.2), value: fraction)
                .allowsHitTesting(false)
        }
    }
}

private struct UpdateProgressView: View {
    @Environment(Updater.self) private var updater

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            Text(title)
                .font(Type.t13.weight(.semibold))
                .foregroundStyle(Color.text)
                .accessibilityAddTraits(.isHeader)
            switch updater.phase {
            case .available:
                Text("Laer downloads the update, installs it and restarts.")
                    .font(Type.t12)
                    .foregroundStyle(Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                TextButton("Update now", role: .primary) { updater.update() }
            case .failed(let message):
                ErrorLine(message)
                TextButton("Try again", role: .primary) { updater.update() }
            default:
                if let fraction = Self.fraction(updater.phase) {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(Color.accentFill)
                        .accessibilityLabel("Update progress")
                        .accessibilityValue("\(Int(fraction * 100)) percent")
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(Color.accentFill)
                        .accessibilityLabel("Update progress")
                }
                HStack {
                    Text(detail)
                    Spacer(minLength: Space.s8)
                    if let fraction = Self.fraction(updater.phase) {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                    }
                }
                .font(Type.t11)
                .foregroundStyle(Color.textMuted)
            }
        }
        .padding(Space.s12)
        .frame(width: 280, alignment: .leading)
    }

    private var title: String {
        switch updater.phase {
        case .available(let version): "Laer \(version) is available"
        case .downloading(let version, _), .extracting(let version, _), .installing(let version): "Updating to Laer \(version)"
        case .failed: "Update failed"
        case .checking: "Checking for updates"
        case .idle: "Laer is up to date"
        }
    }

    private var detail: String {
        switch updater.phase {
        case .downloading:
            guard updater.expectedBytes > 0 else { return "Downloading…" }
            let style = ByteCountFormatStyle(style: .file)
            return "Downloading \(Int64(updater.receivedBytes).formatted(style)) of \(Int64(updater.expectedBytes).formatted(style))"
        case .extracting: return "Preparing the update…"
        case .installing: return "Installing. Laer restarts in a moment."
        default: return ""
        }
    }

    /// Download is the first 80 percent of the bar, unpacking the rest, so it only ever moves forward.
    static func fraction(_ phase: Updater.Phase) -> Double? {
        switch phase {
        case .downloading(_, let fraction): fraction.map { $0 * 0.8 }
        case .extracting(_, let fraction): 0.8 + 0.2 * fraction
        case .installing: 1
        default: nil
        }
    }
}

/// Courses that aren't active, from the rail. A pick opens the course and closes the list.
struct ArchiveList: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigation.self) private var navigation
    @State private var action = WriteAction()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Archived courses")
                .font(Type.t13.weight(.semibold))
                .foregroundStyle(Color.text)
                .padding(.horizontal, Space.s8)
                .padding(.top, Space.s4)
                .padding(.bottom, Space.s6)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.s2) {
                    ForEach(model.archivedCourses) { course in
                        RowButton(selected: model.selection == .course(course.courseId), action: { open(course) }) {
                            HStack(spacing: Space.s8) {
                                Image(systemName: Symbol.course)
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundStyle(Color.textMuted)
                                    .frame(width: Size.icon)
                                    .accessibilityHidden(true)
                                Text(course.shortTitle)
                                    .font(Type.t13)
                                    .foregroundStyle(Color.text)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: Size.control)
                            }
                        }
                        .accessibilityLabel(course.shortTitle)
                        .accessibilityIdentifier("archive.course.\(course.courseId)")
                        .overlay(alignment: .trailing) {
                            if ParityGate.writes {
                                IconButton(Symbol.star, label: "Make active") {
                                    Task { _ = await action.run { await model.toggleActive(course) } }
                                }
                                .disabled(action.isRunning)
                                .padding(.trailing, Space.s4)
                            }
                        }
                        .contextMenu {
                            if ParityGate.writes {
                                ActiveMenuItem(courseId: course.courseId, action: action) {
                                    _ = await action.run { await model.toggleActive(course) }
                                }
                            }
                        }
                    }
                }
                .undividedRows()
                .environment(\.rowSurface, .raised)
            }
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.s4)
        .frame(width: 300)
        .background(Color.raised)
    }

    private func open(_ course: Course) {
        navigation.isArchiveOpen = false
        model.selection = .course(course.courseId)
    }
}
