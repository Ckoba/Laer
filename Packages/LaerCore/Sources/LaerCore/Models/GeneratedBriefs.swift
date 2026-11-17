import Foundation

// Briefs generated on the Mac from a lecture's saved readings. The model runs in the app;
// this file holds what can be tested without it: splitting text into chunks that fit the
// model's small context, grouping chunk notes for combining, merging their lists, and turning
// the result into the `LectureNote` shape the cards already show. See decision 0013.

/// The text of one saved reading.
public struct ReadingText: Sendable, Hashable {
    public var title: String
    public var text: String

    public init(title: String, text: String) {
        self.title = title
        self.text = text
    }
}

/// A piece of one reading small enough for one model request.
public struct ReadingChunk: Sendable, Hashable {
    public var title: String
    /// The chunk's position in its reading, from 0.
    public var index: Int
    public var text: String

    public init(title: String, index: Int, text: String) {
        self.title = title
        self.index = index
        self.text = text
    }
}

/// A term and what it means in the reading.
public struct BriefConcept: Codable, Sendable, Hashable {
    public var term: String
    public var definition: String

    public init(term: String, definition: String) {
        self.term = term
        self.definition = definition
    }
}

/// What the model wrote about one chunk, or about a group of chunk notes when combining.
public struct ChunkDigest: Codable, Sendable, Hashable {
    public var summary: String
    public var keyPoints: [String]
    public var concepts: [BriefConcept]

    public init(summary: String, keyPoints: [String], concepts: [BriefConcept]) {
        self.summary = summary
        self.keyPoints = keyPoints
        self.concepts = concepts
    }

    /// The digest as prompt text for the combining step.
    public var promptText: String {
        var lines = [summary.trimmingCharacters(in: .whitespacesAndNewlines)]
        lines += keyPoints.map { "- " + $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        lines += concepts.map { "- \($0.term): \($0.definition)" }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// Splits and groups text for a model with a small context window. Budgets are in characters,
/// a conservative stand-in for tokens: about four characters per token for English and a little
/// fewer for Danish.
public enum BriefChunker {
    /// About 1,200 to 1,600 tokens of reading, leaving room for instructions and the answer in a
    /// 4,096-token window.
    public static let chunkCharacters = 5_000
    /// Chunks summarised per lecture at most, so a long reading list stays a few minutes of work.
    public static let maxChunks = 12

    /// Whitespace runs folded, hyphenated line breaks joined, and blank-line paragraphs kept.
    public static func normalized(_ text: String) -> String {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let paragraphs = unified.components(separatedBy: "\n\n")
        return paragraphs.map { paragraph in
            paragraph
                .replacingOccurrences(of: "-\n", with: "")
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    /// Chunks of at most `limit` characters that break at paragraphs, then sentences, then words,
    /// and only inside a word when one word is longer than the limit. Empty text gives none.
    public static func chunks(_ text: String, limit: Int = chunkCharacters) -> [String] {
        precondition(limit > 0)
        let clean = normalized(text)
        guard !clean.isEmpty else { return [] }
        var result: [String] = []
        var current = ""

        func append(_ piece: String, separator: String) {
            if current.isEmpty {
                current = piece
            } else if current.count + separator.count + piece.count <= limit {
                current += separator + piece
            } else {
                result.append(current)
                current = piece
            }
        }

        for paragraph in clean.components(separatedBy: "\n\n") {
            if paragraph.count <= limit {
                append(paragraph, separator: "\n\n")
                continue
            }
            for sentence in sentences(paragraph) {
                if sentence.count <= limit {
                    append(sentence, separator: " ")
                    continue
                }
                for word in sentence.split(separator: " ").map(String.init) {
                    var rest = Substring(word)
                    while rest.count > limit {
                        append(String(rest.prefix(limit)), separator: " ")
                        rest = rest.dropFirst(limit)
                    }
                    if !rest.isEmpty { append(String(rest), separator: " ") }
                }
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Sentences ending in ".", "!" or "?" followed by a space, with their punctuation.
    static func sentences(_ paragraph: String) -> [String] {
        var result: [String] = []
        var current = ""
        var previous: Character?
        for character in paragraph {
            if character == " ", let previous, ".!?".contains(previous) {
                result.append(current)
                current = ""
            } else {
                current.append(character)
            }
            previous = character
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// The chunks to summarise for a lecture, in reading order. When there are more than `limit`,
    /// every reading keeps its first chunk and the rest are spread evenly through each reading,
    /// shared out in proportion to its length.
    public static func plan(_ readings: [ReadingText], chunkLimit: Int = chunkCharacters, limit: Int = maxChunks) -> [ReadingChunk] {
        let perReading = readings.map { reading in
            chunks(reading.text, limit: chunkLimit).enumerated().map { ReadingChunk(title: reading.title, index: $0.offset, text: $0.element) }
        }.filter { !$0.isEmpty }
        let total = perReading.reduce(0) { $0 + $1.count }
        guard total > limit else { return perReading.flatMap { $0 } }
        guard perReading.count < limit else {
            return perReading.prefix(limit).map { $0[0] }
        }
        // Each reading gets one chunk; the remaining slots go by length, largest remainder first.
        let spare = limit - perReading.count
        let extraTotal = perReading.reduce(0) { $0 + $1.count - 1 }
        var shares = perReading.map { extraTotal == 0 ? 0.0 : Double(($0.count - 1) * spare) / Double(extraTotal) }
        var counts = shares.map { Int($0) }
        var left = spare - counts.reduce(0, +)
        while left > 0 {
            guard let best = shares.indices.max(by: { shares[$0] - Double(counts[$0]) < shares[$1] - Double(counts[$1]) }) else { break }
            counts[best] += 1
            shares[best] = Double(counts[best])
            left -= 1
        }
        return zip(perReading, counts).flatMap { chunks, extra in
            [chunks[0]] + spread(Array(chunks.dropFirst()), count: min(extra, chunks.count - 1))
        }
    }

    /// `count` items spaced evenly through `items`, in order.
    static func spread<T>(_ items: [T], count: Int) -> [T] {
        guard count > 0, !items.isEmpty else { return [] }
        guard count < items.count else { return items }
        return (0..<count).map { items[($0 * items.count + items.count / 2) / count] }
    }

    /// Consecutive groups whose combined prompt text stays within `limit` characters. A digest
    /// longer than the limit forms a group on its own, so every digest is used once.
    public static func groups(_ digests: [ChunkDigest], limit: Int = chunkCharacters) -> [[ChunkDigest]] {
        var result: [[ChunkDigest]] = []
        var current: [ChunkDigest] = []
        var size = 0
        for digest in digests {
            let length = digest.promptText.count + 2
            if !current.isEmpty, size + length > limit {
                result.append(current)
                current = []
                size = 0
            }
            current.append(digest)
            size += length
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

/// Merges what the model wrote without asking it again.
public enum BriefMerger {
    /// The first definition of each term, in first-seen order, ignoring case, accents and punctuation.
    /// A second term with the same definition is a synonym and is dropped too.
    public static func concepts(_ lists: [[BriefConcept]], limit: Int = 8) -> [BriefConcept] {
        var seen = Set<String>()
        var definitions = Set<String>()
        var result: [BriefConcept] = []
        for concept in lists.flatMap({ $0 }) {
            let term = concept.term.trimmingCharacters(in: .whitespacesAndNewlines)
            let definition = concept.definition.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = LectureNoteMatcher.normalizedTitle(term)
            guard !key.isEmpty, !definition.isEmpty, seen.insert(key).inserted,
                  definitions.insert(LectureNoteMatcher.normalizedTitle(definition)).inserted else { continue }
            result.append(BriefConcept(term: term, definition: definition))
            if result.count == limit { break }
        }
        return result
    }

    /// Lines with duplicates and blanks dropped, in first-seen order.
    public static func lines(_ lists: [[String]], limit: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for line in lists.flatMap({ $0 }) {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = LectureNoteMatcher.normalizedTitle(text)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(text)
            if result.count == limit { break }
        }
        return result
    }

    /// The first `limit` sentences, on one line. The small model sometimes copies its input
    /// instead of summarising; this keeps a card readable when it does.
    public static func sentences(_ text: String, limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return BriefChunker.sentences(flat).prefix(limit).joined(separator: " ")
    }

    /// A digest of several, for when the model cannot combine them: summaries joined, lists merged.
    public static func combined(_ digests: [ChunkDigest]) -> ChunkDigest {
        ChunkDigest(
            summary: digests.map { $0.summary.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " "),
            keyPoints: lines(digests.map(\.keyPoints), limit: 8),
            concepts: concepts(digests.map(\.concepts))
        )
    }
}

extension LectureNote {
    /// True for a brief made on this Mac rather than read from the notes folder.
    public var isGenerated: Bool { path.hasPrefix("laer-generated/") }
}

/// A brief generated on this Mac for one lecture plan, kept in Laer's own storage.
public struct GeneratedBrief: Codable, Sendable, Hashable, Identifiable {
    public var planId: Int
    public var courseId: Int?
    public var lectureTitle: String?
    /// Identifies the saved files it was made from, so a newer copy of a reading makes a new brief.
    public var sourceKey: String
    public var readingTitles: [String]
    /// "da", "en" or another ISO 639-1 code, as detected from the readings.
    public var language: String?
    public var generatedAt: Date
    public var summary: String
    public var keyQuestions: [String]
    public var concepts: [BriefConcept]

    public var id: Int { planId }

    public init(planId: Int, courseId: Int?, lectureTitle: String?, sourceKey: String, readingTitles: [String],
                language: String?, generatedAt: Date, summary: String, keyQuestions: [String], concepts: [BriefConcept]) {
        self.planId = planId
        self.courseId = courseId
        self.lectureTitle = lectureTitle
        self.sourceKey = sourceKey
        self.readingTitles = readingTitles
        self.language = language
        self.generatedAt = generatedAt
        self.summary = summary
        self.keyQuestions = keyQuestions
        self.concepts = concepts
    }

    /// The key for a set of saved readings: each reading's ID, size and save time, in a fixed order.
    public static func sourceKey(_ assets: [LocalAsset]) -> String {
        let parts = assets.sorted { $0.id < $1.id }.map { "\($0.id)|\($0.byteCount)|\(Int($0.downloadedAt.timeIntervalSince1970))" }
        return StableHash.hex(parts.joined(separator: "\n"), length: 32)
    }

    var isDanish: Bool { language == "da" }

    /// Headings in the brief contract's vocabulary, so the parser and the cards treat them alike.
    var headings: (lead: String, summary: String, concepts: String, questions: String) {
        isDanish
            ? ("Forberedelse før forelæsning", "Hvis du kun har 15 minutter", "Nøglebegreber", "Spørgsmål til timen")
            : ("Pre-lecture brief", "If you only have 15 minutes", "Key concepts", "Questions for class")
    }

    var leadText: String {
        let count = readingTitles.count
        if isDanish {
            return "Lavet på denne Mac ud fra \(count == 1 ? "1 læsning" : "\(count) læsninger"). Tjek op mod læsningerne."
        }
        return "Made on this Mac from \(count == 1 ? "1 reading" : "\(count) readings"). Check it against the readings."
    }

    var sections: [BriefSection] {
        let names = headings
        var result = [
            BriefSection(kind: .lead, title: nil, body: "> " + leadText),
            BriefSection(kind: .fifteenMinutes, title: names.summary, body: summary.trimmingCharacters(in: .whitespacesAndNewlines)),
        ]
        if !concepts.isEmpty {
            let body = concepts.map { "* **\(Self.inline($0.term))** – \(Self.inline($0.definition))" }.joined(separator: "\n")
            result.append(BriefSection(kind: .keyConcepts, title: names.concepts, body: body))
        }
        if !keyQuestions.isEmpty {
            let body = keyQuestions.map { "* " + Self.inline($0) }.joined(separator: "\n")
            result.append(BriefSection(kind: .questionForClass, title: names.questions, body: body))
        }
        return result
    }

    /// The brief as a note the cards show like one from the notes folder. The path is not a file.
    public var lectureNote: LectureNote {
        var note = LectureNote(path: "laer-generated/\(planId)")
        note.version = LectureNoteParser.supportedVersion
        note.courseId = courseId
        note.title = lectureTitle
        note.language = language
        note.briefFlag = true
        note.briefUpdated = generatedAt
        note.brief = LectureBrief(sections: sections)
        return note
    }

    /// A note in the brief contract's format, for the opt-in copy in the notes folder. Model text
    /// is kept on one line per item and wikilink brackets are removed, so it cannot add headings,
    /// frontmatter or links.
    public func markdown(start: Date?, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var front = ["---", "type: lecture-prep", "laer: \(LectureNoteParser.supportedVersion)", "generator: laer-on-device"]
        if let start {
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: start)
            if let year = parts.year, let month = parts.month, let day = parts.day {
                front.append(String(format: "date: %04d-%02d-%02d", year, month, day))
            }
            if let hour = parts.hour, let minute = parts.minute {
                front.append(String(format: "start: \"%02d:%02d\"", hour, minute))
            }
            front.append("timezone: \(timeZone.identifier)")
        }
        if let courseId { front.append("itslearning_course_id: \(courseId)") }
        if let lectureTitle { front.append("title: \"\(Self.inline(lectureTitle).replacingOccurrences(of: "\"", with: "'"))\"") }
        if let language { front.append("lang: \(language)") }
        front.append("brief: true")
        front.append("brief_updated: \(generatedAt.formatted(Date.ISO8601FormatStyle()))")
        front.append("---")
        var lines = front + ["", "## " + headings.lead, ""]
        for section in sections {
            if let title = section.title { lines += ["### " + title, ""] }
            lines += [section.kind == .fifteenMinutes ? Self.inline(section.body) : section.body, ""]
        }
        return lines.joined(separator: "\n")
    }

    /// Model text on one line, without Markdown headings, fences or wikilinks.
    static func inline(_ text: String) -> String {
        text.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")
            .replacingOccurrences(of: "```", with: "")
            .split(whereSeparator: { $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }
            .map { line in String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "---" }
            .joined(separator: " ")
    }
}
