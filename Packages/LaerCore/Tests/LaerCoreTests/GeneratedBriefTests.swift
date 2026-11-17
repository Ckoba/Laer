import Foundation
import Testing
@testable import LaerCore

// Synthetic text only. No real readings or course content.

private func words(_ count: Int, prefix: String = "word") -> String {
    (1...count).map { "\(prefix)\($0)" }.joined(separator: " ")
}

private func sentences(_ count: Int) -> String {
    (1...count).map { "Sentence \($0) says something about the example topic." }.joined(separator: " ")
}

struct BriefChunkerTests {
    @Test func emptyAndWhitespaceTextGiveNoChunks() {
        #expect(BriefChunker.chunks("").isEmpty)
        #expect(BriefChunker.chunks(" \n\n \t ").isEmpty)
    }

    @Test func shortTextIsOneNormalizedChunk() {
        let chunks = BriefChunker.chunks("An  example\nline with a hyphen-\nated word.\n\n\n\nA second   paragraph.", limit: 500)
        #expect(chunks == ["An example line with a hyphenated word.\n\nA second paragraph."])
    }

    @Test func everyChunkFitsAndNothingIsLost() {
        let paragraphs = (1...30).map { _ in sentences(6) }
        let text = paragraphs.joined(separator: "\n\n")
        for limit in [80, 300, 1_000, 5_000] {
            let chunks = BriefChunker.chunks(text, limit: limit)
            #expect(chunks.allSatisfy { $0.count <= limit && !$0.isEmpty })
            let original = BriefChunker.normalized(text).split(whereSeparator: \.isWhitespace)
            let rejoined = chunks.joined(separator: " ").split(whereSeparator: \.isWhitespace)
            #expect(rejoined == original)
        }
    }

    @Test func breaksAtParagraphsBeforeSentences() {
        let first = sentences(3)
        let second = sentences(3)
        let chunks = BriefChunker.chunks(first + "\n\n" + second, limit: first.count + 5)
        #expect(chunks == [first, second])
    }

    @Test func longParagraphBreaksAtSentenceEnds() {
        let chunks = BriefChunker.chunks(sentences(20), limit: 200)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.hasSuffix(".") })
    }

    @Test func overlongWordIsCut() {
        let word = String(repeating: "x", count: 250)
        let chunks = BriefChunker.chunks("start \(word) end", limit: 100)
        #expect(chunks.allSatisfy { $0.count <= 100 })
        #expect(chunks.joined().replacingOccurrences(of: " ", with: "") == "start\(word)end")
    }

    @Test func planKeepsEverythingUnderTheLimit() {
        let readings = [ReadingText(title: "A", text: sentences(10)), ReadingText(title: "Empty", text: "  "), ReadingText(title: "B", text: sentences(10))]
        let plan = BriefChunker.plan(readings, chunkLimit: 200, limit: 100)
        #expect(Set(plan.map(\.title)) == ["A", "B"])
        #expect(plan.filter { $0.title == "A" }.map(\.index) == Array(0..<plan.filter { $0.title == "A" }.count))
    }

    @Test func planSamplesLongReadingsFairly() {
        let long = ReadingText(title: "Long", text: (1...40).map { _ in sentences(3) }.joined(separator: "\n\n"))
        let short = ReadingText(title: "Short", text: sentences(3))
        let plan = BriefChunker.plan([long, short], chunkLimit: 200, limit: 6)
        #expect(plan.count == 6)
        // Each reading keeps its opening chunk; the long one gets the spare slots, spread out.
        #expect(plan.contains(ReadingChunk(title: "Short", index: 0, text: BriefChunker.chunks(short.text, limit: 200)[0])))
        let longIndices = plan.filter { $0.title == "Long" }.map(\.index)
        #expect(longIndices.first == 0)
        #expect(longIndices == longIndices.sorted())
        #expect(longIndices.count == 5)
        #expect((longIndices.last ?? 0) > 20)
    }

    @Test func planWithMoreReadingsThanSlotsTakesEachOpening() {
        let readings = (1...5).map { ReadingText(title: "R\($0)", text: sentences(20)) }
        let plan = BriefChunker.plan(readings, chunkLimit: 200, limit: 3)
        #expect(plan.map(\.title) == ["R1", "R2", "R3"])
        #expect(plan.allSatisfy { $0.index == 0 })
    }

    @Test func groupsStayWithinBudgetAndKeepOrder() {
        let digests = (1...10).map { ChunkDigest(summary: words(20, prefix: "s\($0)-"), keyPoints: ["Point \($0)"], concepts: []) }
        let groups = BriefChunker.groups(digests, limit: 400)
        #expect(groups.count > 1)
        #expect(groups.flatMap { $0 } == digests)
        for group in groups where group.count > 1 {
            #expect(group.reduce(0) { $0 + $1.promptText.count + 2 } <= 400)
        }
    }

    @Test func oversizedDigestStandsAlone() {
        let big = ChunkDigest(summary: words(200), keyPoints: [], concepts: [])
        let small = ChunkDigest(summary: "Short.", keyPoints: [], concepts: [])
        #expect(BriefChunker.groups([small, big, small], limit: 100) == [[small], [big], [small]])
    }
}

struct BriefMergerTests {
    @Test func conceptsKeepFirstDefinitionIgnoringCaseAndAccents() {
        let merged = BriefMerger.concepts([
            [BriefConcept(term: "Example Term", definition: "First."), BriefConcept(term: "", definition: "No term.")],
            [BriefConcept(term: "example térm", definition: "Second."), BriefConcept(term: "Other", definition: "  ")],
            [BriefConcept(term: "Third idea", definition: "Kept.")],
        ])
        #expect(merged == [BriefConcept(term: "Example Term", definition: "First."), BriefConcept(term: "Third idea", definition: "Kept.")])
    }

    @Test func synonymsWithTheSameDefinitionCollapse() {
        let merged = BriefMerger.concepts([[BriefConcept(term: "Shared good", definition: "Something many use."),
                                            BriefConcept(term: "Common resource", definition: "something many use")]])
        #expect(merged.map(\.term) == ["Shared good"])
    }

    @Test func summaryIsCappedAtWholeSentences() {
        #expect(BriefMerger.sentences("One. Two!\nThree? Four. Five", limit: 3) == "One. Two! Three?")
        #expect(BriefMerger.sentences("Only one", limit: 5) == "Only one")
    }

    @Test func linesDropDuplicatesAndStopAtLimit() {
        let merged = BriefMerger.lines([["What is A?", " what is a? ", ""], ["Why B?", "How C?"]], limit: 2)
        #expect(merged == ["What is A?", "Why B?"])
    }

    @Test func combinedFallbackJoinsSummaries() {
        let combined = BriefMerger.combined([
            ChunkDigest(summary: "One.", keyPoints: ["A"], concepts: [BriefConcept(term: "X", definition: "x")]),
            ChunkDigest(summary: " Two. ", keyPoints: ["a", "B"], concepts: [BriefConcept(term: "x", definition: "again")]),
        ])
        #expect(combined.summary == "One. Two.")
        #expect(combined.keyPoints == ["A", "B"])
        #expect(combined.concepts == [BriefConcept(term: "X", definition: "x")])
    }
}

struct GeneratedBriefTests {
    let brief = GeneratedBrief(
        planId: 601, courseId: 11, lectureTitle: "Week one", sourceKey: "k", readingTitles: ["Example.pdf"],
        language: "en", generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        summary: "The reading argues an example.\n## Not a heading",
        keyQuestions: ["Why does the example hold?"],
        concepts: [BriefConcept(term: "Example", definition: "A [[made-up]] thing.")]
    )

    @Test func showsLikeAFolderBrief() {
        let note = brief.lectureNote
        #expect(note.courseId == 11)
        #expect(note.brief?.summary?.kind == .fifteenMinutes)
        #expect(note.brief?.sections.map(\.kind) == [.lead, .fifteenMinutes, .keyConcepts, .questionForClass])
    }

    @Test func danishBriefUsesDanishHeadings() {
        var danish = brief
        danish.language = "da"
        #expect(danish.lectureNote.brief?.sections.compactMap(\.title) == ["Hvis du kun har 15 minutter", "Nøglebegreber", "Spørgsmål til timen"])
    }

    @Test func markdownRoundTripsThroughTheParser() throws {
        let zone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let text = brief.markdown(start: start, timeZone: zone)
        let note = try #require(LectureNoteParser.parse(text, path: "Laer/example.md"))
        #expect(note.courseId == 11)
        #expect(note.timeZone == zone)
        #expect(note.start == Calendar.current.date(bySetting: .second, value: 0, of: start))
        #expect(note.brief?.sections.map(\.kind) == [.lead, .fifteenMinutes, .keyConcepts, .questionForClass])
        // Model text cannot add headings or wikilinks to the note.
        #expect(!text.contains("[["))
        #expect(!text.contains("\n## Not"))
        #expect(note.brief?.summary?.body == "The reading argues an example. Not a heading")
    }

    @Test func sourceKeyChangesWithANewerCopy() {
        let asset = LocalAsset(id: "LearningToolElement-702", relativePath: "a", displayName: "a.pdf", byteCount: 10, contentType: nil, downloadedAt: Date(timeIntervalSince1970: 1))
        var newer = asset
        newer.downloadedAt = Date(timeIntervalSince1970: 2)
        let other = LocalAsset(id: "LearningToolElement-703", relativePath: "b", displayName: "b.pdf", byteCount: 5, contentType: nil, downloadedAt: Date(timeIntervalSince1970: 1))
        #expect(GeneratedBrief.sourceKey([asset, other]) == GeneratedBrief.sourceKey([other, asset]))
        #expect(GeneratedBrief.sourceKey([asset, other]) != GeneratedBrief.sourceKey([newer, other]))
    }

    @Test func storeSavesAndReloads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LaerBriefTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try await GeneratedBriefStore(rootDirectory: root, accountKey: "example").save(brief)
        let reloaded = await GeneratedBriefStore(rootDirectory: root, accountKey: "example").all()
        #expect(reloaded[601] == brief)
        let other = await GeneratedBriefStore(rootDirectory: root, accountKey: "other").all()
        #expect(other.isEmpty)
    }
}
