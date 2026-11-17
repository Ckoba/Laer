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
            examPlan = ExamPlanState()
            try? FileManager.default.removeItem(at: Self.examPlanFile)
            if !trimmed.isEmpty { Task { await loadExamPlan(force: true) } }
        }
    }

    private static var examPlanFile: URL {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "Laer/ExamPlan.pdf")
    }

    /// Shows the saved copy at once and fetches a new one at most every twelve hours.
    /// A failed fetch keeps the saved copy.
    func loadExamPlan(force: Bool = false) async {
        guard let address = examPlanAddress, let url = StudyLink(title: "", address: address).url else { return }
        let file = Self.examPlanFile
        if examPlan.fileURL == nil, FileManager.default.fileExists(atPath: file.path) {
            examPlan.fileURL = file
            examPlan.fetchedAt = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            await matchExamPlan()
        }
        if !force, let last = examPlan.fetchedAt, Date().timeIntervalSince(last) < 12 * 60 * 60 { return }
        guard examPlan.phase != .loading else { return }
        examPlan.phase = .loading
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw APIError.unexpectedStatus(0) }
            // A sign-in page answered with 200 is not the plan.
            guard data.starts(with: Array("%PDF".utf8)) else { throw APIError.notJSON }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            examPlan.fileURL = file
            examPlan.fetchedAt = Date()
            examPlan.phase = .idle
            await matchExamPlan()
        } catch {
            Logger(subsystem: "app.laer.Laer", category: "exam-plan").notice("fetch failed: \(String(describing: type(of: error)), privacy: .public)")
            examPlan.phase = .failed(examPlan.fileURL == nil ? "The exam plan couldn't be fetched." : "Showing the saved copy. The update failed.")
        }
    }

    /// Finds the pages that name each active course, off the main thread. Line breaks inside a
    /// table cell are ignored, so a title split over two lines still matches.
    private func matchExamPlan() async {
        guard let file = examPlan.fileURL else { return }
        let titles = activeCourses.map { CourseTitle(id: $0.courseId, title: $0.shortTitle) }
        examPlan.matches = await Task.detached(priority: .utility) { () -> [ExamPlanMatch] in
            guard let document = PDFDocument(url: file) else { return [] }
            let pages = (0..<document.pageCount).map { index in
                Self.squeezed(document.page(at: index)?.string ?? "")
            }
            return titles.compactMap { course in
                let needle = Self.squeezed(course.title)
                guard needle.count >= 4 else { return nil }
                let hits = pages.indices.filter { pages[$0].contains(needle) }
                return hits.isEmpty ? nil : ExamPlanMatch(courseId: course.id, courseTitle: course.title, pages: hits)
            }
        }.value
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
        guard let url = downloads?.fileURLIfPresent(for: asset) else { return }
        viewerItem = ViewerItem(id: asset.id, title: asset.displayName, fileURL: url)
    }
}
