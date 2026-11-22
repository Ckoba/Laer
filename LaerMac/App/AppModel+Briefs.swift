import Foundation
import LaerCore
import Observation
import OSLog

enum BriefLog {
    /// Operation names and error categories only; never titles or text.
    static let log = Logger(subsystem: "app.laer.Laer", category: "briefs")
}

/// Briefs made on this Mac by Apple's on-device model from a lecture's saved readings.
/// Decision 0014: off until the person agrees, stored only in Laer's own storage.
@MainActor
@Observable
final class LectureBriefs {
    private static let enabledKey = "LaerOnDeviceBriefs"
    private static let askedKey = "LaerOnDeviceBriefsAsked"

    private(set) var generated: [Int: GeneratedBrief] = [:]
    /// The plan whose brief is being written now.
    private(set) var workingPlanId: Int?
    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }
    /// True once the person answered the question after sign-in, either way.
    private(set) var hasAsked: Bool {
        didSet { UserDefaults.standard.set(hasAsked, forKey: Self.askedKey) }
    }

    @ObservationIgnored private(set) var store: GeneratedBriefStore?
    @ObservationIgnored var queue: [(plan: PlanPreview, courseId: Int)] = []
    @ObservationIgnored var worker: Task<Void, Never>?
    /// Plan and source key pairs tried this launch, so a failure is not retried in a loop.
    @ObservationIgnored var attempted: Set<String> = []
    init() {
        let defaults = UserDefaults.standard
        hasAsked = defaults.bool(forKey: Self.askedKey)
        // Only an answer to the question turns this on; an older default of on does not count.
        isEnabled = defaults.bool(forKey: Self.askedKey) && defaults.bool(forKey: Self.enabledKey)
        // Folders picked in earlier versions are no longer read or written.
        for key in ["notesFolderBookmark", "briefExportFolderBookmark"] { defaults.removeObject(forKey: key) }
    }

    /// Ask once, after sign-in, and only where the model can run.
    var shouldAsk: Bool {
        isAvailable && !hasAsked && !ProcessInfo.processInfo.arguments.contains("-LaerUITestReset")
    }

    func markAsked() { hasAsked = true }

    /// The feature shows only where the model can run.
    var isAvailable: Bool { OnDeviceModel.isAvailable }

    func open(root: URL, accountKey: String) async {
        let store = GeneratedBriefStore(rootDirectory: root, accountKey: accountKey)
        self.store = store
        generated = await store.all()
    }

    func close() {
        worker?.cancel()
        worker = nil
        queue = []
        attempted = []
        workingPlanId = nil
        generated = [:]
        store = nil
    }

    func record(_ brief: GeneratedBrief) async {
        generated[brief.planId] = brief
        try? await store?.save(brief)
    }

    func setWorking(_ planId: Int?) { workingPlanId = planId }

    /// Turning the feature off stops work and deletes what it made in Laer's storage.
    func setEnabled(_ enabled: Bool) async {
        isEnabled = enabled
        guard !enabled else { return }
        worker?.cancel()
        worker = nil
        queue = []
        generated = [:]
        try? await store?.removeAll()
    }
}

extension AppModel {
    /// A reading was saved: every plan that lists it gets a brief, after the current one.
    func scheduleBrief(forReading resource: Resource) {
        guard briefs.isEnabled else { return }
        for (courseId, coursePlans) in plans where resource.courseId == nil || resource.courseId == courseId {
            for plan in coursePlans where (plan.elements ?? []).contains(where: { Resource(planElement: $0, courseId: courseId).id == resource.id }) {
                scheduleBrief(for: plan, courseId: courseId)
            }
        }
    }

    func scheduleBrief(for plan: PlanPreview, courseId: Int) {
        guard briefs.isEnabled, briefs.isAvailable else { return }
        guard !briefs.queue.contains(where: { $0.plan.planId == plan.planId }) else { return }
        briefs.queue.append((plan, courseId))
        guard briefs.worker == nil else { return }
        briefs.worker = Task(priority: .utility) { [weak self] in
            while let self, !Task.isCancelled, !self.briefs.queue.isEmpty {
                let next = self.briefs.queue.removeFirst()
                await self.generateBrief(for: next.plan, courseId: next.courseId)
            }
            self?.briefs.worker = nil
        }
    }

    /// The plan's brief from its saved readings, unless one from the same files exists, or this
    /// launch already failed on them.
    private func generateBrief(for plan: PlanPreview, courseId: Int) async {
        let saved: [(asset: LocalAsset, url: URL, title: String)] = (plan.elements ?? []).compactMap { element in
            guard element.isFolder != true else { return nil }
            let resource = Resource(planElement: element, courseId: courseId)
            guard let asset = savedAssets[resource.id], let url = downloads?.fileURLIfPresent(for: asset),
                  ReadingExtractor.canRead(url) else { return nil }
            return (asset, url, resource.title)
        }
        guard !saved.isEmpty else { return }
        let sourceKey = GeneratedBrief.sourceKey(saved.map(\.asset))
        let attempt = "\(plan.planId)|\(sourceKey)"
        guard briefs.generated[plan.planId]?.sourceKey != sourceKey, !briefs.attempted.contains(attempt) else { return }
        briefs.attempted.insert(attempt)

        briefs.setWorking(plan.planId)
        defer { briefs.setWorking(nil) }
        BriefLog.log.notice("brief started")
        // Slides become PDFs first, through the same converter and cache the viewer uses.
        var files: [(url: URL, title: String)] = []
        for item in saved {
            if ReadingExtractor.isSlides(item.url) {
                guard let pdf = try? await OfficePDFConverter.convert(item.url, id: item.asset.id) else { continue }
                files.append((pdf, item.title))
            } else {
                files.append((item.url, item.title))
            }
        }
        let readings = await Task.detached(priority: .utility) {
            files.compactMap { file in ReadingExtractor.text(of: file.url).map { ReadingText(title: file.title, text: $0) } }
        }.value
        guard !readings.isEmpty else {
            BriefLog.log.notice("brief skipped: no text")
            return
        }
        let language = ReadingExtractor.language(of: readings.map(\.text))
        let chunks = BriefChunker.plan(readings)

        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return }
        do {
            let started = Date()
            let draft = try await OnDeviceBriefWriter(language: language).write(chunks, lectureTitle: plan.name)
            guard !Task.isCancelled, briefs.isEnabled else { return }
            let brief = GeneratedBrief(
                planId: plan.planId, courseId: courseId, lectureTitle: plan.name, sourceKey: sourceKey,
                readingTitles: readings.map(\.title), language: language, generatedAt: Date(),
                summary: draft.summary, keyQuestions: draft.keyQuestions, concepts: draft.concepts
            )
            await briefs.record(brief)
            BriefLog.log.notice("brief saved: \(chunks.count, privacy: .public) chunks, \(Int(Date().timeIntervalSince(started)), privacy: .public) s")
        } catch {
            BriefLog.log.notice("brief failed: \(OnDeviceBriefWriter.category(error), privacy: .public)")
        }
        #endif
    }

    /// Briefs for lectures whose readings were saved before this launch or before the feature was on.
    func scheduleBriefsForUpcoming() {
        for lecture in upcomingLectures(limit: 4) {
            scheduleBrief(for: lecture.plan, courseId: lecture.course.courseId)
        }
    }

    func setOnDeviceBriefs(_ enabled: Bool) async {
        briefs.markAsked()
        await briefs.setEnabled(enabled)
        if enabled { scheduleBriefsForUpcoming() }
    }
}
