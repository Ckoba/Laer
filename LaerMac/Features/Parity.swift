import LaerCore
import Observation
import SwiftUI

/// Which parity screens are in navigation. Only routes marked pass in docs/feasibility.md are on.
enum ParityGate {
    static let messages = true
    static let pages = true
    static let courseCalendar = true
    /// The route passes, but people found the list of no use. The screen and route stay for later, unreachable.
    static let participants = false
    /// `calendar/events/v1` passes with `fromDate`, which the client always sends.
    static let personalCalendar = true
    /// `messages/v3` passes; older messages load on request.
    static let olderMessages = true
    /// `assignments/{id}/v1` passes for CustomActivity tasks; 403 means the task is not an assignment.
    static let assignments = true
    /// Pass with OAuth sign-in. See docs/feasibility.md.
    static let notifications = true
    static let bulletins = true
    /// Assessment routes are role- and site-dependent. When on, the Grades tab still appears
    /// only after a quiet probe succeeds; a refusal shows nothing. See `GradesAvailability`.
    static let grades = true
    /// Writes need `AppModel.write`, which a bearer or fixture transport backs. Each one is a single user action.
    static let writes = true
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

    func load(using model: AppModel) async {
        if state.lastSuccess == nil, let snapshot = await model.snapshots?.load(Record.self, collection: key) {
            records = snapshot.records
            state.lastSuccess = snapshot.lastSuccess
            state.isIncomplete = snapshot.coverage == .incomplete
        }
        if let last = state.lastSuccess, Date().timeIntervalSince(last) < FreshnessLine.staleAfter { return }
        await refresh(using: model)
    }

    func refresh(using model: AppModel) async {
        state.phase = .loading
        do {
            let result = try await model.fetch(key: key, read)
            let now = Date()
            records = result.items
            let saved: Coverage = result.isComplete ? coverage : .incomplete
            try? await model.snapshots?.save(result.items, collection: key, coverage: saved, checkpoint: nil, at: now)
            state = CollectionState(phase: .idle, lastSuccess: now, isIncomplete: !result.isComplete)
            lastError = nil
        } catch is CancellationError {
            state.phase = .idle
        } catch RefreshError.staleGeneration {
            state.phase = .idle
        } catch {
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

/// Parsed course text, kept so a view body never parses the same HTML twice.
/// Views are redrawn far more often than their text changes.
@MainActor
enum RichTextCache {
    private static var parsed: [String: [RichBlock]] = [:]
    private static var plain: [String: String] = [:]
    private static var inlined: [String: AttributedString] = [:]
    /// Enough for every row on the busiest screen; cleared whole when exceeded.
    private static let limit = 600

    static func blocks(_ html: String) -> [RichBlock] {
        if let hit = parsed[html] { return hit }
        if parsed.count >= limit { parsed.removeAll(keepingCapacity: true) }
        let result = RichText.blocks(fromHTML: html)
        parsed[html] = result
        return result
    }

    /// One line for a row's preview: breaks and paragraphs become spaces, so `lineLimit` shows
    /// as much of the text as fits rather than only its first paragraph.
    static func preview(_ html: String) -> String {
        if let hit = plain[html] { return hit }
        if plain.count >= limit { plain.removeAll(keepingCapacity: true) }
        let result = RichText.preview(blocks(html))
        plain[html] = result
        return result
    }

    /// A short text with its inline formatting (bold, italic, underline, strikethrough) for a row
    /// that is itself a button, where a selectable body would take its clicks. Blocks become lines.
    static func inline(_ html: String) -> AttributedString {
        if let hit = inlined[html] { return hit }
        if inlined.count >= limit { inlined.removeAll(keepingCapacity: true) }
        var result = AttributedString()
        for block in blocks(html) {
            let runs: [RichRun]
            switch block {
            case .heading(_, let r), .paragraph(let r), .quote(let r): runs = r
            case .listItem(let ordered, let number, _, let r): runs = [RichRun(text: ordered ? "\(number). " : "\u{2022} ")] + r
            case .table(let rows): runs = rows.flatMap { $0.flatMap { $0.runs + [RichRun(text: " ")] } }
            case .code(let text): runs = [RichRun(text: text)]
            case .image(_, let alt): runs = alt.map { [RichRun(text: $0)] } ?? []
            case .embed, .rule: runs = []
            }
            guard !runs.isEmpty else { continue }
            if !result.characters.isEmpty { result += AttributedString("\n") }
            for run in runs {
                var part = AttributedString(run.text)
                var intent: InlinePresentationIntent = []
                if run.bold { intent.insert(.stronglyEmphasized) }
                if run.italic { intent.insert(.emphasized) }
                if run.code { intent.insert(.code) }
                if !intent.isEmpty { part.inlinePresentationIntent = intent }
                if run.underline { part.underlineStyle = .single }
                if run.strikethrough { part.strikethroughStyle = .single }
                result += part
            }
        }
        inlined[html] = result
        return result
    }
}

/// A body of course text: one selectable, read-only text view, so ⌘A, a drag and Copy cover every
/// paragraph, list and heading in it. Links open through the app's own link handling.
struct RichTextView: View {
    @Environment(AppModel.self) private var model
    let blocks: [RichBlock]
    var tone: RichTextTone = .page
    var hugsWidth = false

    init(html: String, tone: RichTextTone = .page, hugsWidth: Bool = false) {
        blocks = RichTextCache.blocks(html)
        self.tone = tone
        self.hugsWidth = hugsWidth
    }

    init(blocks: [RichBlock]) {
        self.blocks = blocks
    }

    var body: some View {
        RichTextBody(blocks: blocks, tone: tone, hugsWidth: hugsWidth) { link in
            if let url = resolve(link) { NSWorkspace.shared.open(url) }
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
        probing.insert(key)
        defer { probing.remove(key) }
        do {
            let record = try await model.fetch(key: "grades-probe-\(courseId)") { try await $0.assessmentRecord(courseId: courseId) }
            known[key] = !((record.items ?? []).isEmpty && (record.finalItems ?? []).isEmpty)
        } catch APIError.forbidden, APIError.notFound {
            known[key] = false
        } catch {
            // Offline or a passing failure: try again on the next visit.
        }
    }

    private static func key(_ courseId: Int, _ model: AppModel) -> String? {
        guard case .ready(let person) = model.authState else { return nil }
        return "\(person.personId)-\(courseId)"
    }
}
