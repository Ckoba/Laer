import AppKit
import LaerCore
import PDFKit
import Quartz
import SwiftUI

/// The screen beside the file panel. The panel grows over the screen but never over the sidebar,
/// which sits outside this view.
struct ViewerSplit<Detail: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder var detail: () -> Detail
    @State private var dragStartWidth: CGFloat?
    @State private var isOverHandle = false
    @State private var toggleCount = 0

    private let minPanel: CGFloat = 320
    /// Dragging within this distance of the far edge fills the space.
    private let snapToFull: CGFloat = 200

    var body: some View {
        let hasFile = model.viewerItem != nil
        let target: CGFloat = model.viewerIsFull ? 1 : 0
        ReaderExpansion(progress: target) { progress in
            GeometryReader { proxy in
                let total = proxy.size.width
                let split = splitPanelWidth(total: total)
                let expansion = dragStartWidth == nil ? progress : target
                let panel = hasFile ? split + (total - split) * expansion : 0
                let detailWidth = max(total - panel, 0)
                HStack(spacing: 0) {
                    detail()
                        .frame(width: detailWidth, alignment: .topLeading)
                        .clipped()
                        .contentShape(Rectangle())
                        .allowsHitTesting(detailWidth >= 1)
                        .accessibilityHidden(detailWidth < 1)
                    if hasFile {
                        FileViewerHost(onToggleFull: toggleFull)
                            .frame(width: panel)
                            .background(Color.stage)
                            .overlay(alignment: .leading) { resizeHandle(total: total, panel: panel) }
                            .clipped()
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .transaction(value: progress) { transaction in
                    // The pane widths already describe this animation frame.
                    if hasFile { transaction.animation = nil }
                }
            }
        }
        // Pair the reader's motion with the sidebar collapsing or opening alongside it.
        .motion(model.viewerIsFull ? Motion.sidebarCollapse : Motion.sidebarExpand, value: toggleCount)
        .transaction(value: model.viewerIsFull) { transaction in
            // Drag snaps update the reader immediately, even while the sidebar animates.
            if hasFile { transaction.animation = nil }
        }
    }

    private func toggleFull() {
        toggleCount += 1
        model.viewerIsFull.toggle()
    }

    private func splitPanelWidth(total: CGFloat) -> CGFloat {
        let minimum = min(minPanel, total)
        let maximum = max(minimum, total - snapToFull)
        return min(max(model.viewerWidth ?? total * 0.62, minimum), maximum)
    }

    private func resizeHandle(total: CGFloat, panel: CGFloat) -> some View {
        // The line sits on the panel's own leading edge, so the strip and the page share it. No line when
        // the file fills the window; the drag still works over the same 10pt.
        Color.clear
            .frame(width: 10)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(total - panel < 1 ? Color.clear : (isOverHandle ? Color.borderStrong : Color.border))
                    .frame(width: 1)
            }
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Color.textFaint)
                    .frame(width: 3, height: 36)
                    .padding(.leading, Space.s2)
                    .opacity(isOverHandle ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    NSCursor.resizeLeftRight.set()
                    isOverHandle = true
                case .ended:
                    NSCursor.arrow.set()
                    isOverHandle = false
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartWidth ?? panel
                        dragStartWidth = start
                        let width = start - value.translation.width
                        let isFull = total - width < snapToFull
                        if !isFull { model.viewerWidth = width }
                        model.viewerIsFull = isFull
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
            .help("Drag the divider to resize the reader")
            .accessibilityLabel("Resize file panel")
    }
}

/// Samples the reader's expansion independently of the available width, which the sidebar can change.
private struct ReaderExpansion<Content: View>: View, Animatable {
    nonisolated var progress: CGFloat
    @ViewBuilder var content: (CGFloat) -> Content

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        content(min(max(progress, 0), 1))
    }
}

/// Tabs for open files, one menu, and Close.
struct FileViewerHost: View {
    @Environment(AppModel.self) private var model
    let onToggleFull: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.s4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.s4) {
                        ForEach(model.viewerTabs) { item in
                            FileTab(item: item)
                        }
                        IconButton(Symbol.newTab, label: "New tab", help: "Open a new tab to find another file") { model.openNewTab() }
                            .accessibilityIdentifier("viewer.newTab")
                    }
                }
                IconButton(
                    model.viewerIsFull ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    label: model.viewerIsFull ? "Restore split view" : "Expand reader",
                    action: onToggleFull
                )
                    .help(model.viewerIsFull ? "Restore side-by-side view" : "Expand reader. You can also drag the divider left.")
                    .accessibilityIdentifier("viewer.toggleFull")
                if let item = model.viewerItem, item.fileURL != nil {
                    FileMenu(item: item, onToggleFull: onToggleFull)
                }
                // Tab closes are the small x on each tab; this one closes the whole reader.
                IconButton(Symbol.close, label: "Close file", help: "Close reader") { model.closeViewer() }
            }
            .padding(.horizontal, Space.s8)
            .frame(height: 44)
            ZStack {
                // Open tabs stay alive, so each keeps its page and zoom.
                ForEach(model.viewerTabs) { item in
                    let isCurrent = item.id == model.viewerItem?.id
                    FileContent(item: item, isCurrent: isCurrent)
                        .opacity(isCurrent ? 1 : 0)
                        .allowsHitTesting(isCurrent)
                }
            }
        }
    }
}

private struct FileTab: View {
    @Environment(AppModel.self) private var model
    let item: ViewerItem
    @State private var isHovering = false
    @State private var showsInfo = false
    @State private var hoverTask: Task<Void, Never>?

    private var isCurrent: Bool { item.id == model.viewerItem?.id }
    private var hasSiblings: Bool { model.viewerTabs.count > 1 }

    var body: some View {
        HStack(spacing: Space.s6) {
            Image(systemName: item.isNewTab ? Symbol.newTab : Symbol.file(extension: (item.title as NSString).pathExtension))
                .font(.system(size: 12))
                .foregroundStyle(Color.textMuted)
            Text(item.title)
                .font(Type.t12)
                .foregroundStyle(isCurrent ? Color.text : Color.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 150, alignment: .leading)
            Button {
                model.closeTab(item)
            } label: {
                Image(systemName: Symbol.close)
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: hasSiblings ? 16 : 0, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // With one tab the hidden ✕ takes no room, but stays in the accessibility tree.
            .padding(.leading, hasSiblings ? 0 : -Space.s6)
            .foregroundStyle(Color.textMuted)
            // With one tab open the reader's own Close is the only ✕; this one stays for assistive tech.
            .opacity(hasSiblings && (isCurrent || isHovering) ? 1 : 0)
            .allowsHitTesting(hasSiblings)
            .help("Close tab")
            .accessibilityLabel("Close \(item.title)")
        }
        .padding(.leading, Space.s8)
        .padding(.trailing, hasSiblings ? Space.s4 : Space.s8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                .fill(isCurrent ? Color.selected : (isHovering ? Color.hover : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture { model.viewerItem = item }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .onHover { inside in
            isHovering = inside
            hoverTask?.cancel()
            if inside, !item.isNewTab {
                hoverTask = Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    if !Task.isCancelled { showsInfo = true }
                }
            } else {
                showsInfo = false
            }
        }
        .popover(isPresented: $showsInfo, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Space.s4) {
                Text(item.title)
                    .font(Type.t13)
                    .foregroundStyle(Color.text)
                Text(item.typeAndSize)
                    .font(Type.t12)
                    .foregroundStyle(Color.textMuted)
            }
            .padding(Space.s12)
            .frame(maxWidth: 320, alignment: .leading)
        }
    }
}

/// Everything except Close lives here.
private struct FileMenu: View {
    @Environment(AppModel.self) private var model
    let item: ViewerItem
    let onToggleFull: () -> Void

    private var source: URL { model.shownURL(for: item) ?? URL(fileURLWithPath: "/") }
    private var converted: URL? { model.convertedFiles[item.id] }
    private var showsOriginal: Bool { model.officeFilesShownAsOriginal.contains(item.id) }

    var body: some View {
        Menu {
            Button(model.viewerIsFull ? "Exit full size" : "Full size", action: onToggleFull)
                .keyboardShortcut("f", modifiers: [.shift, .command])
            if item.supportsPDFConversion, converted != nil {
                Button(showsOriginal ? "View as PDF" : (item.isWord ? "View as Word" : "View as PowerPoint")) {
                    if showsOriginal {
                        model.officeFilesShownAsOriginal.remove(item.id)
                    } else {
                        model.officeFilesShownAsOriginal.insert(item.id)
                    }
                }
            }
            Divider()
            Button("Copy file") {
                guard let named = ViewerFiles.namedCopy(of: source, title: item.title) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([named as NSURL])
            }
            Button("Show in Finder") {
                guard let named = ViewerFiles.namedCopy(of: source, title: item.title) else { return }
                NSWorkspace.shared.activateFileViewerSelecting([named])
            }
            // Only known document and media formats open directly; anything else is shown in Finder.
            if let original = item.fileURL, DownloadStore.canOpenDirectlyInDefaultApp(pathExtension: original.pathExtension) {
                Button("Open in default app") {
                    guard let named = ViewerFiles.namedCopy(of: original, title: item.title) else { return }
                    NSWorkspace.shared.open(named)
                }
            }
            Button("Export…") { export() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13))
                .foregroundStyle(Color.textMuted)
                .frame(width: Size.controlSmall, height: Size.controlSmall)
                .contentShape(Rectangle())
        }
        // A plain button menu keeps the label's own colour, so the dots match the icon buttons beside them.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .foregroundStyle(Color.textMuted)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("File actions")
        .help("File actions")
    }

    /// Office files with a PDF copy ask which to save, starting from the one on screen.
    private func export() {
        let panel = NSSavePanel()
        let base = (item.title as NSString).deletingPathExtension
        let name = base.isEmpty ? item.title : base
        var choices = [source]
        if item.supportsPDFConversion, let converted, let original = item.fileURL {
            choices = showsOriginal ? [original, converted] : [converted, original]
        }
        let picker = ExportFormatPicker(panel: panel, name: name, choices: choices)
        panel.nameFieldStringValue = "\(name).\(choices[0].pathExtension)"
        if choices.count > 1 { panel.accessoryView = picker.view }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        // Turned pages leave the app as they look on screen.
        let selected = picker.selected
        if selected.pathExtension.lowercased() == "pdf", let rotated = PDFControllers.rotatedDocument(selected) {
            Task { await FileExport.write(rotated, from: selected, to: destination) }
        } else {
            Task { await FileExport.copy(selected, to: destination) }
        }
    }
}

extension AppModel {
    /// The converted PDF unless the person chose to view the original.
    func shownURL(for item: ViewerItem) -> URL? {
        if officeFilesShownAsOriginal.contains(item.id) { return item.fileURL }
        return convertedFiles[item.id] ?? item.fileURL
    }

    /// The PDF page in view for a file the reader has loaded, zero-based, so history can return to it.
    func viewerPage(for item: ViewerItem) -> Int? {
        guard let url = shownURL(for: item), let controller = PDFControllers.controller(for: url),
              controller.pageCount > 0 else { return nil }
        return controller.pageIndex
    }
}

/// The format menu under the save panel's name field. Picking one swaps the name's extension.
@MainActor
private final class ExportFormatPicker: NSObject {
    let view: NSView
    private let popup: NSPopUpButton
    private let choices: [URL]
    private weak var panel: NSSavePanel?
    private let name: String

    var selected: URL { choices[max(popup.indexOfSelectedItem, 0)] }

    init(panel: NSSavePanel, name: String, choices: [URL]) {
        self.panel = panel
        self.name = name
        self.choices = choices
        popup = NSPopUpButton(frame: .zero, pullsDown: false)
        let label = NSTextField(labelWithString: "Format:")
        let stack = NSStackView(views: [label, popup])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        view = stack
        super.init()
        for url in choices {
            let ext = url.pathExtension.lowercased()
            let label = if ext == "pdf" {
                "PDF"
            } else if ViewerItem.wordExtensions.contains(ext) {
                "Word (.\(ext))"
            } else {
                "PowerPoint (.\(ext))"
            }
            popup.addItem(withTitle: label)
        }
        popup.target = self
        popup.action = #selector(changed)
    }

    @objc private func changed() {
        panel?.nameFieldStringValue = "\(name).\(selected.pathExtension)"
    }
}

enum ViewerFiles {
    /// Named copies hold course files, so they don't outlive the account's session.
    @MainActor
    static func removeDerivedFiles() {
        OfficePDFConverter.removeCachedFiles()
        guard let caches = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return }
        for name in ["NamedFiles", "ConvertedSlides"] {
            try? FileManager.default.removeItem(at: caches.appending(path: name, directoryHint: .isDirectory))
        }
    }

    /// Saved files have opaque names on disk. Anything leaving the app gets its real name.
    static func namedCopy(of source: URL, title: String) -> URL? {
        guard let caches = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        let folder = caches.appending(path: "NamedFiles", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = (title as NSString).deletingPathExtension
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        // File systems cap names at 255 bytes, and course titles can run long.
        let short = String(base.prefix(120))
        let named = folder.appending(path: "\(short.isEmpty ? "File" : short).\(source.pathExtension)")
        try? FileManager.default.removeItem(at: named)
        do {
            try FileManager.default.copyItem(at: source, to: named)
            return named
        } catch {
            return nil
        }
    }
}

/// One open file. Office files use Quick Look if a PDF preview is unavailable.
private struct FileContent: View {
    @Environment(AppModel.self) private var model
    let item: ViewerItem
    let isCurrent: Bool
    @State private var conversion: OfficePDFConverter?
    @State private var conversionFailed = false

    private var displayURL: URL? { model.shownURL(for: item) }

    private var officePreview: OfficePDFConverter? {
        guard let conversion, conversion.source == item.fileURL, conversion.hasPreview,
              !model.officeFilesShownAsOriginal.contains(item.id) else { return nil }
        return conversion
    }

    var body: some View {
        Group {
            if item.isNewTab {
                NewTabPage()
            } else if displayURL?.pathExtension.lowercased() == "pdf" || officePreview != nil || item.firstPDFPage != nil {
                PDFPanel(url: displayURL, fileId: item.id, startPage: item.startPage,
                         searchMatch: item.searchMatch, isCurrent: isCurrent, office: officePreview,
                         firstPDFPage: item.firstPDFPage)
                    .id(item.openingID.map(AnyHashable.init) ?? AnyHashable(item.fileURL))
            } else if item.supportsPDFConversion,
                      !model.officeFilesShownAsOriginal.contains(item.id), !conversionFailed {
                Spinner().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let displayURL {
                QuickLookContent(url: displayURL)
            } else {
                Spinner()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: item.fileURL) { await convertIfNeeded() }
    }

    private func convertIfNeeded() async {
        conversionFailed = false
        guard item.supportsPDFConversion, let source = item.fileURL else { return }
        if let cached = OfficePDFConverter.cachedPDF(for: source, id: item.id) {
            model.convertedFiles[item.id] = cached
            return
        }
        let job = OfficePDFConverter.conversion(for: source, id: item.id)
        conversion = job
        let result = try? await job.result()
        guard !Task.isCancelled, conversion === job,
              model.viewerTabs.contains(where: { $0.id == item.id && $0.fileURL == source }) else { return }
        if let result {
            model.convertedFiles[item.id] = result
        } else {
            conversionFailed = true
        }
        conversion = nil
    }
}

private struct DocumentBox: @unchecked Sendable {
    let document: PDFDocument?
    init(_ document: PDFDocument?) { self.document = document }
}

/// Open PDF panels by the file they show, so the file menu can act on the visible document.
@MainActor
private enum PDFControllers {
    private final class Weak { weak var value: PDFController?; init(_ value: PDFController) { self.value = value } }
    private static var table: [URL: Weak] = [:]

    fileprivate static func register(_ controller: PDFController, for url: URL) {
        table = table.filter { $0.value.value != nil }
        table[url] = Weak(controller)
    }

    fileprivate static func controller(for url: URL) -> PDFController? { table[url]?.value }

    /// The document as rotated on screen, for exporting. Nil when nothing is rotated.
    static func rotatedDocument(_ url: URL) -> PDFDocument? {
        guard let controller = controller(for: url), controller.hasRotation else { return nil }
        return controller.view.document
    }
}

/// A PDF view whose right-click menu also rotates the page under the pointer or the whole file.
private final class LaerPDFView: PDFView {
    var onRotate: ((PDFPage?, Bool, Bool) -> Void)?
    var onReset: (() -> Void)?
    var allowsRotation = true

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard allowsRotation else { return menu }
        let page = self.page(for: convert(event.locationInWindow, from: nil), nearest: true)
        menu.addItem(.separator())
        for (title, all, clockwise) in [("Rotate Page Left", false, false), ("Rotate Page Right", false, true),
                                        ("Rotate All Pages Left", true, false), ("Rotate All Pages Right", true, true)] {
            let item = NSMenuItem(title: title, action: #selector(runMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = MenuAction { [weak self] in self?.onRotate?(all ? nil : page, all, clockwise) }
            menu.addItem(item)
        }
        let reset = NSMenuItem(title: "Reset Rotation", action: #selector(runMenuItem(_:)), keyEquivalent: "")
        reset.target = self
        reset.representedObject = MenuAction { [weak self] in self?.onReset?() }
        menu.addItem(reset)
        return menu
    }

    @objc private func runMenuItem(_ sender: NSMenuItem) { (sender.representedObject as? MenuAction)?.run() }

    private final class MenuAction {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }
}

/// Holds the PDF view, so the page and its thumbnails share one document.
@MainActor
private final class PDFController: ObservableObject {
    let view: LaerPDFView
    @Published private(set) var pageCount = 0
    @Published private(set) var pageIndex = 0
    /// Bumps when pages change so the thumbnails redraw.
    @Published private(set) var revision = 0
    @Published private(set) var allowsRotation = true {
        didSet { view.allowsRotation = allowsRotation }
    }
    private var observer: NSObjectProtocol?
    /// Quarter turns the person added, by page index, on top of the file's own rotation.
    private var added: [Int: Int] = [:]
    private let fileId: String
    private var hasCover = false
    private var showsDownloadPreview = false

    private static let rotationsKey = "viewerPageRotations"

    var hasRotation: Bool { added.values.contains { $0 % 360 != 0 } }

    init(fileId: String) {
        self.fileId = fileId
        let pdfView = LaerPDFView()
        view = pdfView
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        // A soft shadow and a 12pt gap separate the pages from the reading surface.
        view.pageShadowsEnabled = true
        view.pageBreakMargins = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        view.minScaleFactor = 0.25
        view.maxScaleFactor = 6
        view.backgroundColor = .clear
        observer = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePage() }
        }
        pdfView.onRotate = { [weak self] page, all, clockwise in
            guard let self else { return }
            self.rotate(pages: all ? nil : page.map { [$0] }, by: clockwise ? 90 : -90)
        }
        pdfView.onReset = { [weak self] in self?.resetRotation() }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Opening a large document can take a moment, so it happens away from the main thread.
    func load(_ url: URL) async {
        guard view.document == nil || showsDownloadPreview else { return }
        let box = await Task.detached(priority: .userInitiated) { DocumentBox(PDFDocument(url: url)) }.value
        guard !Task.isCancelled, let document = box.document else { return }
        if showsDownloadPreview, let preview = view.document?.page(at: 0), let first = document.page(at: 0) {
            let scale = view.scaleFactor
            let autoScales = view.autoScales
            keepingPlace(from: preview, to: first, in: document) {
                install(document)
                if !autoScales {
                    view.autoScales = false
                    view.scaleFactor = scale
                }
            }
            showsDownloadPreview = false
            allowsRotation = true
            revision += 1
        } else {
            install(document)
        }
        if pageCount > 0 { Perf.mark("PDF document loaded") }
    }

    func showDownloadPreview(_ data: Data) {
        guard view.document == nil, let document = PDFDocument(data: data), !document.isLocked,
              document.pageCount == 1, document.page(at: 0) != nil else { return }
        showsDownloadPreview = true
        allowsRotation = false
        install(document)
        Perf.mark("PDF first page usable")
    }

    func showPages(from office: OfficePDFConverter) {
        if allowsRotation != office.isFinished { allowsRotation = office.isFinished }

        let installed = view.document != nil
        let document = view.document ?? PDFDocument()
        if !installed, office.capturedPages.isEmpty,
           let bytes = office.coverPDF, let page = PDFDocument(data: bytes)?.page(at: 0) {
            document.insert(page, at: 0)
            hasCover = true
        }

        let replacedCover: Bool
        if hasCover, let bytes = office.capturedPages.first, let page = PDFDocument(data: bytes)?.page(at: 0) {
            replaceCover(with: page, in: document)
            hasCover = false
            replacedCover = true
        } else {
            replacedCover = false
        }

        for bytes in office.capturedPages.dropFirst(document.pageCount) {
            guard let page = PDFDocument(data: bytes)?.page(at: 0) else { break }
            if installed { applyRotation(to: page, at: document.pageCount) }
            document.insert(page, at: document.pageCount)
        }

        guard document.pageCount > 0 else { return }
        if !installed {
            install(document)
            Perf.mark("office first PDF page usable")
        } else if pageCount != document.pageCount || replacedCover {
            if pageCount != document.pageCount { view.layoutDocumentView() }
            pageCount = document.pageCount
            revision += 1
        }
    }

    private func replaceCover(with page: PDFPage, in document: PDFDocument) {
        guard let cover = document.page(at: 0) else { return }
        keepingPlace(from: cover, to: page, in: document) {
            document.removePage(at: 0)
            applyRotation(to: page, at: 0)
            document.insert(page, at: 0)
            view.layoutDocumentView()
        }
    }

    /// A stand-in first page gives way to the real one where the reader was, with their selection.
    private func keepingPlace(from old: PDFPage, to new: PDFPage, in document: PDFDocument, _ swap: () -> Void) {
        let viewport = view.currentDestination?.point
        let selected = selection(on: old)
        swap()
        if let viewport { view.go(to: PDFDestination(page: new, at: viewport)) }
        restoreSelection(selected, on: new, in: document)
    }

    private func selection(on page: PDFPage) -> (text: String, ranges: [NSRange])? {
        guard let selection = view.currentSelection, let text = selection.string else { return nil }
        let ranges = (0..<selection.numberOfTextRanges(on: page)).map { selection.range(at: $0, on: page) }
        return (text, ranges)
    }

    private func restoreSelection(_ selected: (text: String, ranges: [NSRange])?, on page: PDFPage, in document: PDFDocument) {
        guard let selected, !selected.ranges.isEmpty else { return }
        let restored = PDFSelection(document: document)
        let pieces = selected.ranges.compactMap { range -> PDFSelection? in
            guard range.location != NSNotFound, NSMaxRange(range) <= page.numberOfCharacters else { return nil }
            return page.selection(for: range)
        }
        restored.add(pieces)
        if restored.string == selected.text {
            view.setCurrentSelection(restored, animate: false)
        }
    }

    private func install(_ document: PDFDocument) {
        added = Self.savedRotations(for: fileId)
        for index in added.keys where index < document.pageCount {
            if let page = document.page(at: index) { applyRotation(to: page, at: index) }
        }
        view.document = document
        for case let scroll as NSScrollView in view.subviews {
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = NSEdgeInsets()
        }
        pageCount = document.pageCount
        // Fit to the panel again now that the page size is known.
        refit()
    }

    private func applyRotation(to page: PDFPage, at index: Int) {
        if let turn = added[index] { page.rotation = Self.normalized(page.rotation + turn) }
    }

    /// Nil pages means every page. The page in view stays in view.
    func rotate(pages: [PDFPage]?, by degrees: Int) {
        guard allowsRotation, let document = view.document else { return }
        let targets = pages ?? (0..<document.pageCount).compactMap { document.page(at: $0) }
        let anchor = view.currentPage
        for page in targets {
            let index = document.index(for: page)
            page.rotation = Self.normalized(page.rotation + degrees)
            added[index] = Self.normalized((added[index] ?? 0) + degrees)
        }
        changed(anchor: anchor)
    }

    func resetRotation() {
        guard allowsRotation, let document = view.document, hasRotation else { return }
        let anchor = view.currentPage
        for (index, turn) in added {
            if let page = document.page(at: index) { page.rotation = Self.normalized(page.rotation - turn) }
        }
        added = [:]
        changed(anchor: anchor)
    }

    private func changed(anchor: PDFPage?) {
        Self.save(added, for: fileId)
        view.layoutDocumentView()
        refit()
        if let anchor { view.go(to: anchor) }
        revision += 1
    }

    func refitKeeping(pageAt index: Int) {
        if view.autoScales { refit() }
        go(toPage: index)
    }

    private func refit() {
        view.autoScales = false
        view.autoScales = true
    }

    private static func normalized(_ degrees: Int) -> Int { ((degrees % 360) + 360) % 360 }

    private static func savedRotations(for id: String) -> [Int: Int] {
        let all = UserDefaults.standard.dictionary(forKey: rotationsKey) as? [String: [String: Int]] ?? [:]
        return Dictionary((all[id] ?? [:]).compactMap { key, value in Int(key).map { ($0, value) } }) { first, _ in first }
    }

    private static func save(_ rotations: [Int: Int], for id: String) {
        var all = UserDefaults.standard.dictionary(forKey: rotationsKey) as? [String: [String: Int]] ?? [:]
        let kept = rotations.filter { $0.value != 0 }
        all[id] = kept.isEmpty ? nil : Dictionary(uniqueKeysWithValues: kept.map { (String($0.key), $0.value) })
        UserDefaults.standard.set(all, forKey: rotationsKey)
    }

    func go(toPage index: Int?) {
        guard let index, let page = view.document?.page(at: index) else { return }
        view.go(to: page)
    }

    func showSearchMatch(_ text: String?, onPage index: Int) {
        go(toPage: index)
        view.highlightedSelections = nil
        guard let text, !text.isEmpty, let page = view.document?.page(at: index), let contents = page.string else { return }
        let range = (contents as NSString).range(of: text)
        guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= page.numberOfCharacters,
              let selection = page.selection(for: range) else { return }
        selection.color = .systemYellow
        view.highlightedSelections = [selection]
        view.go(to: selection)
    }

    private func updatePage() {
        guard let page = view.currentPage, let document = view.document else { return }
        pageIndex = document.index(for: page)
    }
}

private final class MonitorHolder {
    var token: Any?
}

private struct PDFPanel: View {
    let url: URL?
    let startPage: Int?
    let searchMatch: String?
    let isCurrent: Bool
    let office: OfficePDFConverter?
    let firstPDFPage: Data?
    @StateObject private var controller: PDFController
    @State private var didOpenInitialPage = false
    @AppStorage("viewerPagesLocked") private var isLocked = false
    @State private var isOpen = false
    /// The page ticks show only while the pointer is over the document.
    @State private var isHovering = false
    @State private var frame: CGRect = .zero
    @State private var monitor = MonitorHolder()
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var closeTask: Task<Void, Never>?
    @State private var resizePage: Int?

    /// The ticks' width when closed, and the pages panel's width plus ticks when open.
    private let closedRegion: CGFloat = 26
    private let openRegion: CGFloat = 184

    init(url: URL?, fileId: String, startPage: Int?, searchMatch: String?, isCurrent: Bool,
         office: OfficePDFConverter?, firstPDFPage: Data?) {
        self.url = url
        self.startPage = startPage
        self.searchMatch = searchMatch
        self.isCurrent = isCurrent
        self.office = office
        self.firstPDFPage = firstPDFPage
        _controller = StateObject(wrappedValue: PDFController(fileId: fileId))
    }

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .trailing) {
                PDFContent(view: controller.view)
                    .modifier(NoTopEdgeFade())
                    // The 12pt gutter is the same on every side in both appearances. Opening always scrolls
                    // to a page (`go(to:)`), which drops the view's own 6pt margin above the first page,
                    // so the top inset is the full 12pt here; the bottom keeps 6pt plus the last page's margin.
                    .padding(.horizontal, Space.s12)
                    .padding(.top, Space.s12)
                    .padding(.bottom, Space.s6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !isLocked {
                    HStack(spacing: Space.s4) {
                        if isOpen { pagesPanel.transition(.opacity) }
                        PageTicks(count: controller.pageCount, current: controller.pageIndex)
                            .opacity(isHovering || isOpen ? 1 : 0)
                            .animation(Motion.fast, value: isHovering)
                    }
                    // The ticks sit in the page's own 12pt gutter, so nothing is drawn over the page.
                    .padding(.trailing, 0)
                    .padding(.vertical, Space.s8)
                }
            }
            .onHover { isHovering = $0 }
            if isLocked {
                pagesPanel.padding(Space.s8)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("viewer.pdf")
        .overlay(alignment: .topTrailing) {
            if url == nil || office?.isFinished == false { Spinner().padding(Space.s12) }
        }
        .overlay(alignment: .bottomLeading) {
            if startPage != nil, controller.pageCount > 0 {
                Text("Page \(controller.pageIndex + 1) of \(controller.pageCount)")
                    .font(Type.t11)
                    .padding(.horizontal, Space.s8)
                    .padding(.vertical, Space.s4)
                    .background(.regularMaterial, in: Capsule())
                    .padding(Space.s12)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("viewer.pdf.page")
                    .accessibilityLabel("Page \(controller.pageIndex + 1) of \(controller.pageCount)")
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { frame = proxy.frame(in: .global) }
                    .onChange(of: proxy.frame(in: .global)) { _, new in frame = new }
            }
        }
        .task(id: url) {
            if let firstPDFPage { controller.showDownloadPreview(firstPDFPage) }
            if office != nil {
                updateOfficePages()
            } else {
                if let url { await controller.load(url) }
                // Always land on a page, so the top gutter is the same whether or not a page was asked for.
                if !didOpenInitialPage { openInitialPage() }
            }
        }
        .onChange(of: office?.capturedPages.count) { updateOfficePages() }
        .onChange(of: office?.isFinished) { updateOfficePages() }
        .onChange(of: office) { previous, current in
            // The finished file takes the same panel. Attach any final pages before releasing their buffers.
            if current == nil, let previous, previous.isFinished {
                controller.showPages(from: previous)
                if !didOpenInitialPage { openInitialPage() }
            }
        }
        .onChange(of: startPage) { reopenInitialPage() }
        .onChange(of: searchMatch) { reopenInitialPage() }
        // Keep the starting page through rapid reversals and refit once the viewport settles.
        .onChange(of: model.viewerIsFull) {
            if isCurrent, resizePage == nil { resizePage = controller.pageIndex }
        }
        .task(id: isCurrent && resizePage != nil ? frame.width : nil) {
            guard isCurrent, let page = resizePage else { return }
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            resizePage = nil
            controller.refitKeeping(pageAt: page)
        }
        .onAppear(perform: startWatching)
        .onDisappear(perform: stopWatching)
        .onAppear { registerController() }
        .onChange(of: url) { registerController() }
        .onChange(of: isCurrent) {
            if isCurrent { registerController() }
            else { resizePage = nil }
        }
    }

    private func registerController() {
        if let url { PDFControllers.register(controller, for: url) }
    }

    private func updateOfficePages() {
        guard let office else { return }
        controller.showPages(from: office)
        if !didOpenInitialPage { openInitialPage() }
    }

    private func reopenInitialPage() {
        didOpenInitialPage = false
        openInitialPage()
    }

    private func openInitialPage() {
        guard (startPage ?? 0) < controller.pageCount else { return }
        controller.showSearchMatch(searchMatch, onPage: startPage ?? 0)
        didOpenInitialPage = true
    }

    /// The PDF view takes hover events for itself, so the panel listens to pointer moves directly.
    private func startWatching() {
        NSApp.keyWindow?.acceptsMouseMovedEvents = true
        NSApp.mainWindow?.acceptsMouseMovedEvents = true
        guard monitor.token == nil else { return }
        monitor.token = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { event in
            pointerMoved(event)
            return event
        }
    }

    private func stopWatching() {
        if let token = monitor.token { NSEvent.removeMonitor(token) }
        monitor.token = nil
    }

    private func pointerMoved(_ event: NSEvent) {
        guard isCurrent, !isLocked, let window = event.window else { return }
        let point = CGPoint(x: event.locationInWindow.x, y: window.frame.height - event.locationInWindow.y)
        let width = isOpen ? openRegion : closedRegion
        let region = CGRect(x: frame.maxX - width, y: frame.minY, width: width, height: frame.height)
        if region.contains(point) {
            closeTask?.cancel()
            closeTask = nil
            if !isOpen { withMotion(Motion.fast, reduceMotion: reduceMotion) { isOpen = true } }
        } else if isOpen, closeTask == nil {
            closeTask = Task {
                try? await Task.sleep(for: .milliseconds(250))
                if !Task.isCancelled { withMotion(Motion.fast, reduceMotion: reduceMotion) { isOpen = false } }
                closeTask = nil
            }
        }
    }

    private var pagesPanel: some View {
        VStack(spacing: Space.s6) {
            HStack {
                Text(controller.pageCount == 1 ? "1 page" : "\(controller.pageCount) pages")
                    .font(Type.t12)
                    .foregroundStyle(Color.textMuted)
                Spacer(minLength: 0)
                // One button: the page in view, or every page with Command held.
                IconButton(Symbol.rotate, label: "Rotate page") {
                    let all = NSEvent.modifierFlags.contains(.command)
                    controller.rotate(pages: all ? nil : controller.view.currentPage.map { [$0] }, by: 90)
                }
                .help("Rotate page. Hold ⌘ to rotate all pages.")
                .accessibilityHint("Hold Command to rotate all pages")
                .accessibilityIdentifier("viewer.rotate")
                .disabled(!controller.allowsRotation)
                IconButton(isLocked ? "lock" : "lock.open", label: isLocked ? "Unlock pages" : "Lock pages") {
                    isLocked.toggle()
                    isOpen = false
                }
            }
            .padding(.horizontal, Space.s8)
            .padding(.top, Space.s4)
            ThumbnailContent(pdfView: controller.view, revision: controller.revision)
        }
        .frame(width: 148)
        .background(Color.raised, in: RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
    }
}

/// A short tick per page along the edge, with the current page marked. Hovering opens the pages.
private struct PageTicks: View {
    let count: Int
    let current: Int
    private let maxTicks = 30

    var body: some View {
        let shown = min(count, maxTicks)
        let marked = count > 0 ? current * shown / max(count, 1) : 0
        VStack(spacing: 5) {
            ForEach(0..<shown, id: \.self) { tick in
                Capsule()
                    .fill(tick == marked ? Color.text : Color.textMuted.opacity(0.5))
                    .frame(width: tick == marked ? 10 : 6, height: tick == marked ? 2 : 1)
            }
        }
        .padding(.vertical, Space.s8)
        .frame(width: Space.s12)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .help("Page \(current + 1) of \(count)")
        .accessibilityElement()
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}

/// Newer systems fade a scroll view's top edge under the tab bar, which lays a faint band across the
/// top of the page. The page starts below the bar, so there is nothing to fade.
private struct NoTopEdgeFade: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.scrollEdgeEffectHidden(true, for: .top)
        } else {
            content
        }
    }
}

private struct PDFContent: NSViewRepresentable {
    let view: PDFView

    func makeNSView(context: Context) -> PDFView { view }
    func updateNSView(_ nsView: PDFView, context: Context) {}
}

private struct ThumbnailContent: NSViewRepresentable {
    let pdfView: PDFView
    let revision: Int

    final class Coordinator { var revision = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView()
        view.thumbnailSize = CGSize(width: 116, height: 150)
        view.maximumNumberOfColumns = 1
        view.backgroundColor = .clear
        view.pdfView = pdfView
        return view
    }

    func updateNSView(_ view: PDFThumbnailView, context: Context) {
        // Reattach when the document adds or rotates pages.
        guard context.coordinator.revision != revision else { return }
        context.coordinator.revision = revision
        view.pdfView = nil
        view.pdfView = pdfView
    }
}

private struct QuickLookContent: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? URL) != url { view.previewItem = url as NSURL }
    }
}
