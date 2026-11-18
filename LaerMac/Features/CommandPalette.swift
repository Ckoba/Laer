import LaerCore
import SwiftUI

/// Search over everything Laer has read, opened from the rail or ⌘K.
/// Arrow keys move, Return opens, Esc closes.
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
    @State private var showsPreview = false
    @State private var searchingOnline = false
    @State private var hasSearched = false
    @State private var contentHeight: CGFloat = 0
    @FocusState private var isFieldFocused: Bool
    @AppStorage("LaerSearchOnline") private var onlineEnabled = false
    @AppStorage("LaerIndexArchivedCourses") private var indexArchived = false
    @AppStorage(AppModel.searchOCRPreference) private var recognizesPDFs = false

    init(restoring state: SearchReturnState? = nil) {
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

    enum ScopeChoice: Hashable {
        case everywhere, active, course
    }

    private static let fileTypes = ["pdf", "pptx", "docx", "xlsx"]

    private var currentCourseId: Int? {
        if case .course(let id) = model.selection { return id }
        return nil
    }

    private var searchScope: SearchScope {
        switch scope {
        case .everywhere: .everywhere
        case .active: .activeCourses
        case .course: currentCourseId.map(SearchScope.course) ?? .everywhere
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
    private var hits: [SearchHit] { shownHits(Array(allHits.prefix(visibleCount))) }

    private func shownHits(_ page: [SearchHit]) -> [SearchHit] {
        var seen = Set<String>()
        return page.filter { hit in
            guard let key = hit.document?.resourceKey else { return true }
            return expandedDocuments.contains(key) || seen.insert(key).inserted
        }
    }

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
                filters
                    .padding(.horizontal, Space.s12)
                    .padding(.bottom, Space.s8)
                Rectangle().fill(Color.border).frame(height: 1)
                results
                status
                if !hits.isEmpty {
                    Rectangle().fill(Color.border).frame(height: 1)
                    HStack {
                        Text(hits.count == 1 ? "1 result" : contentHeight > Self.maxResultsHeight ? "\(hits.count) results, scroll for more" : "\(hits.count) results")
                        Spacer(minLength: Space.s8)
                        Button("Preview") { showsPreview = true }
                            .buttonStyle(.plain)
                            .popover(isPresented: $showsPreview) { preview }
                        Text("↑↓ Select · ↩ Open · esc Close")
                    }
                    .font(Type.t11)
                    .foregroundStyle(Color.textMuted)
                    .padding(.horizontal, Space.s12)
                    .padding(.vertical, Space.s6)
                }
            }
            .frame(width: Size.palette)
            .background(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous).fill(Color.raised))
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
            try? await Task.sleep(for: .milliseconds(50))
            isFieldFocused = true
        }
        .onChange(of: kind) { if kind != .material { fileType = nil } }
        .onChange(of: indexArchived) { Task { await model.changeSearchCoverage() } }
        .onChange(of: recognizesPDFs) { model.updateSearchOCR() }
        .onChange(of: query) {
            keepsRestoredOnline = false
            localHits = []
            onlineHits = []
            highlighted = nil
            onlineSummary = nil
            hasSearched = false
            visibleCount = 60
            expandedDocuments = []
            showsPreview = false
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
            TextField("Search courses, plans, files, tasks and messages", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(Color.text)
                .focused($isFieldFocused)
                .onSubmit(openHighlighted)
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.escape) { close(); return .handled }
                .accessibilityLabel("Search")
        }
        .padding(.horizontal, Space.s12)
        .frame(height: 44)
    }

    /// Three pop-up menus at one weight: where, what kind, which file type.
    private var filters: some View {
        HStack(spacing: Space.s4) {
            Menu {
                Button("All courses") { scope = .everywhere }
                Button("Active courses") { scope = .active }
                if currentCourseId != nil {
                    Button("This course") { scope = .course }
                }
            } label: {
                Text(Self.title(for: scope))
                    .accessibilityLabel(Self.title(for: scope))
            }
            .menuStyle(.button)
            .menuIndicator(.visible)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel("Scope")
            Menu {
                Button("All result types") { kind = nil }
                Divider()
                ForEach(SearchKind.allCases, id: \.self) { item in
                    Button(Self.title(for: item)) { kind = item }
                }
            } label: {
                Text(kind.map(Self.title(for:)) ?? "All result types")
                    .accessibilityLabel(kind.map(Self.title(for:)) ?? "All result types")
            }
            .menuStyle(.button)
            .menuIndicator(.visible)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel("Kind")
            if kind == .material {
            Menu {
                Button("Any file type") { fileType = nil }
                Divider()
                ForEach(Self.fileTypes, id: \.self) { type in
                    Button(type.uppercased()) { fileType = type }
                }
            } label: {
                Text(fileType?.uppercased() ?? "Any file type")
                    .accessibilityLabel(fileType?.uppercased() ?? "Any file type")
            }
            .menuStyle(.button)
            .menuIndicator(.visible)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel("File type")
            }
            Spacer(minLength: 0)
            Menu("Search options") {
                Toggle("Search itslearning online", isOn: $onlineEnabled)
                Toggle("Index archived courses", isOn: $indexArchived)
                Toggle("Recognize text in scanned PDFs", isOn: $recognizesPDFs)
                Button("Rebuild local search index") { Task { await model.rebuildSearchIndex() } }
                    .disabled(model.isIndexing)
            }
            .controlSize(.small)
        }
    }

    private static func title(for scope: ScopeChoice) -> String {
        switch scope {
        case .everywhere: "All courses"
        case .active: "Active courses"
        case .course: "This course"
        }
    }

    @ViewBuilder private var results: some View {
        let matches = allHits
        let page = Array(matches.prefix(visibleCount))
        let visible = shownHits(page)
        let documents = Dictionary(grouping: page.compactMap { hit in hit.document.map { ($0.resourceKey, hit.id) } }, by: \.0)
        let selectedID = visible.first(where: { $0.id == highlighted })?.id ?? visible.first?.id
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if hits.isEmpty {
                        EmptyLine(emptyText)
                            .padding(Space.s8)
                    }
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, hit in
                        if index == 0 {
                            Text("Best matches")
                                .font(Type.section)
                                .foregroundStyle(Color.textMuted)
                                .padding(.horizontal, Space.s8)
                                .padding(.top, index == 0 ? Space.s4 : Space.s12)
                                .padding(.bottom, Space.s4)
                                .accessibilityAddTraits(.isHeader)
                        }
                        RowButton(selected: hit.id == selectedID, action: { open(hit) }) {
                            HitRow(hit: hit, subtitle: subtitle(for: hit))
                        }
                        .accessibilityIdentifier("search.result.\(hit.id)")
                        .overlay {
                            if hit.id == selectedID {
                                RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                                    .fill(Color.accent.opacity(0.15))
                                    .allowsHitTesting(false)
                            }
                        }
                        .id(hit.id)
                        .onHover { if $0 { highlighted = hit.id } }
                        if let key = hit.document?.resourceKey, let pages = documents[key], pages.count > 1,
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
                    if matches.count > visibleCount, visibleCount < 500 {
                        Button("Show more results") { visibleCount = min(visibleCount + 60, 500) }
                            .padding(Space.s8)
                    } else if matches.count > visibleCount {
                        EmptyLine("Showing the first 500 matches. Narrow the search to see different matches.")
                            .padding(Space.s8)
                    }
                }
                .padding(.horizontal, Space.s4)
                .padding(.top, Space.s4)
                .padding(.bottom, Space.s4)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            // Hug the rows up to a whole number of rows; past that the scrollbar and the count say there is more.
            .frame(idealHeight: resultsHeight, maxHeight: resultsHeight)
            .scrollIndicators(.visible)
            .onChange(of: highlighted) { _, id in if let id { proxy.scrollTo(id) } }
        }
    }

    @ViewBuilder private var preview: some View {
        if let hit = selectedHit {
            VStack(alignment: .leading, spacing: Space.s8) {
                Text(hit.title).font(Type.t13.weight(.semibold))
                if let subtitle = subtitle(for: hit) { Text(subtitle).foregroundStyle(Color.textMuted) }
                if let excerpt = hit.excerpt { Text(verbatim: excerpt).textSelection(.enabled) }
                if let contexts = hit.contexts, contexts.count > 1 {
                    Text("Locations").font(Type.t11.weight(.semibold))
                    ForEach(contexts, id: \.self) { Text(verbatim: $0) }
                }
                Button("Open result") { showsPreview = false; open(hit) }
            }
            .font(Type.t12)
            .frame(width: 320, alignment: .leading)
            .padding(Space.s12)
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
        if searchingOnline || model.isIndexing { return "Searching…" }
        if onlineSummary?.error != nil || model.searchCoverageIncomplete { return hasSearched ? "No matches in the sources searched" : "" }
        return hasSearched ? "Nothing matches" : ""
    }

    @ViewBuilder private var status: some View {
        if !query.text.isEmpty || query.fileType != nil || model.searchIndexFailed {
            VStack(alignment: .leading, spacing: Space.s4) {
                if model.searchIndexFailed {
                    Text("The local index could not be read. Rebuild it under Search options.")
                } else if model.searchOCRIsRunning {
                    Text("Recognizing text on this Mac")
                } else if model.isIndexing {
                    Text("Local indexing in progress")
                } else if model.searchCoverageIncomplete {
                    Text("Local index coverage is partial")
                } else {
                    Text("Local results")
                }
                if searchingOnline {
                    Text("Searching itslearning in \(min(onlineCourses.count, 12)) courses")
                } else if let summary = onlineSummary {
                    if let error = summary.error { Text(error) }
                    Text("Online search checked \(summary.searched) of \(summary.total) courses")
                    if summary.incomplete { Text("Online results may be partial") }
                } else if !onlineEnabled {
                    Text("Online search is off")
                }
            }
            .font(Type.t11)
            .foregroundStyle(Color.textMuted)
            .padding(.horizontal, Space.s12)
            .padding(.vertical, Space.s6)
        }
    }

    private func runLocalSearch() async {
        let current = query
        guard !current.text.isEmpty || current.fileType != nil else { return }
        try? await Task.sleep(for: .milliseconds(80))
        guard !Task.isCancelled else { return }
        let kinds: Set<SearchKind> = current.kind.map { [$0] } ?? []
        let found = await model.search(current.text, scope: current.scope, kinds: kinds,
                                       fileExtension: current.fileType, limit: visibleCount + 1)
        guard !Task.isCancelled, current == query else { return }
        if highlighted == nil { highlighted = selectedHit?.id ?? found.first?.id }
        localHits = found
        hasSearched = true
    }

    private func runOnlineSearch() async {
        if keepsRestoredOnline { keepsRestoredOnline = false; return }
        onlineHits = []
        onlineSummary = nil
        searchingOnline = false
        let current = query
        let targets = onlineCourses
        guard onlineEnabled, current.text.count >= 2, current.kind == nil || current.kind == .material, !targets.isEmpty else { return }
        searchingOnline = true
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled, current == query else { return }
        let summary = await model.onlineSearch(current.text, courses: targets, fileExtension: current.fileType) { newHits in
            if highlighted == nil { highlighted = selectedHit?.id ?? newHits.first?.id }
            onlineHits = SearchHit.unique(onlineHits + newHits)
        }
        guard !Task.isCancelled, current == query else { return }
        onlineSummary = summary
        searchingOnline = false
    }

    private var selectedHit: SearchHit? { hits.first(where: { $0.id == highlighted }) ?? hits.first }

    private func move(_ offset: Int) {
        guard !hits.isEmpty else { return }
        let index = hits.firstIndex { $0.id == selectedHit?.id } ?? 0
        highlighted = hits[min(max(index + offset, 0), hits.count - 1)].id
    }

    private func openHighlighted() {
        if let selectedHit { open(selectedHit) }
    }

    private func open(_ hit: SearchHit) {
        navigation.searchReturn = SearchReturnState(
            text: text, scope: scope, kind: kind, fileType: fileType, selectedID: hit.id,
            visibleCount: visibleCount, localHits: localHits, onlineHits: onlineHits, onlineSummary: onlineSummary,
            expandedDocuments: expandedDocuments,
            previousSelection: model.selection, previousFile: model.viewerItem,
            courseTabs: navigation.courseTabs, expandedCourses: navigation.expandedCourses
        )
        close()
        navigation.searchTarget = hit
        if let course = hit.courseId {
            if hit.kind == .plan { navigation.courseTabs[course] = .plans }
            if hit.kind == .announcement { navigation.courseTabs[course] = .updates }
            if hit.resource?.isFolder == true { navigation.courseTabs[course] = .materials }
        }
        model.open(hit)
    }

    private func close() {
        navigation.restoresSearch = false
        navigation.isPaletteOpen = false
    }

    /// A second line that adds to the title, or nothing.
    private func subtitle(for hit: SearchHit) -> String? {
        var parts: [String] = []
        switch hit.kind {
        case .event:
            if let date = hit.date { parts.append(StudyDates.relative(date)) }
            // The course dot and title row already name the course; only add detail that says more.
            if let detail = hit.detail, !detail.isEmpty, !Self.sameText(detail, courseTitle(hit.courseId)), !Self.sameText(detail, hit.title) {
                parts.append(detail)
            }
        case .task:
            if let detail = hit.detail ?? courseTitle(hit.courseId), !detail.isEmpty { parts.append(detail) }
            if let date = hit.date { parts.append(StudyDates.relative(date)) }
        case .material:
            if let position = hit.document {
                if let page = position.page { parts.append("Page \(page + 1)") }
                parts.append("Saved copy")
                if position.recognizedText == true { parts.append("OCR · may contain errors") }
            }
            if let detail = hit.detail ?? courseTitle(hit.courseId), !detail.isEmpty {
                parts.append(detail.replacingOccurrences(of: " / ", with: " › ").replacingOccurrences(of: ", ", with: " › "))
            }
        default:
            if let detail = hit.detail ?? courseTitle(hit.courseId), !detail.isEmpty { parts.append(detail) }
        }
        let line = parts.joined(separator: " · ")
        return line.isEmpty || Self.sameText(line, hit.title) ? nil : line
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
        case .task: "Tasks"
        case .message: "Messages"
        case .event: "Events"
        case .announcement: "Announcements"
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
                        if let course = hit.courseId {
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
            if let type = hit.fileExtension {
                Text(type.uppercased())
                    .font(Type.t11)
                    .foregroundStyle(Color.textMuted)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
