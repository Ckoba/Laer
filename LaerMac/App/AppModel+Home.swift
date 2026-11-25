import AppKit
import Foundation
import LaerCore
import OSLog
import PDFKit

/// A link the person added, opened in their browser. Nothing about it is built in, so any
/// institution's exam, mail or sign-in sites fit.
struct StudyLink: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    var address: String
    /// An SF Symbol name the person picked. Nil means the guess from title and address.
    var symbol: String?

    var icon: String { symbol ?? Symbol.linkIcon(title: title, address: address) }

    var url: URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)"),
              url.scheme == "https" || url.scheme == "http", url.host != nil else { return nil }
        return url
    }

    private static let key = "studyLinks"

    static func saved() -> [StudyLink] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([StudyLink].self, from: data)) ?? []
    }

    static func save(_ links: [StudyLink]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(links), forKey: key)
    }
}

/// Where an active course appears in the exam plan PDF.
struct ExamPlanMatch: Hashable, Identifiable, Sendable {
    var courseId: Int
    var courseTitle: String
    /// Zero-based.
    var pages: [Int]
    var id: Int { courseId }
}

struct ExamPlanState: Equatable {
    enum Phase: Equatable { case idle, loading, failed(String) }
    var phase: Phase = .idle
    var fileURL: URL?
    var fetchedAt: Date?
    var matches: [ExamPlanMatch] = []
}

private struct CourseTitle: Sendable {
    var id: Int
    var title: String
}

extension AppModel {
    // MARK: - Links

    func setStudyLinks(_ links: [StudyLink]) {
        studyLinks = links
        StudyLink.save(links)
    }

    func open(_ link: StudyLink) {
        if let url = link.url { NSWorkspace.shared.open(url) }
    }

    // MARK: - Exam plan

    private static let examPlanKey = "examPlanAddress"

    /// A PDF address the person entered, such as their programme's published exam plan.
    var examPlanAddress: String? {
        get { UserDefaults.standard.string(forKey: Self.examPlanKey) }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            UserDefaults.standard.set(trimmed.isEmpty ? nil : trimmed, forKey: Self.examPlanKey)
            cancelExamPlan()
            examPlan = ExamPlanState()
            try? FileManager.default.removeItem(at: examPlanFile)
            if !trimmed.isEmpty { Task { await loadExamPlan(force: true) } }
        }
    }

    private var examPlanFile: URL { examPlanRoot.appending(path: "ExamPlan.pdf") }

    func cancelExamPlan() {
        examPlanGeneration += 1
        examPlanTask?.cancel()
        examPlanTask = nil
        if examPlan.phase == .loading { examPlan.phase = .idle }
    }

    /// Shows the saved copy at once and fetches a new one at most every twelve hours.
    /// A failed fetch keeps the saved copy.
    func loadExamPlan(force: Bool = false) async {
        guard case .ready = authState, !Task.isCancelled,
              let address = examPlanAddress, let url = StudyLink(title: "", address: address).url else { return }
        if !force, let examPlanTask {
            await examPlanTask.value
            return
        }
        cancelExamPlan()
        let generation = examPlanGeneration
        let session = CollectionSession(self)
        let file = examPlanFile
        let task = Task { await fetchExamPlan(url: url, file: file, force: force, session: session, generation: generation) }
        examPlanTask = task
        await task.value
        if examPlanTask == task { examPlanTask = nil }
    }

    private func fetchExamPlan(url: URL, file: URL, force: Bool, session: CollectionSession, generation: Int) async {
        func isCurrent() -> Bool { generation == examPlanGeneration && session.isCurrent(self) }
        guard isCurrent() else { return }
        if examPlan.fileURL == nil, FileManager.default.fileExists(atPath: file.path) {
            examPlan.fileURL = file
            examPlan.fetchedAt = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let matches = await matchExamPlan(file)
            guard isCurrent() else { return }
            examPlan.matches = matches
        }
        if !force, let last = examPlan.fetchedAt, Date().timeIntervalSince(last) < 12 * 60 * 60 { return }
        examPlan.phase = .loading
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard isCurrent() else { return }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw APIError.unexpectedStatus(0) }
            guard data.starts(with: Array("%PDF".utf8)) else { throw APIError.notJSON }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            examPlan.fileURL = file
            examPlan.fetchedAt = Date()
            examPlan.matches = []
            let matches = await matchExamPlan(file)
            guard isCurrent() else { return }
            examPlan.matches = matches
            examPlan.phase = .idle
        } catch {
            guard isCurrent() else { return }
            Logger(subsystem: "app.laer.Laer", category: "exam-plan").notice("fetch failed: \(String(describing: type(of: error)), privacy: .public)")
            examPlan.phase = .failed(examPlan.fileURL == nil ? "The exam plan couldn't be fetched." : "Showing the saved copy. The update failed.")
        }
    }

    /// Finds the pages that name each active course, off the main thread.
    private func matchExamPlan(_ file: URL) async -> [ExamPlanMatch] {
        let titles = activeCourses.map { CourseTitle(id: $0.courseId, title: $0.shortTitle) }
        let task = Task.detached(priority: .utility) { () -> [ExamPlanMatch] in
            guard !Task.isCancelled, let document = PDFDocument(url: file) else { return [] }
            var pages: [String] = []
            for index in 0..<document.pageCount {
                guard !Task.isCancelled else { return [] }
                pages.append(Self.squeezed(document.page(at: index)?.string ?? ""))
            }
            return titles.compactMap { course in
                let needle = Self.squeezed(course.title)
                guard !Task.isCancelled, needle.count >= 4 else { return nil }
                let hits = pages.indices.filter { pages[$0].contains(needle) }
                return hits.isEmpty ? nil : ExamPlanMatch(courseId: course.id, courseTitle: course.title, pages: hits)
            }
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private nonisolated static func squeezed(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    func openExamPlan(page: Int? = nil) {
        guard let file = examPlan.fileURL else { return }
        viewerItem = ViewerItem(id: "exam-plan", title: "Exam plan", fileURL: file, startPage: page)
    }

    // MARK: - Announcements and recent files

    /// Recent updates across active courses, newest first, with the course each belongs to.
    func recentAnnouncements(limit: Int) -> [(course: Course, update: CourseUpdate)] {
        activeCourses
            .flatMap { course in (updates[course.courseId] ?? []).map { (course: course, update: $0) } }
            .sorted { ($0.update.published ?? .distantPast) > ($1.update.published ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    func loadActiveUpdates() async {
        await withTaskGroup(of: Void.self) { group in
            for course in activeCourses.prefix(16) {
                let id = course.courseId
                group.addTask { await self.loadUpdates(courseId: id) }
            }
        }
    }

    /// Files saved on this Mac, newest first.
    func recentFiles(limit: Int) -> [LocalAsset] {
        Array(savedAssets.values.sorted { $0.downloadedAt > $1.downloadedAt }.prefix(limit))
    }

    func open(_ asset: LocalAsset) {
        guard let downloads, let url = downloads.fileURLIfPresent(for: asset) else { return }
        let item = ViewerItem(id: asset.id, title: asset.displayName, fileURL: url)
        if !asset.isAutoPrefetched {
            viewerItem = item
            return
        }
        Task {
            await keepSavedAsset(asset.id, store: downloads)
            guard downloads === self.downloads, downloads.fileURLIfPresent(for: asset) != nil else { return }
            viewerItem = item
        }
    }
}
