import AppKit
import Foundation
import LaerCore
import NaturalLanguage
import PDFKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Plain text from a saved reading, read on the calling thread. PDFs through PDFKit, word
/// processor and text files through AppKit's readers. Slides are converted to PDF first by the caller.
enum ReadingExtractor {
    /// Enough for any reading; the chunk plan samples longer ones anyway.
    static let maxCharacters = 400_000
    static let slideExtensions: Set<String> = ["ppt", "pptx", "key", "odp"]
    static let documentExtensions: Set<String> = ["doc", "docx", "rtf", "odt", "txt", "md", "markdown"]

    static func isSlides(_ url: URL) -> Bool { slideExtensions.contains(url.pathExtension.lowercased()) }

    static func canRead(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "pdf" || isSlides(url) || documentExtensions.contains(ext)
    }

    static func text(of url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        let text: String?
        if ext == "pdf" || isSlides(url) {
            text = PDFDocument(url: url)?.string
        } else if ["txt", "md", "markdown"].contains(ext) {
            text = try? String(contentsOf: url, encoding: .utf8)
        } else if documentExtensions.contains(ext) {
            text = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        } else {
            text = nil
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return String(text.prefix(maxCharacters))
    }

    /// The dominant language as an ISO 639-1 code, such as "da" or "en".
    static func language(of texts: [String]) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(texts.map { String($0.prefix(4_000)) }.joined(separator: "\n"))
        return recognizer.dominantLanguage?.rawValue
    }
}

/// Whether Apple's on-device model can be used now. False before macOS 26 and when Apple
/// Intelligence is off, not supported or still downloading.
enum OnDeviceModel {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    /// A short reason category for the log. Never includes content.
    static var unavailableReason: String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return "available"
            case .unavailable(.deviceNotEligible): return "device not eligible"
            case .unavailable(.appleIntelligenceNotEnabled): return "apple intelligence off"
            case .unavailable(.modelNotReady): return "model not ready"
            case .unavailable: return "unavailable"
            }
        }
        #endif
        return "requires macOS 26"
    }
}

/// The brief as the model writes it, before Laer adds the lecture's details.
struct BriefDraft: Sendable {
    var summary: String
    var keyQuestions: [String]
    var concepts: [BriefConcept]
}

enum OnDeviceBriefError: Error {
    case unavailable
    case nothingUsable
}

#if canImport(FoundationModels)
@available(macOS 26, *)
@Generable
struct ConceptOutput {
    @Guide(description: "A term the text uses, as written in the text")
    var term: String
    @Guide(description: "What the term means in this text, in one short sentence")
    var definition: String
}

@available(macOS 26, *)
@Generable
struct ChunkNotesOutput {
    @Guide(description: "Two or three sentences on what this text argues or explains")
    var summary: String
    @Guide(description: "The most important points, each one short sentence", .maximumCount(3))
    var keyPoints: [String]
    @Guide(description: "Terms the text itself explains, with that explanation. Leave out terms the text only names. Empty when there are none.", .maximumCount(3))
    var concepts: [ConceptOutput]
}

@available(macOS 26, *)
@Generable
struct LectureBriefOutput {
    @Guide(description: "What a student who has only 15 minutes must know before the lecture: the main argument in three to five sentences")
    var summary: String
    @Guide(description: "Questions the lecture is likely to discuss, each answerable from the readings", .count(3...4))
    var keyQuestions: [String]
    @Guide(description: "The key concepts the notes explain, as the notes explain them. No general words.", .maximumCount(6))
    var concepts: [ConceptOutput]
}

/// Map, reduce and write: each chunk is summarised in its own session, notes are combined in
/// groups until they fit one request, and the brief is written from the combined notes. A new
/// session per request keeps every call inside the model's small context window.
@available(macOS 26, *)
struct OnDeviceBriefWriter {
    var language: String?
    var options = GenerationOptions(sampling: .greedy)

    private var languageName: String {
        guard let language, let name = Locale(identifier: "en").localizedString(forLanguageCode: language) else {
            return "the same language as the text"
        }
        return name
    }

    func write(_ chunks: [ReadingChunk], lectureTitle: String?) async throws -> BriefDraft {
        guard OnDeviceModel.isAvailable else { throw OnDeviceBriefError.unavailable }
        var digests: [ChunkDigest] = []
        for chunk in chunks {
            try Task.checkCancellation()
            digests += await digest(chunk)
        }
        guard !digests.isEmpty else { throw OnDeviceBriefError.nothingUsable }
        // Combine until one request can hold every note. Each round at least halves the count.
        var rounds = 0
        while digests.count > 1, BriefChunker.groups(digests).count > 1, rounds < 4 {
            try Task.checkCancellation()
            var next: [ChunkDigest] = []
            for group in BriefChunker.groups(digests) {
                next.append(group.count == 1 ? group[0] : await combine(group))
            }
            digests = next
            rounds += 1
        }
        try Task.checkCancellation()
        return try await brief(from: digests, lectureTitle: lectureTitle)
    }

    /// Notes on one chunk. A chunk that overflows the window is halved once; one the model
    /// declines is skipped, so one passage never blocks the brief.
    private func digest(_ chunk: ReadingChunk, canSplit: Bool = true) async -> [ChunkDigest] {
        let session = LanguageModelSession(instructions: """
            You help a university student prepare for a lecture. You get one excerpt from a course \
            reading. Describe only what the excerpt says. Write in \(languageName).
            """)
        do {
            let response = try await session.respond(to: "Reading: \(chunk.title)\n\n\(chunk.text)", generating: ChunkNotesOutput.self, options: options)
            return [Self.digest(response.content)]
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize where canSplit {
            var result: [ChunkDigest] = []
            for half in BriefChunker.chunks(chunk.text, limit: max(chunk.text.count / 2 + 1, 200)) {
                result += await digest(ReadingChunk(title: chunk.title, index: chunk.index, text: half), canSplit: false)
            }
            return result
        } catch {
            BriefLog.log.notice("chunk skipped: \(Self.category(error), privacy: .public)")
            return []
        }
    }

    private func combine(_ group: [ChunkDigest]) async -> ChunkDigest {
        let session = LanguageModelSession(instructions: """
            You combine notes on parts of course readings into one set of notes, keeping the main \
            argument and dropping repetition. Use only the notes. Write in \(languageName).
            """)
        let notes = group.map(\.promptText).joined(separator: "\n\n")
        do {
            return Self.digest(try await session.respond(to: notes, generating: ChunkNotesOutput.self, options: options).content)
        } catch {
            BriefLog.log.notice("combine fell back: \(Self.category(error), privacy: .public)")
            return BriefMerger.combined(group)
        }
    }

    private func brief(from digests: [ChunkDigest], lectureTitle: String?) async throws -> BriefDraft {
        let session = LanguageModelSession(instructions: """
            You write a short pre-lecture brief for a university student from notes on the lecture's \
            readings. Be concrete and faithful to the notes; do not add facts. Write in \(languageName).
            """)
        let notes = digests.map(\.promptText).joined(separator: "\n\n")
        let prompt = (lectureTitle.map { "Lecture: \($0)\n\n" } ?? "") + "Notes on the readings:\n\(notes)"
        do {
            let output = try await session.respond(to: prompt, generating: LectureBriefOutput.self, options: options).content
            return BriefDraft(
                summary: BriefMerger.sentences(output.summary, limit: 5),
                keyQuestions: BriefMerger.lines([output.keyQuestions], limit: 4),
                concepts: BriefMerger.concepts([output.concepts.map(Self.concept), digests.flatMap(\.concepts)], limit: 6)
            )
        } catch {
            // Notes without questions are still worth showing.
            BriefLog.log.notice("brief fell back: \(Self.category(error), privacy: .public)")
            let combined = BriefMerger.combined(digests)
            guard !combined.summary.isEmpty else { throw error }
            return BriefDraft(summary: combined.summary, keyQuestions: [], concepts: Array(combined.concepts.prefix(6)))
        }
    }

    private static func concept(_ output: ConceptOutput) -> BriefConcept {
        BriefConcept(term: output.term, definition: output.definition)
    }

    private static func digest(_ output: ChunkNotesOutput) -> ChunkDigest {
        ChunkDigest(summary: output.summary, keyPoints: output.keyPoints, concepts: output.concepts.map(concept))
    }

    static func category(_ error: Error) -> String {
        guard let error = error as? LanguageModelSession.GenerationError else {
            return error is CancellationError ? "cancelled" : "other"
        }
        switch error {
        case .exceededContextWindowSize: return "context window"
        case .guardrailViolation: return "guardrail"
        case .unsupportedLanguageOrLocale: return "language"
        case .assetsUnavailable: return "assets unavailable"
        case .rateLimited: return "rate limited"
        case .concurrentRequests: return "concurrent requests"
        case .refusal: return "refusal"
        case .decodingFailure: return "decoding"
        case .unsupportedGuide: return "unsupported guide"
        @unknown default: return "generation"
        }
    }
}
#endif
