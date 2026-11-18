import AppKit
import LaerCore
import SwiftUI

/// Folder-by-folder browsing. A listing covers its folder, not the whole course.
struct MaterialsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigation.self) private var navigation
    let course: Course
    @State private var path: [Resource] = []
    @State private var reading: Resource?

    private var folderId: Int? { path.last?.elementId }
    private var key: String { AppModel.folderKey(courseId: course.courseId, folderId: folderId) }

    var body: some View {
        Group {
            if let reading {
                PageReaderView(resource: reading) { self.reading = nil }
            } else {
                list
            }
        }
        .task(id: navigation.searchTarget?.id) {
            guard case .folder(let id, _, _) = navigation.searchTarget?.destination,
                  id == course.courseId, let folder = navigation.searchTarget?.resource else { return }
            reading = nil
            path = [folder]
        }
    }

    @ViewBuilder private var list: some View {
        let items = model.resources[key] ?? []
        let state = model.resourcesState[key] ?? CollectionState()
        PageScroll(spacing: 0, lazy: true) {
            if !path.isEmpty {
                HStack(spacing: Space.s6) {
                    IconButton(Symbol.back, label: "Back") { path.removeLast() }
                        .keyboardShortcut("[", modifiers: .command)
                    Text(path.map(\.title).joined(separator: " / "))
                        .font(Type.t12)
                        .foregroundStyle(Color.textMuted)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .padding(.bottom, Space.s4)
            }
            FreshnessLine(state: state)
            if items.isEmpty {
                EmptyState(state: state, empty: "This folder is empty")
            }
            ForEach(items) { resource in
                ResourceRow(
                    resource: resource,
                    onOpenFolder: { path.append(resource) },
                    onRead: { reading = resource })
                .environment(\.rowDividerHidden, resource.id == items.last?.id)
                // Row text starts at the page's inset, like the title: rows reach 8pt into the gutter,
                // so the hairline and the selected fill share the row's edges as they do in Plans.
                .padding(.horizontal, -Space.s8)
            }
        }
        .dividedRows()
        .task(id: key) { await model.loadFolder(courseId: course.courseId, folderId: folderId) }
    }
}

struct ResourceRow: View {
    @Environment(AppModel.self) private var model
    let resource: Resource
    let onOpenFolder: () -> Void
    let onRead: () -> Void

    /// Items that are not files may be pages; the reader falls back to the website if not.
    private var canRead: Bool {
        ParityGate.pages && !resource.isFolder && !FileAcquirer.canAttempt(resource)
    }

    private var isSaved: Bool { model.savedAssets[resource.id] != nil }

    @State private var isHovered = false

    /// A downloadable file, as opposed to a page or link that only opens in the reader or on the website.
    private var isFile: Bool {
        guard FileAcquirer.canAttempt(resource) else { return false }
        if resource.learningObjectId != nil || resource.learningObjectInstanceId != nil { return true }
        let ext = (resource.title as NSString).pathExtension
        return !ext.isEmpty && ext.count <= 5 && !ext.contains(" ")
    }

    private var sizeLabel: String? {
        guard let asset = model.savedAssets[resource.id], asset.byteCount > 0 else { return nil }
        return asset.byteCount.formatted(.byteCount(style: .file))
    }

    /// A folder glyph for folders, a link glyph for web items, and the shared per-type file glyph
    /// that Home, Plans, Search and the viewer tabs use for everything else.
    private var rowSymbol: String {
        if resource.isFolder { return Symbol.folder }
        return isFile || isSaved ? Symbol.file(extension: (resource.title as NSString).pathExtension) : Symbol.link
    }

    var body: some View {
        HStack(spacing: Space.s8) {
            Image(systemName: rowSymbol)
                .font(.system(size: 13, weight: .regular))
                .frame(width: Size.icon, height: Size.icon)
                .foregroundStyle(Color.textMuted)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.s2) {
                Text(resource.title)
                    .font(Type.t13)
                    .foregroundStyle(Color.text)
                    .lineLimit(2)
                if case .failed(let message) = model.downloadStates[resource.id] {
                    ErrorLine(message)
                }
            }
            Spacer(minLength: Space.s8)
            actions
                .frame(width: Size.icon, alignment: .center)
            // Every row opens something, so every row carries the chevron.
            RowTrailing(date: nil, chevron: true)
        }
        .laerRow(selected: model.viewerItem?.id == resource.id)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { primaryAction() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { primaryAction() }
        .contextMenu { menu }
    }

    @ViewBuilder private var actions: some View {
        if resource.isFolder {
            EmptyView()
        } else if model.downloadStates[resource.id] == .downloading {
            Spinner()
        } else if isSaved {
            Image(systemName: Symbol.saved)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color.textMuted)
                .accessibilityLabel("Downloaded")
                .help("Downloaded")
        } else if isFile, isHovered {
            IconButton(Symbol.save, label: "Download") { Task { await model.download(resource) } }
        }
    }

    @ViewBuilder private var menu: some View {
        if let asset = model.savedAssets[resource.id] {
            Button("Open") { Task { await openSaved() } }
            Button("Open in default app") {
                Task {
                    if let url = await model.savedFileURL(for: resource) { NSWorkspace.shared.open(url) }
                }
            }
            Button("Show in Finder") {
                Task {
                    if let url = await model.savedFileURL(for: resource) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
            Button("Export…") { Task { await export(asset) } }
            Button("Save newer copy") { Task { await model.download(resource) } }
        } else if FileAcquirer.canAttempt(resource) {
            Button("Save") { Task { await model.download(resource) } }
        } else if canRead {
            Button("Open", action: onRead)
        }
        if let url = originalURL {
            Button("Open on the website") { NSWorkspace.shared.open(url) }
        }
        if isSaved {
            Divider()
            Button("Remove saved copy", role: .destructive) { Task { await model.removeSavedFile(resource) } }
        }
    }

    private var originalURL: URL? {
        model.absoluteURL(resource.url) ?? model.absoluteURL(resource.contentUrl)
    }

    private func primaryAction() {
        guard model.downloadStates[resource.id] != .downloading else { return }
        if resource.isFolder {
            onOpenFolder()
        } else if isSaved {
            Task { await openSaved() }
        } else if FileAcquirer.canAttempt(resource) {
            Task {
                await model.download(resource)
                if model.savedAssets[resource.id] != nil {
                    await openSaved()
                } else if ParityGate.pages {
                    // Not a file: it may be a page, which reads natively. The reader falls back to the website.
                    model.clearDownloadState(resource)
                    onRead()
                }
            }
        } else if canRead {
            onRead()
        } else if let url = originalURL {
            NSWorkspace.shared.open(url)
        }
    }

    private func openSaved() async {
        // Only bytes on disk open here, in the right panel. A missing file clears the saved mark through the store.
        await model.open(resource)
    }

    private func export(_ asset: LocalAsset) async {
        guard let source = await model.savedFileURL(for: resource) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = asset.displayName
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: source, to: destination)
    }
}
