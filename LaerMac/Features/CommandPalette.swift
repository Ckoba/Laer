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
    @State private var hits: [SearchHit] = []
    @State private var highlighted = 0
    @State private var hasSearched = false
    @State private var contentHeight: CGFloat = 0
    @FocusState private var isFieldFocused: Bool

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
        var scope: ScopeChoice
        var kind: SearchKind?
        var fileType: String?
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
                if !hits.isEmpty {
                    Rectangle().fill(Color.border).frame(height: 1)
                    HStack {
                        Text(hits.count == 1 ? "1 result" : contentHeight > Self.maxResultsHeight ? "\(hits.count) results, scroll for more" : "\(hits.count) results")
                        Spacer(minLength: Space.s8)
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
        .task(id: Query(text: text, scope: scope, kind: kind, fileType: fileType)) { await runSearch() }
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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if hits.isEmpty {
                        EmptyLine(emptyText)
                            .padding(Space.s8)
                    }
                    ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                        if index == 0 || Self.group(hits[index - 1]) != Self.group(hit) {
                            Text(Self.section(for: hit))
                                .font(Type.section)
                                .foregroundStyle(Color.textMuted)
                                .padding(.horizontal, Space.s8)
                                .padding(.top, index == 0 ? Space.s4 : Space.s12)
                                .padding(.bottom, Space.s4)
                                .accessibilityAddTraits(.isHeader)
                        }
                        RowButton(selected: index == highlighted, action: { open(hit) }) {
                            HitRow(hit: hit, subtitle: subtitle(for: hit))
                        }
                        .overlay {
                            if index == highlighted {
                                RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                                    .fill(Color.accent.opacity(0.15))
                                    .allowsHitTesting(false)
                            }
                        }
                        .id(index)
                        .onHover { if $0 { highlighted = index } }
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
            .onChange(of: highlighted) { _, index in proxy.scrollTo(index) }
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
        if text.trimmingCharacters(in: .whitespaces).isEmpty { return "Type to search" }
        return hasSearched ? "Nothing matches" : ""
    }

    private func runSearch() async {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            hits = []
            hasSearched = false
            return
        }
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        let kinds: Set<SearchKind> = kind.map { [$0] } ?? Set(SearchKind.allCases)
        let found = await model.search(query, scope: searchScope, kinds: kinds, fileExtension: fileType)
        guard !Task.isCancelled else { return }
        hits = Array(arrange(found).prefix(60))
        highlighted = 0
        hasSearched = true
    }

    private func move(_ offset: Int) {
        guard !hits.isEmpty else { return }
        highlighted = min(max(highlighted + offset, 0), hits.count - 1)
    }

    private func openHighlighted() {
        guard hits.indices.contains(highlighted) else { return }
        open(hits[highlighted])
    }

    private func open(_ hit: SearchHit) {
        close()
        if hit.kind == .plan, let course = hit.courseId { navigation.courseTabs[course] = .plans }
        model.open(hit)
    }

    private func close() {
        navigation.isPaletteOpen = false
    }

    /// Deduplicates indexed records by identity, then groups by kind, courses first.
    private func arrange(_ found: [SearchHit]) -> [SearchHit] {
        var seen = Set<String>()
        // A class with no time says nothing its course row does not.
        let unique = found.filter { hit in
            (hit.kind != .event || hit.date != nil) && seen.insert(hit.id).inserted
        }
        let order = Self.sectionOrder
        let needle = text.trimmingCharacters(in: .whitespaces)
        // A title that holds the query beats a hit that only inherits it from its course.
        func direct(_ hit: SearchHit) -> Bool {
            needle.isEmpty || hit.title.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        return unique.enumerated().sorted { a, b in
            let ka = order.firstIndex(of: Self.group(a.element)) ?? order.count
            let kb = order.firstIndex(of: Self.group(b.element)) ?? order.count
            if ka != kb { return ka < kb }
            let da = direct(a.element), db = direct(b.element)
            return da == db ? a.offset < b.offset : da
        }.map(\.element)
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

    /// Result groups: a link is not a file, so it gets a group of its own.
    enum Group: Hashable { case course, event, material, link, plan, task, message }

    private static let sectionOrder: [Group] = [.course, .event, .material, .link, .plan, .task, .message]

    static func isLink(_ hit: SearchHit) -> Bool {
        guard hit.kind == .material, let resource = hit.resource, !resource.isFolder else { return false }
        return resource.learningObjectId == nil && resource.learningObjectInstanceId == nil && hit.fileExtension == nil
    }

    static func group(_ hit: SearchHit) -> Group {
        if isLink(hit) { return .link }
        return switch hit.kind {
        case .course: .course
        case .event: .event
        case .material: .material
        case .plan: .plan
        case .task: .task
        case .message: .message
        }
    }

    static func section(for hit: SearchHit) -> String {
        if isLink(hit) { return "Links" }
        return section(for: hit.kind)
    }

    static func section(for kind: SearchKind) -> String {
        kind == .event ? "Classes" : title(for: kind)
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
        }
    }
}

private struct HitRow: View {
    let hit: SearchHit
    let subtitle: String?

    /// Folders, links (no file behind them) and files each get their own icon, as in Files.
    private var symbol: String {
        guard hit.kind == .material, let resource = hit.resource else { return CommandPalette.symbol(for: hit.kind) }
        if resource.isFolder { return Symbol.folder }
        if CommandPalette.isLink(hit) { return Symbol.link }
        let ext = hit.fileExtension ?? (hit.title as NSString).pathExtension
        return Symbol.file(extension: ext)
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
