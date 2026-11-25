import CryptoKit
import LaerCore
import Observation
import SwiftUI

/// Which parity screens are in navigation.
enum ParityGate {
    static let messages = true
    static let pages = true
    static let courseCalendar = true
    /// The route passes, but people found the list of no use. The screen and route stay for later, unreachable.
    static let participants = false
    /// `calendar/events/v1` passes with `fromDate`, which the client always sends.
    static let personalCalendar = true
    /// `assignments/{id}/v1` passes for CustomActivity tasks; 403 means the task is not an assignment.
    static let assignments = true
    static let notifications = true
    static let bulletins = true
    /// Assessment routes are role- and site-dependent. When on, the Grades tab still appears
    /// only after a quiet probe succeeds; a refusal shows nothing. See `GradesAvailability`.
    static let grades = true
    /// Writes need `AppModel.write`, which a bearer or fixture transport backs. Each one is a single user action.
    static let writes = true
}

/// The account and store a collection read started with.
struct CollectionSession: Equatable {
    let store: SnapshotStore?
    private let personId: Int?
    private let authGeneration: Int

    @MainActor init(_ model: AppModel) {
        store = model.snapshots
        if case .ready(let person) = model.authState {
            personId = person.personId
        } else {
            personId = nil
        }
        authGeneration = model.authGeneration
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.store === rhs.store && lhs.personId == rhs.personId
            && lhs.authGeneration == rhs.authGeneration
    }

    @MainActor func matches(_ model: AppModel) -> Bool { self == Self(model) }

    @MainActor func isCurrent(_ model: AppModel) -> Bool { !Task.isCancelled && matches(model) }
}

/// One cached collection for a feature screen: snapshot first, then a refresh when stale.
/// A failed refresh keeps what is on screen.
@MainActor
@Observable
final class CollectionLoader<Record: Codable & Sendable> {
    private(set) var records: [Record] = []
    private(set) var state = CollectionState()
    /// The last refresh's error, for screens that treat a specific error as an answer.
    private(set) var lastError: Error?

    let key: String
    private let coverage: Coverage
    private let read: @Sendable (ItslearningClient) async throws -> PagedResult<Record>

    init(key: String, coverage: Coverage = .complete, read: @escaping @Sendable (ItslearningClient) async throws -> PagedResult<Record>) {
        self.key = key
        self.coverage = coverage
        self.read = read
    }

    @ObservationIgnored private var session: CollectionSession?
    @ObservationIgnored private var requestID: UUID?

    private func scope(to model: AppModel) -> CollectionSession {
        let current = CollectionSession(model)
        if session != current {
            session = current
            requestID = nil
            records = []
            state = CollectionState()
            lastError = nil
        }
        return current
    }

    func load(using model: AppModel) async {
        guard !Task.isCancelled else { return }
        let session = scope(to: model)
        if state.lastSuccess == nil, requestID == nil,
           let snapshot = await session.store?.load(Record.self, collection: key) {
            guard session.isCurrent(model), requestID == nil else { return }
            if state.lastSuccess == nil {
                records = snapshot.records
                state.lastSuccess = snapshot.lastSuccess
                state.isIncomplete = snapshot.coverage == .incomplete
            }
        }
        guard session.isCurrent(model) else { return }
        if let last = state.lastSuccess, Date().timeIntervalSince(last) < FreshnessLine.staleAfter { return }
        await refresh(using: model)
    }

    func refresh(using model: AppModel) async {
        guard !Task.isCancelled else { return }
        let session = scope(to: model)
        let request = UUID()
        requestID = request
        state.phase = .loading
        defer {
            if requestID == request {
                requestID = nil
                if session.matches(model), state.phase == .loading { state.phase = .idle }
            }
        }
        do {
            let result = try await model.fetch(key: key, read)
            guard session.isCurrent(model), requestID == request else { return }
            let now = Date()
            let saved: Coverage = result.isComplete ? coverage : .incomplete
            try? await session.store?.save(result.items, collection: key, coverage: saved, checkpoint: nil, at: now)
            guard session.isCurrent(model), requestID == request else { return }
            records = result.items
            state = CollectionState(phase: .idle, lastSuccess: now, isIncomplete: !result.isComplete)
            lastError = nil
        } catch is CancellationError {
            return
        } catch RefreshError.staleGeneration {
            return
        } catch {
            guard session.isCurrent(model), requestID == request else { return }
            lastError = error
            state.phase = .failed(model.message(for: error))
        }
    }
}

// MARK: - Rich text

/// One derived value per screen, recomputed only when its inputs change. Not observed: reading
/// it never causes a redraw. Hold it in `@State` so it lives as long as the screen.
@MainActor
final class Memo<Key: Equatable, Value> {
    private var key: Key?
    private var value: Value?

    func value(for key: Key, _ compute: () -> Value) -> Value {
        if let value, self.key == key { return value }
        let result = compute()
        self.key = key
        value = result
        return result
    }
}

/// The minute now, so groupings that depend on the time refresh at most once a minute.
@MainActor
func currentMinute() -> Date {
    Date(timeIntervalSinceReferenceDate: (Date().timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
}

/// Parsed course text shared by the full body and row previews.
@MainActor
enum RichTextCache {
    @MainActor
    @Observable
    fileprivate final class Entry {
        var content: ParsedRichText?
        @ObservationIgnored var parse: Task<ParsedRichText, Never>?
        var inline: AttributedString?
        @ObservationIgnored var isPreparingInline = false
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 600
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    static func key(for html: String) -> String {
        let digest = SHA256.hash(data: Data(html.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func entry(for html: String, key: String) -> Entry? {
        guard !html.isEmpty else { return nil }
        if let hit = cache.object(forKey: key as NSString) { return hit }
        let entry = Entry()
        let parse = Task.detached(priority: .userInitiated) { ParsedRichText(html: html) }
        entry.parse = parse
        cache.setObject(entry, forKey: key as NSString, cost: 1024 + 4 * html.utf8.count)
        Task {
            entry.content = await parse.value
            entry.parse = nil
        }
        return entry
    }

    static func cachedBlocks(key: String) -> [RichBlock]? {
        cache.object(forKey: key as NSString)?.content?.blocks
    }

    static func loadBlocks(_ html: String, key: String) async -> [RichBlock] {
        guard let entry = entry(for: html, key: key) else { return [] }
        if let content = entry.content { return content.blocks }
        return await entry.parse?.value.blocks ?? []
    }

    /// One line for a row's preview, with breaks and paragraphs collapsed to spaces.
    static func preview(_ html: String) -> String {
        entry(for: html, key: key(for: html))?.content?.preview ?? ""
    }

    /// Formatted preview for a row that needs to keep its own click target.
    static func inline(_ html: String) -> AttributedString {
        guard let entry = entry(for: html, key: key(for: html)) else { return AttributedString() }
        if let inline = entry.inline { return inline }
        guard let content = entry.content else { return AttributedString() }
        if !entry.isPreparingInline {
            entry.isPreparingInline = true
            let format = Task.detached(priority: .userInitiated) { content.inlinePreview() }
            Task { entry.inline = await format.value }
        }
        return AttributedString()
    }
}

/// A body of course text: one selectable, read-only text view, so ⌘A, a drag and Copy cover every
/// paragraph, list and heading in it. Links open through the app's own link handling.
struct RichTextView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigation.self) private var navigation
    private enum Content {
        case html(String)
        case blocks([RichBlock])
    }

    private let content: Content
    @State private var parsed: (key: String, blocks: [RichBlock])?
    var tone: RichTextTone = .page
    var hugsWidth = false

    init(html: String, tone: RichTextTone = .page, hugsWidth: Bool = false) {
        content = .html(html)
        self.tone = tone
        self.hugsWidth = hugsWidth
    }

    init(blocks: [RichBlock]) {
        content = .blocks(blocks)
    }

    var body: some View {
        switch content {
        case .blocks(let blocks):
            rendered(blocks)
        case .html(let html):
            let key = RichTextCache.key(for: html)
            rendered((parsed?.key == key ? parsed?.blocks : RichTextCache.cachedBlocks(key: key)) ?? [])
                .task(id: key) {
                    let blocks = await RichTextCache.loadBlocks(html, key: key)
                    guard !Task.isCancelled else { return }
                    parsed = (key, blocks)
                }
        }
    }

    private func rendered(_ blocks: [RichBlock]) -> some View {
        RichTextBody(blocks: blocks, tone: tone, hugsWidth: hugsWidth) { link in
            if let url = resolve(link), !navigation.openSiteLink(url) { NSWorkspace.shared.open(url) }
        }
    }

    private func resolve(_ link: String) -> URL? {
        if link.lowercased().hasPrefix("mailto:") { return URL(string: link) }
        return model.absoluteURL(link)
    }
}

// MARK: - Shared rows

/// A thin, muted divider between items in a page.
struct ItemDivider: View {
    var body: some View {
        Rectangle().fill(Color.border).frame(height: 1)
    }
}

/// Whether this site lets the signed-in person read the gradebook. Learned from one quiet read per
/// launch; a refusal (403 or 404) hides the Grades tab and is never shown as an error.
@MainActor
@Observable
final class GradesAvailability {
    static let shared = GradesAvailability()

    /// Keyed by person and course, so one account's answer never applies to another.
    private var known: [String: Bool] = [:]
    private var probing: Set<String> = []

    func isAvailable(courseId: Int, model: AppModel) -> Bool {
        guard let key = Self.key(courseId, model) else { return false }
        return known[key] == true
    }

    func probe(courseId: Int, using model: AppModel) async {
        guard ParityGate.grades, let key = Self.key(courseId, model), known[key] == nil, !probing.contains(key) else { return }
        let session = CollectionSession(model)
        probing.insert(key)
        defer { probing.remove(key) }
        do {
            let record = try await model.fetch(key: "grades-probe-\(courseId)") { try await $0.assessmentRecord(courseId: courseId) }
            guard session.isCurrent(model) else { return }
            known[key] = !((record.items ?? []).isEmpty && (record.finalItems ?? []).isEmpty)
        } catch APIError.forbidden, APIError.notFound {
            guard session.isCurrent(model) else { return }
            known[key] = false
        } catch {
            // Offline or a passing failure: try again on the next visit.
        }
    }

    private static func key(_ courseId: Int, _ model: AppModel) -> String? {
        guard case .ready(let person) = model.authState, let site = model.site else { return nil }
        return "\(site.customerId)-\(person.personId)-\(courseId)"
    }
}
