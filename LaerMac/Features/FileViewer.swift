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
        return min(max(model.viewerWidth ?? total * 0.5, min(minPanel, total)), total)
    }

    private func resizeHandle(total: CGFloat) -> some View {
        Rectangle()
            .fill(Color.border)
            .frame(width: 1)
            .frame(width: 8)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active: NSCursor.resizeLeftRight.set()
                case .ended: NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartWidth ?? panelWidth(total: total)
                        dragStartWidth = start
                        let width = start - value.translation.width
                        model.viewerIsFull = total - width < snapToFull
                        model.viewerWidth = min(width, total)
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
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
                    }
                }
                if let item = model.viewerItem, item.fileURL != nil {
                    FileMenu(item: item)
                }
                IconButton(Symbol.close, label: "Close") { model.closeViewer() }
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

    var body: some View {
        HStack(spacing: Space.s6) {
            Image(systemName: Symbol.material)
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
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.textMuted)
            .opacity(isCurrent || isHovering ? 1 : 0)
            .accessibilityLabel("Close \(item.title)")
        }
        .padding(.leading, Space.s8)
        .padding(.trailing, Space.s4)
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
            if inside {
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

    private var source: URL { model.convertedFiles[item.id] ?? item.fileURL ?? URL(fileURLWithPath: "/") }

    var body: some View {
        Menu {
            Button(model.viewerIsFull ? "Exit full size" : "Full size") { model.viewerIsFull.toggle() }
                .keyboardShortcut("f", modifiers: [.shift, .command])
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
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("File actions")
    }

    private func export() {
        let panel = NSSavePanel()
        let base = (item.title as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(base.isEmpty ? item.title : base).\(source.pathExtension)"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: source, to: destination)
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

    private var displayURL: URL? { model.convertedFiles[item.id] ?? item.fileURL }

    var body: some View {
        Group {
            if let displayURL, displayURL.pathExtension.lowercased() == "pdf" {
                PDFPanel(url: displayURL, isCurrent: isCurrent)
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
        guard item.isSlides, let source = item.fileURL else { return }
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

/// Holds the PDF view, so the page and its thumbnails share one document.
@MainActor
@Observable
private final class PDFController {
    let view = PDFView()
    private(set) var pageCount = 0
    private(set) var pageIndex = 0
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(url: URL) {
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.minScaleFactor = 0.25
        view.maxScaleFactor = 6
        view.backgroundColor = .clear
        observer = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePage() }
        }
    }

    /// Opening a large document can take a moment, so it happens away from the main thread.
    func load(_ url: URL) async {
        guard view.document == nil else { return }
        let box = await Task.detached(priority: .userInitiated) { DocumentBox(PDFDocument(url: url)) }.value
        view.document = box.document
        pageCount = box.document?.pageCount ?? 0
        // Fit to the panel again now that the page size is known.
        view.autoScales = false
        view.autoScales = true
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
    let isCurrent: Bool
    @State private var controller: PDFController
    @AppStorage("viewerPagesLocked") private var isLocked = false
    @State private var isOpen = false
    @State private var frame: CGRect = .zero
    @State private var monitor = MonitorHolder()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var closeTask: Task<Void, Never>?

    /// The ticks' width when closed, and the pages panel's width plus ticks when open.
    private let closedRegion: CGFloat = 26
    private let openRegion: CGFloat = 184

    init(url: URL, isCurrent: Bool) {
        self.url = url
        self.isCurrent = isCurrent
        _controller = State(initialValue: PDFController(url: url))
    }

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .trailing) {
                PDFContent(view: controller.view)
                if !isLocked {
                    HStack(spacing: Space.s4) {
                        if isOpen { pagesPanel.transition(.opacity) }
                        PageTicks(count: controller.pageCount, current: controller.pageIndex)
                    }
                    .padding(.trailing, Space.s4)
                    .padding(.vertical, Space.s8)
                }
            }
            if isLocked {
                pagesPanel.padding(Space.s8)
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { frame = proxy.frame(in: .global) }
                    .onChange(of: proxy.frame(in: .global)) { _, new in frame = new }
            }
        }
        .task { await controller.load(url) }
        .onAppear(perform: startWatching)
        .onDisappear(perform: stopWatching)
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
                IconButton(isLocked ? "lock" : "lock.open", label: isLocked ? "Unlock pages" : "Lock pages") {
                    isLocked.toggle()
                    isOpen = false
                }
            }
            .padding(.horizontal, Space.s8)
            .padding(.top, Space.s4)
            ThumbnailContent(pdfView: controller.view)
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
                    .frame(width: tick == marked ? 12 : 8, height: tick == marked ? 2 : 1)
            }
        }
        .padding(.vertical, Space.s8)
        .frame(width: 18)
        // Stays readable over a white page.
        .background(Color.rail.opacity(0.85), in: Capsule())
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}

private struct PDFContent: NSViewRepresentable {
    let view: PDFView

    func makeNSView(context: Context) -> PDFView { view }
    func updateNSView(_ nsView: PDFView, context: Context) {}
}

private struct ThumbnailContent: NSViewRepresentable {
    let pdfView: PDFView

    func makeNSView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView()
        view.thumbnailSize = CGSize(width: 116, height: 150)
        view.maximumNumberOfColumns = 1
        view.backgroundColor = .clear
        view.pdfView = pdfView
        return view
    }

    func updateNSView(_ view: PDFThumbnailView, context: Context) {}
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
