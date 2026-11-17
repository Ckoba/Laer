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
        ZStack(alignment: .top) {
            Color.scrim
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
            }
            .frame(width: Size.palette)
            .background(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous).fill(Color.raised))
            .overlay(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous).strokeBorder(Color.borderStrong, lineWidth: 1))
            .floatShadow()
            .padding(.top, 72)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Search")
            .accessibilityIdentifier("palette")
        }
        // Focus after the overlay is in the window, or the field never takes it.
        .task {
            try? await Task.sleep(for: .milliseconds(50))
            isFieldFocused = true
        }
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

    private var filters: some View {
        HStack(spacing: Space.s4) {
            Chip("Everywhere", isSelected: scope == .everywhere) { scope = .everywhere }
            Chip("Active courses", isSelected: scope == .active) { scope = .active }
            if currentCourseId != nil {
                Chip("This course", isSelected: scope == .course) { scope = .course }
            }
            Rectangle().fill(Color.border).frame(width: 1, height: Space.s12)
                .padding(.horizontal, Space.s4)
            Menu {
                Button("Everything") { kind = nil }
                Divider()
                ForEach(SearchKind.allCases, id: \.self) { item in
                    Button(Self.title(for: item)) { kind = item }
                }
            } label: {
                Text(kind.map(Self.title(for:)) ?? "Everything").font(Type.t11)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Kind")
            Menu {
                Button("Any file type") { fileType = nil }
                Divider()
                ForEach(Self.fileTypes, id: \.self) { type in
                    Button(type.uppercased()) { fileType = type; kind = .material }
                }
            } label: {
                Text(fileType?.uppercased() ?? "Any file type").font(Type.t11)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("File type")
            Spacer(minLength: 0)
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
                        RowButton(selected: index == highlighted, action: { open(hit) }) {
                            HitRow(hit: hit, courseTitle: courseTitle(hit.courseId))
                        }
                        .id(index)
                        .onHover { if $0 { highlighted = index } }
                    }
                }
                .padding(Space.s4)
            }
            .frame(maxHeight: 400)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: highlighted) { _, index in proxy.scrollTo(index) }
        }
    }

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
        hits = Array(found.prefix(60))
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

    private func courseTitle(_ id: Int?) -> String? {
        guard let id else { return nil }
        return model.courses.first { $0.courseId == id }?.shortTitle
    }

    static func title(for kind: SearchKind) -> String {
        switch kind {
        case .course: "Courses"
        case .plan: "Plans"
        case .material: "Materials"
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
    let courseTitle: String?

    var body: some View {
        HStack(spacing: Space.s8) {
            Image(systemName: hit.resource?.isFolder == true ? Symbol.folder : CommandPalette.symbol(for: hit.kind))
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.textMuted)
                .frame(width: Size.icon)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.s2) {
                Text(hit.title)
                    .font(Type.t13)
                    .foregroundStyle(Color.text)
                    .lineLimit(1)
                if let detail = hit.detail ?? courseTitle, !detail.isEmpty {
                    Text(detail)
                        .font(Type.t11)
                        .foregroundStyle(Color.textMuted)
                        .lineLimit(1)
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
