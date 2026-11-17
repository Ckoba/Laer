import Foundation

/// A lecture-prep note from a notes folder the user picked, such as an Obsidian vault folder.
/// Laer only reads these files. The format is the brief contract in `docs/lecture-briefs.md`.
public struct LectureNote: Sendable, Hashable, Identifiable {
    public enum Status: String, Sendable, Hashable {
        case confirmed
        case unconfirmed
        /// A calendar block with no teaching behind it.
        case noTeaching = "no-teaching"
    }

    /// The path below the picked folder, which is also the identity.
    public var path: String
    public var version: Int?
    /// The local day, read as written.
    public var day: DateComponents?
    /// Minutes after local midnight.
    public var startMinute: Int?
    public var endMinute: Int?
    public var timeZone: TimeZone?
    public var courseTitle: String?
    public var courseId: Int?
    public var session: String?
    public var title: String?
    public var room: String?
    public var language: String?
    /// What the frontmatter says. `brief` holds what the file actually has.
    public var briefFlag: Bool?
    public var briefUpdated: Date?
    public var status: Status?
    public var brief: LectureBrief?

    public var id: String { path }

    public init(path: String) {
        self.path = path
    }

    /// The instant the calendar block starts, in the note's own time zone.
    public var start: Date? { instant(minute: startMinute) }
    public var end: Date? { instant(minute: endMinute) }

    func instant(minute: Int?) -> Date? {
        guard var parts = day else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone ?? .current
        parts.calendar = calendar
        parts.timeZone = calendar.timeZone
        parts.hour = (minute ?? 0) / 60
        parts.minute = (minute ?? 0) % 60
        return calendar.date(from: parts)
    }
}

/// The pre-lecture section of a note: an optional lead and its subsections, in file order.
public struct LectureBrief: Sendable, Hashable {
    public var sections: [BriefSection]

    public init(sections: [BriefSection]) {
        self.sections = sections
    }

    /// The short read for the card: the 15-minute subsection, else the first one with text.
    public var summary: BriefSection? {
        sections.first { $0.kind == .fifteenMinutes } ?? sections.first { !$0.body.isEmpty }
    }
}

public struct BriefSection: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// Text between the heading and the first subsection.
        case lead
        case fifteenMinutes
        case coreArgument
        case keyConcepts
        case linkToLastTime
        case examQuestions
        case questionForClass
        case missing
        case other
    }

    public var kind: Kind
    /// The heading as written, without the hashes. Nil for the lead.
    public var title: String?
    /// Markdown as written.
    public var body: String
    public var id: String { "\(title ?? "")|\(body.hashValue)" }

    public init(kind: Kind, title: String?, body: String) {
        self.kind = kind
        self.title = title
        self.body = body
    }

    /// The body as inline Markdown lines: bullets as "•", quote markers and blank runs dropped,
    /// wikilinks rewritten by `WikiLink.markdown`.
    public func displayText(linkScheme: String?) -> String {
        var lines: [String] = []
        for raw in body.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while line.hasPrefix(">") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            for marker in ["* ", "- ", "+ "] where line.hasPrefix(marker) {
                let indent = raw.prefix { $0 == " " || $0 == "\t" }.count >= 2 ? "    " : ""
                line = indent + "• " + line.dropFirst(marker.count)
                break
            }
            if line.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(line)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return WikiLink.markdown(lines.joined(separator: "\n"), scheme: linkScheme)
    }
}

public enum LectureNoteParser {
    public static let supportedVersion = 1
    static let briefHeadings = ["forberedelse før forelæsning", "pre-lecture brief"]
    static let kinds: [(prefixes: [String], kind: BriefSection.Kind)] = [
        (["hvis du kun har 15 minutter", "if you only have 15 minutes"], .fifteenMinutes),
        (["kerneargument", "core argument"], .coreArgument),
        (["nøglebegreber", "key concepts"], .keyConcepts),
        (["kobling til sidste gang", "link to last time"], .linkToLastTime),
        (["eksamensspørgsmål", "exam question"], .examQuestions),
        (["spørgsmål til timen", "question for class", "questions for class"], .questionForClass),
        (["mangler", "missing"], .missing),
    ]

    /// Nil unless the frontmatter says `type: lecture-prep`.
    public static func parse(_ text: String, path: String) -> LectureNote? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let (fields, bodyStart) = frontmatter(lines) else { return nil }
        guard fields["type"]?.lowercased() == "lecture-prep" else { return nil }
        var note = LectureNote(path: path)
        note.version = fields["laer"].flatMap { Int($0) }
        note.timeZone = fields["timezone"].flatMap { TimeZone(identifier: $0) }
        note.day = fields["date"].flatMap(day)
        note.startMinute = fields["start"].flatMap(minute)
        note.endMinute = fields["end"].flatMap(minute)
        note.courseTitle = nonEmpty(fields["course"])
        note.courseId = fields["itslearning_course_id"].flatMap { Int($0) }
        note.session = nonEmpty(fields["session"])
        note.title = nonEmpty(fields["title"])
        note.room = nonEmpty(fields["room"])
        note.language = nonEmpty(fields["lang"])
        note.briefFlag = fields["brief"].flatMap(bool)
        note.briefUpdated = fields["brief_updated"].flatMap(instant)
        note.status = fields["status"].flatMap { LectureNote.Status(rawValue: $0.lowercased()) }
        note.brief = brief(Array(lines[bodyStart...]))
        return note
    }

    // MARK: Frontmatter

    /// Flat `key: value` pairs between the opening and closing `---`, and the first body line.
    /// Nested YAML is not part of the contract and is skipped.
    static func frontmatter(_ lines: [String]) -> ([String: String], Int)? {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        var fields: [String: String] = [:]
        for index in 1..<lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces) == "---" { return (fields, index + 1) }
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty, !key.hasPrefix("#") else { continue }
            fields[key] = scalar(String(line[line.index(after: colon)...]))
        }
        return nil
    }

    /// A YAML scalar without its quotes or trailing comment.
    static func scalar(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if let quote = text.first, quote == "\"" || quote == "'" {
            let rest = text.dropFirst()
            if let close = rest.firstIndex(of: quote) { return String(rest[..<close]) }
            return String(rest)
        }
        if let comment = text.range(of: " #") { return text[..<comment.lowerBound].trimmingCharacters(in: .whitespaces) }
        return text
    }

    static func day(_ text: String) -> DateComponents? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        return DateComponents(year: parts[0], month: parts[1], day: parts[2])
    }

    static func minute(_ text: String) -> Int? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return parts[0] * 60 + parts[1]
    }

    static func bool(_ text: String) -> Bool? {
        switch text.lowercased() {
        case "true", "yes": true
        case "false", "no": false
        default: nil
        }
    }

    static func instant(_ text: String) -> Date? {
        try? Date(text, strategy: Date.ISO8601FormatStyle())
    }

    static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    // MARK: Brief section

    /// The brief section, from its H2 to the next H2. Nil when the note has none yet.
    static func brief(_ lines: [String]) -> LectureBrief? {
        var inFence = false
        var inBrief = false
        var sections: [BriefSection] = []
        var current: (kind: BriefSection.Kind, title: String?) = (.lead, nil)
        var buffer: [String] = []
        var found = false

        func flush() {
            let body = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if current.title != nil || !body.isEmpty {
                sections.append(BriefSection(kind: current.kind, title: current.title, body: body))
            }
            buffer = []
        }

        for line in lines {
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle() }
            if !inFence, let heading = heading(line, level: 2) {
                if inBrief { break }
                if briefHeadings.contains(normalized(heading)) {
                    inBrief = true
                    found = true
                }
                continue
            }
            guard inBrief else { continue }
            if !inFence, let heading = heading(line, level: 3) {
                flush()
                current = (kind(for: heading), heading)
                continue
            }
            buffer.append(line)
        }
        guard found else { return nil }
        flush()
        return LectureBrief(sections: sections)
    }

    static func heading(_ line: String, level: Int) -> String? {
        let marker = String(repeating: "#", count: level) + " "
        guard line.hasPrefix(marker) else { return nil }
        let text = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    static func kind(for heading: String) -> BriefSection.Kind {
        let text = normalized(heading)
        return kinds.first { $0.prefixes.contains { text.hasPrefix($0) } }?.kind ?? .other
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Finds the note for a lecture: same course, same local day, nearest start within an hour.
public enum LectureNoteMatcher {
    public static let window: TimeInterval = 60 * 60

    public static func note(for plan: PlanPreview, course: Course?, in notes: [LectureNote]) -> LectureNote? {
        guard let start = realDate(plan.start) else { return nil }
        return note(courseId: plan.courseId ?? course?.courseId, course: course, start: start, in: notes)
    }

    public static func note(for event: CalendarEvent, course: Course?, in notes: [LectureNote]) -> LectureNote? {
        guard let start = realDate(event.fromDate) else { return nil }
        return note(courseId: event.courseId ?? course?.courseId, course: course, start: start, in: notes)
    }

    /// Notes with a course ID match on it. Notes without one fall back to the course title.
    /// A start at local midnight is a plan with a day and no time: the day's one note matches.
    public static func note(courseId: Int?, course: Course?, start: Date, in notes: [LectureNote]) -> LectureNote? {
        let candidates = notes.filter { note in
            guard sameCourse(note, courseId: courseId, course: course) else { return false }
            guard let day = note.day else { return false }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = note.timeZone ?? .current
            let local = calendar.dateComponents([.year, .month, .day], from: start)
            return local.year == day.year && local.month == day.month && local.day == day.day
        }
        var best: (note: LectureNote, distance: TimeInterval)?
        for note in candidates where note.startMinute != nil {
            guard let noteStart = note.start else { continue }
            let distance = abs(noteStart.timeIntervalSince(start))
            guard distance <= window else { continue }
            if let current = best, current.distance < distance || (current.distance == distance && current.note.path <= note.path) { continue }
            best = (note, distance)
        }
        if let best { return best.note }
        let undated = candidates.filter { $0.startMinute == nil }
        if undated.count == 1 { return undated[0] }
        if isMidnight(start, in: candidates.first?.timeZone), candidates.count == 1 { return candidates[0] }
        return nil
    }

    static func sameCourse(_ note: LectureNote, courseId: Int?, course: Course?) -> Bool {
        if let noteId = note.courseId { return noteId == courseId }
        guard let title = note.courseTitle.map(normalizedTitle), !title.isEmpty, let course else { return false }
        return [course.shortTitle, course.displayTitle, course.title].map(normalizedTitle).contains(title)
    }

    static func isMidnight(_ date: Date, in zone: TimeZone?) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone ?? .current
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return parts.hour == 0 && parts.minute == 0
    }

    /// Case, accents, punctuation and spacing ignored.
    static func normalizedTitle(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let kept = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }
}

/// Obsidian `[[target|alias]]` links in brief text.
public enum WikiLink {
    /// Parentheses are escaped too, since an unbalanced one ends a Markdown link.
    static let linkAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "()"))

    /// Each wikilink becomes a Markdown link to `scheme:` plus the escaped target, so a view can
    /// open it, or plain text when `scheme` is nil.
    public static func markdown(_ text: String, scheme: String?) -> String {
        guard let pattern = try? NSRegularExpression(pattern: #"!?\[\[([^\]|#]+)(#[^\]|]*)?(?:\|([^\]]+))?\]\]"#) else { return text }
        var result = ""
        var cursor = text.startIndex
        let ns = text as NSString
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[cursor..<range.lowerBound]
            let target = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let alias = match.range(at: 3).location == NSNotFound ? nil : ns.substring(with: match.range(at: 3))
            let label = alias ?? (target as NSString).lastPathComponent
            let escapedLabel = label.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            if let scheme, let encoded = target.addingPercentEncoding(withAllowedCharacters: linkAllowed) {
                result += "[\(escapedLabel)](\(scheme):\(encoded))"
            } else {
                result += escapedLabel
            }
            cursor = range.upperBound
        }
        result += text[cursor...]
        return result
    }

    /// Where a link target may be below `folder`, most likely first. Vault links start at the
    /// vault root, the picked folder's parent, so a leading folder name is dropped; a bare file
    /// name is also tried in `Readings`. Targets that would leave the folder give none.
    public static func candidates(_ target: String, in folder: URL) -> [URL] {
        var parts = target.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else { return [] }
        if parts.count > 1, parts.first == folder.lastPathComponent { parts.removeFirst() }
        var result = [parts.reduce(folder) { $0.appendingPathComponent($1) }]
        if let name = parts.last, parts.count == 1 || parts.first != "Readings" {
            result.append(folder.appendingPathComponent("Readings").appendingPathComponent(name))
        }
        return result
    }
}
