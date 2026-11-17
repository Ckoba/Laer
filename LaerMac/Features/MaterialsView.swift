import AppKit
import LaerCore
import SwiftUI

/// Folder-by-folder browsing. A listing covers its folder, not the whole course.
struct MaterialsView: View {
    @Environment(AppModel.self) private var model
    let course: Course
    @State private var path: [Resource] = []
    @State private var reading: Resource?

    private var folderId: Int? { path.last?.elementId }
    private var key: String { AppModel.folderKey(courseId: course.courseId, folderId: folderId) }

    var body: some View {
        if let reading {
            PageReaderView(resource: reading) { self.reading = nil }
        } else {
            list
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

    var body: some View {
        HStack(spacing: Space.s8) {
            Image(systemName: resource.isFolder ? Symbol.folder : Symbol.material)
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
                } else if isSaved {
                    Text("Saved")
                        .font(Type.t11)
                        .foregroundStyle(Color.textMuted)
                }
            }
            Spacer(minLength: Space.s8)
            actions
        }
        .laerRow()
        .onTapGesture { primaryAction() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { primaryAction() }
        .contextMenu { menu }
    }

    @ViewBuilder private var actions: some View {
        if resource.isFolder {
            Image(systemName: Symbol.disclosure)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color.textMuted)
                .accessibilityHidden(true)
        } else if model.downloadStates[resource.id] == .downloading {
            Spinner()
        } else if isSaved {
            IconButton(Symbol.open, label: "Open") { Task { await openSaved() } }
        } else if FileAcquirer.canAttempt(resource) {
            IconButton(Symbol.save, label: "Save") { Task { await model.download(resource) } }
        } else if canRead {
            Image(systemName: Symbol.disclosure)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color.textMuted)
                .accessibilityHidden(true)
        } else if let url = originalURL {
            IconButton(Symbol.open, label: "Open on the website") { NSWorkspace.shared.open(url) }
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
        if resource.isFolder {
            onOpenFolder()
        } else if isSaved {
            Task { await openSaved() }
        } else if FileAcquirer.canAttempt(resource), model.downloadStates[resource.id] != .downloading {
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
