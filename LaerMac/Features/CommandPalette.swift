import LaerCore
import SwiftUI

/// Search over everything Laer has read, opened from the toolbar or ⌘K.
/// Arrow keys move, Return opens, Esc closes, ⌘1 to ⌘6 pick a tab along the bottom.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigation.self) private var navigation
    @State private var text = ""
    @State private var scope: ScopeChoice = .everywhere
    @State private var kind: SearchKind?
    @State private var fileType: String?
    @State private var localHits: [SearchHit] = []
    @State private var onlineHits: [SearchHit] = []
    @State private var highlighted: String?
    @State private var visibleCount = 60
    @State private var onlineSummary: OnlineSearchSummary?
    @State private var expandedDocuments: Set<String> = []
    @State private var searchingOnline = false
    @State private var hasSearched = false
    @State private var contentHeight: CGFloat = 0
    @FocusState private var isFieldFocused: Bool
    // Changed in Settings; read here for the status lines and online search.
    @AppStorage("LaerSearchOnline") private var onlineEnabled = false
    @AppStorage(AppModel.searchOCRPreference) private var recognizesScans = false
    /// Back reopened this palette, so its course scope stays as it was left.
    private let restored: Bool

    init(restoring state: SearchReturnState? = nil) {
        restored = state != nil
        guard let state else { return }
        _text = State(initialValue: state.text)
        _scope = State(initialValue: state.scope)
        _kind = State(initialValue: state.kind)
        _fileType = State(initialValue: state.fileType)
        _highlighted = State(initialValue: state.selectedID)
        _visibleCount = State(initialValue: state.visibleCount)
        _localHits = State(initialValue: state.localHits)
        _onlineHits = State(initialValue: state.onlineHits)
        _onlineSummary = State(initialValue: state.onlineSummary)
        _expandedDocuments = State(initialValue: state.expandedDocuments)
        _hasSearched = State(initialValue: true)
        _keepsRestoredOnline = State(initialValue: state.onlineSummary != nil || !state.onlineHits.isEmpty)
    }

    @State private var keepsRestoredOnline = false
    /// The query the shown local results belong to.
    @State private var localQuery: Query?
    @State private var opensWhenCurrent = false
    /// The last pointer position over a row, in window coordinates.
    @State private var pointer: CGPoint?
    /// The row the arrow keys moved to, which the list scrolls into view.
    @State private var keyboardTarget: String?

    /// Everywhere, or one course shown as a token in the field.
    enum ScopeChoice: Hashable {
        case everywhere
        case course(Int)
    }

    private static let fileTypes = ["pdf", "txt", "png", "jpg", "jpeg", "pptx", "docx", "xlsx"]

    /// The tabs along the bottom, in order; `nil` is All. Courses and calendar entries appear under All only.
    private var tabs: [SearchKind?] {
        var kinds: [SearchKind?] = [nil, .material, .plan, .task]
        if ParityGate.messages { kinds.append(.message) }
        kinds.append(.announcement)
        return kinds
    }

    /// The order of the sections under All, after the best match.
    private static let sectionOrder: [SearchKind] = [.material, .plan, .task, .announcement, .message, .event, .course]
    /// Rows per section under All; the rest are one tab away.
    private static let sectionLimit = 4

    private var currentCourseId: Int? {
        if case .course(let id) = model.selection { return id }
        return nil
    }

    private var scopedCourse: Int? {
        if case .course(let id) = scope { return id }
        return nil
    }

    private var searchScope: SearchScope {
        switch scope {
        case .everywhere: .everywhere
        case .course(let id): .course(id)
        }
    }

    private struct Query: Equatable {
        var text: String
        var scope: SearchScope
        var kind: SearchKind?
        var fileType: String?
    }

    private struct LocalQuery: Equatable {
        var query: Query
        var limit: Int
        var revision: Int
    }

    private struct OnlineQuery: Equatable {
        var query: Query
        var enabled: Bool
        var courses: [Int]
    }

    /// One titled group of rows. Under a tab there is one untitled group.
    private struct Section: Identifiable {
        var id: String
        var title: String?
        var hits: [SearchHit]
        /// The tab with every match of this kind, when the section shows only the first few.
        var more: SearchKind?
    }

    private var query: Query {
        Query(text: text.trimmingCharacters(in: .whitespacesAndNewlines), scope: searchScope, kind: kind, fileType: fileType)
    }

    private var onlineCourses: [Course] {
        switch searchScope {
        case .everywhere: return model.activeCourses + model.archivedCourses
        case .activeCourses: return model.activeCourses
        case .course(let id): return model.courses.filter { $0.courseId == id }
        }
    }

    private var allHits: [SearchHit] { SearchHit.unique(localHits + onlineHits) }
    /// Every row in the order shown, which is the order the arrow keys walk.
    private var hits: [SearchHit] { sections.flatMap(\.hits) }

    /// Under All: the best match, then a few rows of each kind. Under a tab: every row.
    private var sections: [Section] {
        let visible = shownHits(page(allHits))
        let single = [Section(id: "all", title: nil, hits: visible, more: nil)]
        guard kind == nil, let best = visible.first else { return single }
        let grouped = Dictionary(grouping: visible, by: \.kind)
        let present = Self.sectionOrder.filter { grouped[$0] != nil }
        guard present.count > 1 else { return single }
        var result = [Section(id: "best", title: "Best match", hits: [best], more: nil)]
        for item in present {
            let rows = grouped[item, default: []].filter { $0.id != best.id }
            guard !rows.isEmpty else { continue }
            let hasTab = tabs.contains(item)
            let shown = hasTab ? Array(rows.prefix(Self.sectionLimit)) : rows
            result.append(Section(id: item.rawValue, title: Self.title(for: item), hits: shown,
                                  more: hasTab && rows.count > shown.count ? item : nil))
        }
        return result
    }

    /// Every matching page of one document counts as one result.
    private static func resultKey(_ hit: SearchHit) -> String { hit.document?.resourceKey ?? hit.id }

    private func page(_ matches: [SearchHit]) -> [SearchHit] {
        var keys = Set<String>()
        return matches.filter { hit in
            let key = Self.resultKey(hit)
            if keys.contains(key) { return true }
            guard keys.count < visibleCount else { return false }
            keys.insert(key)
            return true
        }
    }

    private static func resultCount(_ matches: [SearchHit]) -> Int { Set(matches.map(resultKey)).count }

    private func shownHits(_ page: [SearchHit]) -> [SearchHit] {
        var seen = Set<String>()
        return page.filter { hit in
            guard let key = hit.document?.resourceKey else { return true }
            return expandedDocuments.contains(key) || seen.insert(key).inserted
        }
    }

    private var isBusy: Bool { !query.text.isEmpty && (searchingOnline || model.isIndexing || model.searchOCRIsRunning) }

    var body: some View {
        GeometryReader { geo in
        ZStack(alignment: .top) {
            // Dims the whole window, toolbar included, so no strip of the top bar is left bright.
            Color.scrim.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                field
                Rectangle().fill(Color.border).frame(height: 1)
                // The filters stay under the field whether or not there are results.
                tabBar
                if !query.text.isEmpty || query.fileType != nil || model.searchIndexFailed {
                    Rectangle().fill(Color.border).frame(height: 1)
                    results
                    status
                }
            }
            .frame(width: Size.palette)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous).strokeBorder(Color.borderStrong, lineWidth: 1))
            .floatShadow()
            // The whole panel fits the window with 80pt to spare; the results scroll inside.
            .frame(maxHeight: max(geo.size.height - Self.topOffset - 80, 160), alignment: .top)
            .padding(.top, Self.topOffset)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Search")
            .accessibilityIdentifier("palette")
        }
        }
        // Focus after the overlay is in the window, or the field never takes it.
        .task {
            if let preset = navigation.paletteKind {
                kind = preset
                navigation.paletteKind = nil
            }
            // Opened inside a course, search starts there; the token in the field widens it.
            if !restored, let course = currentCourseId { scope = .course(course) }
            try? await Task.sleep(for: .milliseconds(50))
            isFieldFocused = true
        }
        .onChange(of: kind) { if kind != .material { fileType = nil } }
        // The previous results stay until the new ones arrive, so typing never blanks the list.
        .onChange(of: query) {
            keepsRestoredOnline = false
            highlighted = nil
            visibleCount = 60
            expandedDocuments = []
            if query.text.isEmpty && query.fileType == nil {
                localHits = []
                onlineHits = []
                onlineSummary = nil
                hasSearched = false
            }
        }
        .task(id: LocalQuery(query: query, limit: visibleCount, revision: model.searchRevision)) {
            await runLocalSearch()
        }
        .task(id: OnlineQuery(query: query, enabled: onlineEnabled, courses: onlineCourses.map(\.courseId))) {
            await runOnlineSearch()
        }
    }

    private var field: some View {
        HStack(spacing: Space.s8) {
            Image(systemName: Symbol.search)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Color.textMuted)
                .accessibilityHidden(true)
            if let course = scopedCourse {
                courseToken(course)
            }
            TextField(scopedCourse == nil ? "Search courses, plans, files and messages" : "Search this course", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(Color.text)
                .focused($isFieldFocused)
                .onSubmit(openHighlighted)
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.escape) { close(); return .handled }
                // Backspace in an empty field removes the course token, as in Mail and Finder.
                .onKeyPress(.delete) {
                    guard text.isEmpty, scopedCourse != nil else { return .ignored }
                    scope = .everywhere
                    return .handled
                }
                .accessibilityLabel("Search")
        }
        .padding(.horizontal, Space.s12)
        .frame(height: 48)
    }

    /// The course search is limited to, removable with its button or Backspace.
    private func courseToken(_ course: Int) -> some View {
        HStack(spacing: Space.s4) {
            Circle()
                .fill(Color.course(course))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(courseTitle(course) ?? "This course")
                .font(Type.t12)
                .foregroundStyle(Color.text)
                .lineLimit(1)
            Button {
                scope = .everywhere
                isFieldFocused = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.textMuted)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search all courses")
            .accessibilityIdentifier("search.scope.clear")
        }
        .padding(.leading, Space.s6)
        .padding(.trailing, Space.s2)
        .frame(height: 22)
        .frame(maxWidth: 180, alignment: .leading)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).fill(Color.selected))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Searching in \(courseTitle(course) ?? "this course")")
        .accessibilityIdentifier("search.scope")
    }

    /// Kinds along the bottom edge; the file type menu joins them under Files.
    private var tabBar: some View {
        HStack(spacing: Space.s2) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { index, item in
                tabButton(item, number: index + 1)
            }
            Spacer(minLength: Space.s8)
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Searching")
            }
            if kind == .material { fileTypeMenu }
        }
        .padding(.horizontal, Space.s8)
        .padding(.vertical, Space.s6)
    }

    private func tabButton(_ item: SearchKind?, number: Int) -> some View {
        let selected = kind == item
        let title = item.map(Self.title(for:)) ?? "All"
        return Button { choose(item) } label: {
            Text(title)
                .font(Type.t12)
                .foregroundStyle(selected ? Color.text : Color.textMuted)
                .padding(.horizontal, Space.s8)
                .frame(height: Size.controlSmall)
                .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(selected ? Color.selected : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
        .help("\(title) (⌘\(number))")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("search.tab.\(item?.rawValue ?? "all")")
    }

    private var fileTypeMenu: some View {
        Menu {
            Button("Any type") { fileType = nil }
            Divider()
            ForEach(Self.fileTypes, id: \.self) { type in
                Button(type.uppercased()) { fileType = type }
            }
        } label: {
            Text(fileType?.uppercased() ?? "Any type")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .font(Type.t12)
        .fixedSize()
        .accessibilityLabel("File type")
    }

    private func choose(_ item: SearchKind?) {
        kind = item
        isFieldFocused = true
    }

    @ViewBuilder private var results: some View {
        let matches = allHits
        let page = page(matches)
        let documents = Dictionary(grouping: page.compactMap { hit in hit.document.map { ($0.resourceKey, hit.id) } }, by: \.0)
        let groups = sections
        let rows = groups.flatMap(\.hits)
        let selectedID = rows.first(where: { $0.id == highlighted })?.id ?? rows.first?.id
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if rows.isEmpty {
                        emptyState
                            .padding(Space.s8)
                    }
                    ForEach(groups) { group in
                        if let title = group.title {
                            Text(title)
                                .font(Type.t11)
                                .foregroundStyle(Color.textMuted)
                                .padding(.horizontal, Space.s8)
                                .padding(.top, group.id == groups.first?.id ? Space.s4 : Space.s12)
                                .padding(.bottom, Space.s4)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(group.hits) { hit in
                            row(hit, selected: hit.id == selectedID)
                            if group.title == nil, let key = hit.document?.resourceKey, let pages = documents[key], pages.count > 1,
                               pages.first?.1 == hit.id {
                                Button(expandedDocuments.contains(key) ? "Hide other matches" : "Show \(pages.count) matches in this document") {
                                    if expandedDocuments.contains(key) { expandedDocuments.remove(key) }
                                    else { expandedDocuments.insert(key) }
                                }
                                .buttonStyle(.plain)
                                .font(Type.t11)
                                .foregroundStyle(Color.accent)
                                .padding(.leading, Size.icon + Space.s12)
                                .padding(.bottom, Space.s4)
                            }
                        }
                        if let more = group.more {
                            Button("All \(Self.title(for: more).lowercased())") { choose(more) }
                                .buttonStyle(.plain)
                                .font(Type.t11)
                                .foregroundStyle(Color.accent)
                                .padding(.leading, Size.icon + Space.s12)
                                .padding(.vertical, Space.s4)
                                .accessibilityIdentifier("search.more.\(more.rawValue)")
                        }
                    }
                    if kind != nil, Self.resultCount(matches) > visibleCount, visibleCount < 500 {
                        Button("Show more results") { visibleCount = min(visibleCount + 60, 500) }
                            .padding(Space.s8)
                    } else if kind != nil, Self.resultCount(matches) > visibleCount {
                        EmptyLine("Showing the first 500 matches. Narrow the search to see different matches.")
                            .padding(Space.s8)
                    }
                }
                .padding(.horizontal, Space.s4)
                .padding(.vertical, Space.s4)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            // Hug the rows up to a whole number of rows; past that the scrollbar says there is more.
            .frame(idealHeight: resultsHeight, maxHeight: resultsHeight)
            .scrollIndicators(.visible)
            // Follows the keyboard only; scrolling to a hovered row would fight the trackpad.
            .onChange(of: keyboardTarget) { _, id in if let id { proxy.scrollTo(id) } }
        }
    }

    private func row(_ hit: SearchHit, selected: Bool) -> some View {
        RowButton(selected: selected, action: { open(hit) }) {
            HitRow(hit: hit, subtitle: subtitle(for: hit), showsCourseDot: scopedCourse == nil)
        }
        // The selection is the row's own background, behind its text.
        .environment(\.rowSelectedFill, Color.accent.opacity(0.15))
        .environment(\.rowSurface, .clear)
        .accessibilityIdentifier("search.result.\(hit.id)")
        .id(hit.id)
        // Only a moving pointer selects: rows scrolling under a still pointer leave the selection alone.
        .onContinuousHover(coordinateSpace: .global) { phase in
            guard case .active(let location) = phase, location != pointer else { return }
            pointer = location
            highlighted = hit.id
        }
    }

    /// Nothing found inside one course offers the same search everywhere.
    @ViewBuilder private var emptyState: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            EmptyLine(emptyText)
            if hasSearched, scopedCourse != nil, !isBusy {
                Button("Search all courses") {
                    scope = .everywhere
                    isFieldFocused = true
                }
                .buttonStyle(.plain)
                .font(Type.t12)
                .foregroundStyle(Color.accent)
                .padding(.horizontal, Space.s8)
            }
        }
    }

    /// Capped on a row boundary, so no result is ever cut through its text.
    private var resultsHeight: CGFloat {
        guard contentHeight > Self.maxResultsHeight else { return contentHeight }
        let rows = ((Self.maxResultsHeight - Space.s8) / Self.rowHeight).rounded(.down)
        return rows * Self.rowHeight + Space.s8
    }

    private static let rowHeight: CGFloat = 44
    private static let maxResultsHeight: CGFloat = 400

    private var emptyText: String {
        if query.text.isEmpty && query.fileType == nil { return "Type to search" }
        if model.searchIndexFailed { return "Local search is unavailable" }
        if searchingOnline || model.isIndexing || model.searchOCRIsRunning { return "Searching…" }
        if onlineSummary?.error != nil || model.searchCoverageIncomplete { return hasSearched ? "No matches in the sources searched" : "" }
        return hasSearched ? "Nothing matches" : ""
    }

    /// Only what changes how far to trust the list: a broken index, work still running, or partial coverage.
    private var statusLines: [String] {
        guard !query.text.isEmpty || query.fileType != nil || model.searchIndexFailed else { return [] }
        if model.searchIndexFailed { return ["The local index could not be read. Rebuild it in Settings."] }
        var lines: [String] = []
        if recognizesScans && model.searchOCRPowerPaused {
            lines.append("Text recognition paused in Low Power Mode")
        } else if model.isIndexing || model.searchOCRIsRunning {
            lines.append("Indexing in progress, more results may appear")
        } else if model.searchCoverageIncomplete {
            lines.append("Some courses aren't fully indexed yet")
        }
        if searchingOnline {
            lines.append("Searching itslearning…")
        } else if let summary = onlineSummary {
            if let error = summary.error {
                lines.append("itslearning: \(error)")
            } else if summary.incomplete {
                lines.append("itslearning searched \(summary.searched) of \(summary.total) courses")
            }
        }
        return lines
    }

    @ViewBuilder private var status: some View {
        let lines = statusLines
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: Space.s4) {
                ForEach(lines, id: \.self) { Text($0) }
            }
            .font(Type.t11)
            .foregroundStyle(Color.textMuted)
            .padding(.horizontal, Space.s12)
            .padding(.vertical, Space.s6)
            .accessibilityElement(children: .combine)
        }
    }

    private func runLocalSearch() async {
        let current = query
        guard !current.text.isEmpty || current.fileType != nil else { return }
        // A background index write re-runs the same query; wait longer so the list doesn't shuffle as it fills.
        try? await Task.sleep(for: .milliseconds(current == localQuery ? 1_000 : 60))
        guard !Task.isCancelled else { return }
        let kinds: Set<SearchKind> = current.kind.map { [$0] } ?? []
        let found = await model.search(current.text, scope: current.scope, kinds: kinds,
                                       fileExtension: current.fileType, limit: visibleCount + 1)
        guard !Task.isCancelled, current == query else { return }
        if localQuery != current { highlighted = nil }
        localHits = found
        localQuery = current
        if highlighted == nil { highlighted = found.first?.id }
        hasSearched = true
        if opensWhenCurrent {
            opensWhenCurrent = false
            openHighlighted()
        }
    }

    private func runOnlineSearch() async {
        if keepsRestoredOnline { keepsRestoredOnline = false; return }
        let current = query
        let targets = onlineCourses
        guard onlineEnabled, current.text.count >= 3, current.kind == nil || current.kind == .material, !targets.isEmpty else {
            onlineHits = []
            onlineSummary = nil
            searchingOnline = false
            return
        }
        searchingOnline = true
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled, current == query else { return }
        // The previous query's online rows stay until this query's first answer replaces them.
        var replaced = false
        let summary = await model.onlineSearch(current.text, courses: targets, fileExtension: current.fileType) { newHits in
            guard current == query else { return }
            onlineHits = replaced ? SearchHit.unique(onlineHits + newHits) : newHits
            replaced = true
        }
        guard !Task.isCancelled, current == query else { return }
        if !replaced { onlineHits = [] }
        onlineSummary = summary
        searchingOnline = false
    }

    private var selectedHit: SearchHit? { hits.first(where: { $0.id == highlighted }) ?? hits.first }

    private func move(_ offset: Int) {
        guard !hits.isEmpty else { return }
        let index = hits.firstIndex { $0.id == selectedHit?.id } ?? 0
        highlighted = hits[min(max(index + offset, 0), hits.count - 1)].id
        keyboardTarget = highlighted
    }

    /// Return on results from an earlier keystroke waits for the current query's results.
    private func openHighlighted() {
        guard localQuery == query else {
            opensWhenCurrent = true
            return
        }
        if let selectedHit { open(selectedHit) }
    }

    /// One history entry: Back from the result reopens this palette as it is now.
    private func open(_ hit: SearchHit) {
        let search = SearchReturnState(
            text: text, scope: scope, kind: kind, fileType: fileType, selectedID: hit.id,
            visibleCount: visibleCount, localHits: localHits, onlineHits: onlineHits, onlineSummary: onlineSummary,
            expandedDocuments: expandedDocuments
        )
        navigation.arrive(at: hit, from: search) {
            close()
            if let course = hit.courseId {
                if hit.kind == .plan { navigation.courseTabs[course] = .plans }
                if hit.kind == .announcement { navigation.courseTabs[course] = .updates }
                if hit.resource?.isFolder == true { navigation.courseTabs[course] = .materials }
            }
            if case .folder(let course, _, _) = hit.destination, let folder = hit.resource {
                navigation.folders[course] = FolderPlace(path: [folder])
            }
            if case .thread(let id) = hit.destination { navigation.selectedThread = id }
            model.open(hit)
        }
    }

    private func close() {
        navigation.closePalette()
    }

    /// A second line that adds to the title, or nothing.
    private func subtitle(for hit: SearchHit) -> String? {
        var parts: [String] = []
        // With a course token in the field every result is in that course; it is not repeated.
        let course = scopedCourse == nil ? courseTitle(hit.courseId) : nil
        let detail = trimmedDetail(hit)
        switch hit.kind {
        case .event:
            if let date = hit.date { parts.append(StudyDates.relative(date)) }
            // The course dot and title row already name the course; only add detail that says more.
            if let detail, !Self.sameText(detail, courseTitle(hit.courseId)), !Self.sameText(detail, hit.title) {
                parts.append(detail)
            }
        case .task:
            if let detail = detail ?? course, !detail.isEmpty { parts.append(detail) }
            if let date = hit.date { parts.append(StudyDates.relative(date)) }
        case .material:
            if let position = hit.document {
                if let page = position.page { parts.append("Page \(page + 1)") }
                parts.append("Saved copy")
                if position.recognizedText == true { parts.append("OCR · may contain errors") }
            }
            if let detail = detail ?? course, !detail.isEmpty {
                parts.append(detail.replacingOccurrences(of: " / ", with: " › ").replacingOccurrences(of: ", ", with: " › "))
            }
        case .announcement:
            // Who, where and when; the text itself is already the title.
            let author = hit.detail?.components(separatedBy: AppModel.announcementSeparator).first ?? ""
            if !author.isEmpty { parts.append(author) }
            if let course { parts.append(course) }
            if let date = hit.date { parts.append(StudyDates.relative(date)) }
        default:
            if let detail = detail ?? course, !detail.isEmpty { parts.append(detail) }
        }
        let line = parts.joined(separator: " · ")
        return line.isEmpty || Self.sameText(line, hit.title) ? nil : line
    }

    /// The hit's detail without a leading name of the course the search is limited to.
    private func trimmedDetail(_ hit: SearchHit) -> String? {
        guard let detail = hit.detail, !detail.isEmpty else { return nil }
        guard scopedCourse != nil, let course = courseTitle(hit.courseId), !course.isEmpty,
              detail.range(of: course, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil
        else { return detail }
        var rest = Substring(detail.dropFirst(course.count))
        while let first = rest.first, " ›/,·-–".contains(first) { rest = rest.dropFirst() }
        return rest.isEmpty ? nil : String(rest)
    }

    private static func sameText(_ a: String, _ b: String?) -> Bool {
        guard let b else { return false }
        return a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    private static let topOffset: CGFloat = 72

    static func isLink(_ hit: SearchHit) -> Bool {
        guard hit.kind == .material, let resource = hit.resource, !resource.isFolder else { return false }
        return resource.learningObjectId == nil && resource.learningObjectInstanceId == nil && hit.fileExtension == nil
    }

    private func courseTitle(_ id: Int?) -> String? {
        guard let id else { return nil }
        return model.courses.first { $0.courseId == id }?.shortTitle
    }

    static func title(for kind: SearchKind) -> String {
        switch kind {
        case .course: "Courses"
        case .plan: "Plans"
        case .material: "Files"
        case .task: "Assignments"
        case .message: "Messages"
        case .event: "Calendar"
        case .announcement: "Updates"
        }
    }

    static func symbol(for kind: SearchKind) -> String {
        switch kind {
        case .course: Symbol.course
        case .plan: Symbol.plan
        case .material: Symbol.material
        case .task: Symbol.task
        case .message: Symbol.message
        case .event: Symbol.lecture
        case .announcement: Symbol.update
        }
    }
}

private struct HitRow: View {
    let hit: SearchHit
    let subtitle: String?
    var showsCourseDot = true

    /// Folders, links (no file behind them) and files each get their own icon, as in Files.
    private var symbol: String {
        if hit.document != nil { return Symbol.file(extension: hit.fileExtension ?? "") }
        guard hit.kind == .material, let resource = hit.resource else { return CommandPalette.symbol(for: hit.kind) }
        if resource.isFolder { return Symbol.folder }
        if CommandPalette.isLink(hit) { return Symbol.link }
        let ext = hit.fileExtension ?? (hit.title as NSString).pathExtension
        return Symbol.file(extension: ext)
    }

    private func highlightedExcerpt(_ excerpt: String) -> Text {
        guard let match = hit.matchedText, let range = excerpt.range(of: match) else { return Text(verbatim: excerpt) }
        var attributed = AttributedString(excerpt)
        if let span = Range(range, in: attributed) { attributed[span].font = Type.t11.weight(.bold) }
        return Text(attributed)
    }

    var body: some View {
        HStack(spacing: Space.s8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.textMuted)
                .frame(width: Size.icon)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.s2) {
                Text(hit.title)
                    .font(Type.t13)
                    .foregroundStyle(Color.text)
                    .lineLimit(1)
                if let subtitle {
                    HStack(spacing: Space.s4) {
                        if showsCourseDot, let course = hit.courseId {
                            Circle()
                                .fill(Color.course(course))
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                        }
                        Text(subtitle)
                            .font(Type.t11)
                            .foregroundStyle(Color.textMuted)
                            .lineLimit(1)
                    }
                }
                if let excerpt = hit.excerpt {
                    highlightedExcerpt(excerpt)
                        .font(Type.t11)
                        .foregroundStyle(Color.textMuted)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: Space.s8)
            // Only when the icon is the generic one and so doesn't show the type.
            if let type = hit.fileExtension, symbol == Symbol.material {
                Text(type.uppercased())
                    .font(Type.t11)
                    .foregroundStyle(Color.textMuted)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
