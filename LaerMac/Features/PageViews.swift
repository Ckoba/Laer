import LaerCore
import SwiftUI

/// A course's participants, grouped by role.
struct ParticipantsView: View {
    @Environment(AppModel.self) private var model
    @State private var loader: CollectionLoader<Participant>

    init(course: Course) {
        let courseId = course.courseId
        _loader = State(initialValue: CollectionLoader(key: "participants-\(courseId)") { client in
            try await client.participants(courseId: courseId)
        })
    }

    var body: some View {
        PageScroll {
            FreshnessLine(state: loader.state)
            if loader.records.isEmpty {
                EmptyState(state: loader.state, empty: "No participants")
            }
            ForEach(groups, id: \.role) { group in
                Text(group.role)
                    .font(Type.t12)
                    .foregroundStyle(Color.textMuted)
                    .padding(.top, Space.s16)
                    .accessibilityAddTraits(.isHeader)
                ForEach(group.people) { person in
                    Text(person.fullName ?? "Unknown name")
                        .font(Type.t13)
                        .foregroundStyle(Color.text)
                        .lineLimit(1)
                        .plainRow()
                }
            }
        }
        .task { await loader.load(using: model) }
        .focusedSceneValue(\.refreshCurrent, RefreshAction { await loader.refresh(using: model) })
    }

    private var groups: [(role: String, people: [Participant])] {
        let grouped = Dictionary(grouping: loader.records) { $0.role.flatMap { $0.isEmpty ? nil : $0 } ?? "Other" }
        return grouped.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { role in
            (role, grouped[role]!.sorted { ($0.fullName ?? "").localizedStandardCompare($1.fullName ?? "") == .orderedAscending })
        }
    }
}

/// A material rendered natively from its content blocks. Shown in place of the materials list.
struct PageReaderView: View {
    @Environment(AppModel.self) private var model
    let resource: Resource
    let onClose: () -> Void
    @State private var loader: CollectionLoader<PageContent>

    init(resource: Resource, onClose: @escaping () -> Void) {
        self.resource = resource
        self.onClose = onClose
        let elementId = resource.elementId
        _loader = State(initialValue: CollectionLoader(key: "page-\(elementId)") { client in
            PagedResult(items: [try await client.page(elementId: elementId)], isComplete: true)
        })
    }

    var body: some View {
        PageScroll {
            HStack(spacing: Space.s6) {
                IconButton(Symbol.back, label: "Back", action: onClose)
                    .keyboardShortcut("[", modifiers: .command)
                Spacer(minLength: Space.s8)
                if let url = model.absoluteURL(resource.url) {
                    IconButton(Symbol.open, label: "Open on the website") { NSWorkspace.shared.open(url) }
                }
            }
            PageHeader(title: loader.records.first?.title ?? resource.title)
                .padding(.vertical, Space.s8)
            FreshnessLine(state: loader.state)
            if let page = loader.records.first {
                let blocks = page.orderedBlocks
                if blocks.isEmpty {
                    EmptyLine("This page is empty")
                }
                ForEach(blocks) { block in
                    ContentBlockView(block: block)
                }
            } else {
                EmptyState(state: loader.state, empty: "This page is empty")
            }
        }
        .task { await loader.load(using: model) }
        .focusedSceneValue(\.refreshCurrent, RefreshAction { await loader.refresh(using: model) })
    }
}

private struct ContentBlockView: View {
    @Environment(AppModel.self) private var model
    let block: ContentBlock

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            if let title = block.title, !title.isEmpty {
                Text(title)
                    .font(Type.t15)
                    .foregroundStyle(Color.text)
                    .accessibilityAddTraits(.isHeader)
            }
            if let html = block.html, !html.isEmpty {
                RichTextView(html: html)
            }
            ForEach(Array((block.files ?? []).enumerated()), id: \.offset) { _, file in
                HStack(spacing: Space.s6) {
                    Image(systemName: Symbol.material)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color.textMuted)
                        .accessibilityHidden(true)
                    Text(file.name ?? "File")
                        .font(Type.t13)
                        .foregroundStyle(Color.text)
                        .lineLimit(1)
                    if let size = file.size {
                        Text(size.formatted(.byteCount(style: .file)))
                            .font(Type.t11)
                            .foregroundStyle(Color.textMuted)
                    }
                    Spacer(minLength: Space.s8)
                    if let url = model.absoluteURL(file.url) {
                        IconButton(Symbol.open, label: "Open on the website") { NSWorkspace.shared.open(url) }
                    }
                }
                .plainRow()
            }
        }
        .padding(.vertical, Space.s8)
    }
}
