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

    private let minPanel: CGFloat = 320
    /// Dragging within this distance of the far edge fills the space.
    private let snapToFull: CGFloat = 200

    var body: some View {
        GeometryReader { proxy in
            let total = proxy.size.width
            let hasFile = model.viewerItem != nil
            let panel = hasFile ? panelWidth(total: total) : 0
            HStack(spacing: 0) {
                detail()
                    .frame(width: max(total - panel, 0))
                    .opacity(total - panel < 1 ? 0 : 1)
                    .clipped()
                if hasFile {
                    FileViewerHost()
                        .frame(width: panel)
                        .background(Color.viewerPanel)
                        .overlay(alignment: .leading) { resizeHandle(total: total) }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
    }

    private func panelWidth(total: CGFloat) -> CGFloat {
        if model.viewerIsFull { return total }
        let minimum = min(minPanel, total)
        let maximum = max(minimum, total - snapToFull)
        return min(max(model.viewerWidth ?? total * 0.62, minimum), maximum)
    }

    private func resizeHandle(total: CGFloat) -> some View {
        // The line sits on the panel's own leading edge, so the strip and the page share it. No line when
        // the file fills the window; the drag still works over the same 10pt.
        Color.clear
            .frame(width: 10)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(model.viewerIsFull ? Color.clear : (isOverHandle ? Color.borderStrong : Color.border))
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
                        let start = dragStartWidth ?? panelWidth(total: total)
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

/// Tabs for open files, one menu, and Close.
struct FileViewerHost: View {
    @Environment(AppModel.self) private var model

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
                    label: model.viewerIsFull ? "Restore split view" : "Expand reader"
                ) { model.viewerIsFull.toggle() }
                    .help(model.viewerIsFull ? "Restore side-by-side view" : "Expand reader. You can also drag the divider left.")
                    .accessibilityIdentifier("viewer.toggleFull")
                if let item = model.viewerItem, item.fileURL != nil {
                    FileMenu(item: item)
                }
                // Tab closes are the small x on each tab; this one closes the whole reader.
                IconButton(Symbol.close, label: "Close file", help: "Close reader") { model.closeViewer() }
            }
            .padding(.horizontal, Space.s8)
            .frame(height: 44)
            // The toolbar is the same surface as the document area below it, not a lighter strip.
            .background(Color.chrome)
            // The one line between the tab strip and the document; both share the surface's edges.
            Rectangle()
                .fill(Color.border)
                .frame(height: 1)
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

    private var source: URL { model.shownURL(for: item) ?? URL(fileURLWithPath: "/") }
    private var converted: URL? { model.convertedFiles[item.id] }
    private var showsOriginal: Bool { model.slidesShownAsOriginal.contains(item.id) }

    var body: some View {
        Menu {
            Button(model.viewerIsFull ? "Exit full size" : "Full size") { model.viewerIsFull.toggle() }
                .keyboardShortcut("f", modifiers: [.shift, .command])
            if item.isSlides, converted != nil {
                Button(showsOriginal ? "View as PDF" : "View as PowerPoint") {
                    if showsOriginal {
                        model.slidesShownAsOriginal.remove(item.id)
                    } else {
                        model.slidesShownAsOriginal.insert(item.id)
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
            Button("Open in default app") {
                guard let original = item.fileURL, let named = ViewerFiles.namedCopy(of: original, title: item.title) else { return }
                NSWorkspace.shared.open(named)
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

    /// Slides with a PDF copy ask which to save, starting from the one on screen.
    private func export() {
        let panel = NSSavePanel()
        let base = (item.title as NSString).deletingPathExtension
        let name = base.isEmpty ? item.title : base
        var choices = [source]
        if item.isSlides, let converted, let original = item.fileURL {
            choices = showsOriginal ? [original, converted] : [converted, original]
        }
        let picker = ExportFormatPicker(panel: panel, name: name, choices: choices)
        panel.nameFieldStringValue = "\(name).\(choices[0].pathExtension)"
        if choices.count > 1 { panel.accessoryView = picker.view }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        // Turned pages leave the app as they look on screen.
        if picker.selected.pathExtension.lowercased() == "pdf", let rotated = PDFControllers.rotatedDocument(picker.selected) {
            FileExport.write(rotated, to: destination)
        } else {
            FileExport.copy(picker.selected, to: destination)
        }
    }
}

extension AppModel {
    /// What the viewer shows for a file: the PDF copy of a slide deck unless the person chose the original.
    func shownURL(for item: ViewerItem) -> URL? {
        if slidesShownAsOriginal.contains(item.id) { return item.fileURL }
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
            popup.addItem(withTitle: ext == "pdf" ? "PDF" : "PowerPoint (.\(ext))")
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
    static func removeDerivedFiles() {
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

/// One open file. Slides turn into a PDF in the background, and Quick Look shows them until then.
private struct FileContent: View {
    @Environment(AppModel.self) private var model
    let item: ViewerItem
    let isCurrent: Bool
    @State private var isConverting = false

    private var displayURL: URL? { model.shownURL(for: item) }

    var body: some View {
        Group {
            if item.isNewTab {
                NewTabPage()
            } else if let displayURL, displayURL.pathExtension.lowercased() == "pdf" {
                PDFPanel(url: displayURL, fileId: item.id, startPage: item.startPage, searchMatch: item.searchMatch, isCurrent: isCurrent)
                    .id(displayURL)
            } else if let displayURL {
                QuickLookContent(url: displayURL)
            } else {
                Spinner()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isConverting {
                Spinner().padding(Space.s12)
            }
        }
        .task(id: item.fileURL) { await convertIfNeeded() }
    }

    private func convertIfNeeded() async {
        if let cached = SlideConverter.cachedPDF(for: item.id) {
            model.convertedFiles[item.id] = cached
            return
        }
        guard item.isSlides, !item.isNewTab, let source = item.fileURL else { return }
        isConverting = true
        defer { isConverting = false }
        // If this fails, Quick Look keeps showing the slides.
        if let pdf = try? await SlideConverter().convert(source, id: item.id) {
            model.convertedFiles[item.id] = pdf
        }
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

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
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
@Observable
private final class PDFController {
    let view: PDFView
    private(set) var pageCount = 0
    private(set) var pageIndex = 0
    /// Bumps when pages turn, so the thumbnails redraw.
    private(set) var revision = 0
    @ObservationIgnored private var observer: NSObjectProtocol?
    /// Quarter turns the person added, by page index, on top of the file's own rotation.
    @ObservationIgnored private var added: [Int: Int] = [:]
    @ObservationIgnored private let fileId: String

    private static let rotationsKey = "viewerPageRotations"

    var hasRotation: Bool { added.values.contains { $0 % 360 != 0 } }

    init(url: URL, fileId: String) {
        self.fileId = fileId
        let pdfView = LaerPDFView()
        view = pdfView
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        // A soft shadow and a 12pt gap lift each page off the grey canvas in both appearances.
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

    /// Opening a large document can take a moment, so it happens away from the main thread.
    func load(_ url: URL) async {
        guard view.document == nil else { return }
        let box = await Task.detached(priority: .userInitiated) { DocumentBox(PDFDocument(url: url)) }.value
        added = Self.savedRotations(for: fileId)
        if let document = box.document {
            for (index, turn) in added where index < document.pageCount {
                if let page = document.page(at: index) { page.rotation = Self.normalized(page.rotation + turn) }
            }
        }
        view.document = box.document
        for case let scroll as NSScrollView in view.subviews {
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = NSEdgeInsets()
        }
        pageCount = box.document?.pageCount ?? 0
        // Fit to the panel again now that the page size is known.
        refit()
    }

    /// Nil pages means every page. The page in view stays in view.
    func rotate(pages: [PDFPage]?, by degrees: Int) {
        guard let document = view.document else { return }
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
        guard let document = view.document, hasRotation else { return }
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
        refit()
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
    let url: URL
    let startPage: Int?
    let searchMatch: String?
    let isCurrent: Bool
    @State private var controller: PDFController
    @AppStorage("viewerPagesLocked") private var isLocked = false
    @State private var isOpen = false
    /// The page ticks show only while the pointer is over the document.
    @State private var isHovering = false
    @State private var frame: CGRect = .zero
    @State private var monitor = MonitorHolder()
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var closeTask: Task<Void, Never>?

    /// The ticks' width when closed, and the pages panel's width plus ticks when open.
    private let closedRegion: CGFloat = 26
    private let openRegion: CGFloat = 184

    init(url: URL, fileId: String, startPage: Int?, searchMatch: String?, isCurrent: Bool) {
        self.url = url
        self.startPage = startPage
        self.searchMatch = searchMatch
        self.isCurrent = isCurrent
        _controller = State(initialValue: PDFController(url: url, fileId: fileId))
    }

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .trailing) {
                // One neutral reading background across the whole document area, so a white page reads as
                // a page in both appearances. One even gutter on every side; the page's own shadow is the
                // only edge, and the area runs to the surface's edges with no frame of its own.
                PDFContent(view: controller.view)
                    .modifier(NoTopEdgeFade())
                    // The 12pt gutter is the same on every side in both appearances. Opening always scrolls
                    // to a page (`go(to:)`), which drops the view's own 6pt margin above the first page,
                    // so the top inset is the full 12pt here; the bottom keeps 6pt plus the last page's margin.
                    .padding(.horizontal, Space.s12)
                    .padding(.top, Space.s12)
                    .padding(.bottom, Space.s6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.chrome)
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
        .background(Color.chrome)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { frame = proxy.frame(in: .global) }
                    .onChange(of: proxy.frame(in: .global)) { _, new in frame = new }
            }
        }
        .task {
            await controller.load(url)
            // Always land on a page, so the top gutter is the same whether or not a page was asked for.
            controller.showSearchMatch(searchMatch, onPage: startPage ?? 0)
        }
        .onChange(of: startPage) { _, page in controller.showSearchMatch(searchMatch, onPage: page ?? 0) }
        .onChange(of: searchMatch) { _, match in controller.showSearchMatch(match, onPage: startPage ?? 0) }
        // Expanding or restoring resizes the page; keep the same page in view.
        .onChange(of: model.viewerIsFull) {
            guard isCurrent else { return }
            let index = controller.pageIndex
            Task {
                try? await Task.sleep(for: .milliseconds(60))
                controller.refitKeeping(pageAt: index)
            }
        }
        .onAppear(perform: startWatching)
        .onDisappear(perform: stopWatching)
        // Registered here, not in the controller's init: SwiftUI builds and drops a controller each time
        // this view is rebuilt, and a dropped one would replace the live one in the table.
        .onAppear { PDFControllers.register(controller, for: url) }
        .onChange(of: isCurrent) { if isCurrent { PDFControllers.register(controller, for: url) } }
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
        // Thumbnails don't notice a page turning, so they reattach to draw it again.
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
