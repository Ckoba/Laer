import Foundation
import Testing
@testable import LaerCore

// Synthetic notes in the shape of the brief contract. No real course content.

private let danishNote = """
---
type: lecture-prep          # only parse notes with this type
laer: 1
date: 2026-03-10
start: "08:00"
end: "10:00"
timezone: Europe/Berlin
course: "Eksempelkursus i politik"
itslearning_course_id: 1001
session: "9"
title: "Eksempel: politik og marked"
room: "R1"
lang: da
brief: true
brief_updated: 2026-03-10T07:01:00+01:00
status: confirmed
---

# 9 - Eksempel

- Kalenderblok: **08:00–10:00**

## Obligatorisk læsning / forberedelse

- Forfatter (2020): [[uni/Readings/1__Forfatter 2020.pdf|Forfatter 2020.pdf]].

## Notebook-resumé

### Nøglebegreber og definitioner

- Not part of the brief.

## Forberedelse før forelæsning

> Genereret fra eksempellæsninger. Tjek op mod læsningerne.

### Hvis du kun har 15 minutter

Læs afsnit 2 i [[uni/Readings/1__Forfatter 2020.pdf|Forfatter 2020]].

### Kerneargumenter (5 punkter)

* **Forfatter (2020)** argumenterer for et eksempel.

### Nøglebegreber

* **Begreb** – en definition.

```
## Not a heading inside a fence
```

### Spørgsmål til timen

Hvad er pointen?

## Noter

Mine egne noter.

## Kilder

Eksempelkilde.
"""

private let englishNote = """
---
type: lecture-prep
laer: 1
date: 2026-03-10
start: "16:00"
end: "18:00"
timezone: Europe/Berlin
course: "Example Economics"
itslearning_course_id: 1002
session: ""
title: "Exercises"
lang: en
brief: true
status: unconfirmed
---

# Exercises

## Pre-lecture brief

### If you only have 15 minutes

Skim problem set 3.

### Missing

- A reading that was not available.

## Notes
"""

private let leadOnlyNote = """
---
type: lecture-prep
date: 2026-03-12
start: "14:00"
end: "16:00"
timezone: Europe/Berlin
course: "Example Organisation"
itslearning_course_id: 1003
brief: true
status: no-teaching
---

## Forberedelse før forelæsning

> Tjekket torsdag kl. 11:58.

- Der er ingen plan for i dag.

## Noter
"""

private let noBriefNote = """
---
date: 2026-03-24
course: "Example Economics"
type: lecture-prep
timezone: Europe/Berlin
brief: false
---

# Later lecture

## Required reading

- Something.
"""

private func instant(_ text: String) -> Date { try! Date(text, strategy: Date.ISO8601FormatStyle()) }

private func plan(_ id: Int, course: Int?, start: String?, stop: String? = nil) -> PlanPreview {
    var parts = ["\"id\":\(id)"]
    if let course { parts.append("\"courseId\":\(course)") }
    if let start { parts.append("\"start\":\"\(start)\"") }
    if let stop { parts.append("\"stop\":\"\(stop)\"") }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = APIDate.decoding
    return try! decoder.decode(PlanPreview.self, from: Data("{\(parts.joined(separator: ","))}".utf8))
}

@Suite struct LectureNoteParserTests {
    @Test func readsFrontmatter() throws {
        let note = try #require(LectureNoteParser.parse(danishNote, path: "Courses/A/Lectures/a.md"))
        #expect(note.version == 1)
        #expect(note.day == DateComponents(year: 2026, month: 3, day: 10))
        #expect(note.startMinute == 8 * 60)
        #expect(note.endMinute == 10 * 60)
        #expect(note.timeZone?.identifier == "Europe/Berlin")
        #expect(note.courseTitle == "Eksempelkursus i politik")
        #expect(note.courseId == 1001)
        #expect(note.session == "9")
        #expect(note.title == "Eksempel: politik og marked")
        #expect(note.room == "R1")
        #expect(note.language == "da")
        #expect(note.briefFlag == true)
        #expect(note.briefUpdated == instant("2026-03-10T06:01:00Z"))
        #expect(note.status == .confirmed)
        #expect(note.start == instant("2026-03-10T07:00:00Z"))
        #expect(note.end == instant("2026-03-10T09:00:00Z"))
    }

    @Test func readsTheBriefSectionOnly() throws {
        let brief = try #require(LectureNoteParser.parse(danishNote, path: "a.md")?.brief)
        #expect(brief.sections.map(\.kind) == [.lead, .fifteenMinutes, .coreArgument, .keyConcepts, .questionForClass])
        #expect(brief.sections[2].title == "Kerneargumenter (5 punkter)")
        #expect(brief.sections[0].body.hasPrefix("> Genereret"))
        #expect(brief.sections[3].body.contains("## Not a heading inside a fence"))
        let all = brief.sections.map(\.body).joined()
        #expect(!all.contains("Not part of the brief"))
        #expect(!all.contains("Mine egne noter"))
        #expect(brief.summary?.kind == .fifteenMinutes)
    }

    @Test func readsEnglishHeadings() throws {
        let note = try #require(LectureNoteParser.parse(englishNote, path: "b.md"))
        #expect(note.session == nil)
        #expect(note.status == .unconfirmed)
        #expect(note.brief?.sections.map(\.kind) == [.fifteenMinutes, .missing])
    }

    @Test func keepsALeadWithoutSubsections() throws {
        let note = try #require(LectureNoteParser.parse(leadOnlyNote, path: "c.md"))
        #expect(note.status == .noTeaching)
        #expect(note.version == nil)
        #expect(note.brief?.sections.count == 1)
        #expect(note.brief?.summary?.kind == .lead)
    }

    @Test func noBriefYet() throws {
        let note = try #require(LectureNoteParser.parse(noBriefNote, path: "d.md"))
        #expect(note.brief == nil)
        #expect(note.briefFlag == false)
        #expect(note.startMinute == nil)
        #expect(note.courseId == nil)
    }

    @Test func skipsOtherNotes() {
        #expect(LectureNoteParser.parse("# Just a note\n", path: "e.md") == nil)
        #expect(LectureNoteParser.parse("---\ntype: course-index\n---\n", path: "f.md") == nil)
        #expect(LectureNoteParser.parse("---\ntype: lecture-prep\n", path: "g.md") == nil)
    }

    @Test func toleratesWindowsLineEndingsAndBadValues() throws {
        let text = "---\r\ntype: lecture-prep\r\ndate: 2026-13-40\r\nstart: \"25:00\"\r\nitslearning_course_id: abc\r\n---\r\n## Pre-lecture brief\r\nHi\r\n"
        let note = try #require(LectureNoteParser.parse(text, path: "h.md"))
        #expect(note.day == nil)
        #expect(note.startMinute == nil)
        #expect(note.courseId == nil)
        #expect(note.brief?.sections.first?.body == "Hi")
    }
}

@Suite struct LectureNoteMatcherTests {
    let notes = [danishNote, englishNote, leadOnlyNote, noBriefNote].enumerated().compactMap { index, text in
        LectureNoteParser.parse(text, path: "note-\(index).md")
    }

    @Test func matchesCourseDayAndNearestStart() {
        // Plans often start at the quarter past.
        let match = LectureNoteMatcher.note(for: plan(1, course: 1001, start: "2026-03-10T07:15:00Z"), course: nil, in: notes)
        #expect(match?.courseId == 1001)
    }

    @Test func refusesStartsMoreThanAnHourAway() {
        #expect(LectureNoteMatcher.note(for: plan(1, course: 1001, start: "2026-03-10T08:01:00Z"), course: nil, in: notes) == nil)
        #expect(LectureNoteMatcher.note(for: plan(1, course: 1001, start: "2026-03-10T08:00:00Z"), course: nil, in: notes) != nil)
    }

    @Test func refusesOtherCoursesAndDays() {
        #expect(LectureNoteMatcher.note(for: plan(1, course: 9999, start: "2026-03-10T07:00:00Z"), course: nil, in: notes) == nil)
        #expect(LectureNoteMatcher.note(for: plan(1, course: 1001, start: "2026-03-11T07:00:00Z"), course: nil, in: notes) == nil)
        #expect(LectureNoteMatcher.note(for: plan(1, course: 1001, start: nil), course: nil, in: notes) == nil)
    }

    @Test func picksTheNearestOfTwoOnOneDay() {
        let morning = LectureNoteParser.parse(englishNote.replacingOccurrences(of: "\"16:00\"", with: "\"10:00\"").replacingOccurrences(of: "Exercises", with: "Lecture"), path: "z-morning.md")!
        let all = notes + [morning]
        #expect(LectureNoteMatcher.note(for: plan(1, course: 1002, start: "2026-03-10T09:15:00Z"), course: nil, in: all)?.path == "z-morning.md")
        #expect(LectureNoteMatcher.note(for: plan(1, course: 1002, start: "2026-03-10T15:15:00Z"), course: nil, in: all)?.path == "note-1.md")
    }

    @Test func fallsBackToTheCourseTitle() {
        let course = Course(courseId: 5, title: "Example economics, spring 26")
        let match = LectureNoteMatcher.note(for: plan(1, course: 5, start: "2026-03-24T09:15:00Z"), course: course, in: notes)
        #expect(match?.path == "note-3.md")
        let other = Course(courseId: 5, title: "Something else")
        #expect(LectureNoteMatcher.note(for: plan(1, course: 5, start: "2026-03-24T09:15:00Z"), course: other, in: notes) == nil)
    }

    @Test func aCourseIdBeatsTheTitle() {
        // The note names its course ID, so a same-titled course with another ID does not match.
        let course = Course(courseId: 77, title: "Example Economics")
        #expect(LectureNoteMatcher.note(for: plan(1, course: 77, start: "2026-03-10T15:00:00Z"), course: course, in: notes) == nil)
    }

    @Test func aDayOnlyPlanMatchesTheDaysOneNote() {
        // Midnight in the note's zone.
        let match = LectureNoteMatcher.note(for: plan(1, course: 1003, start: "2026-03-11T23:00:00Z"), course: nil, in: notes)
        #expect(match?.status == .noTeaching)
    }

    @Test func usesTheNotesTimeZoneForTheDay() {
        // 23:30 UTC on the 9th is 00:30 on the 10th in Berlin: still outside the hour.
        #expect(LectureNoteMatcher.note(for: plan(1, course: 1001, start: "2026-03-09T23:30:00Z"), course: nil, in: notes) == nil)
    }

    @Test func matchesCalendarEvents() {
        let event = CalendarEvent(eventId: 1, title: "E", fromDate: instant("2026-03-10T15:00:00Z"), toDate: nil, courseId: 1002)
        #expect(LectureNoteMatcher.note(for: event, course: nil, in: notes)?.courseId == 1002)
    }
}

@Suite struct BriefTextTests {
    @Test func flattensBlockMarkdown() {
        let section = BriefSection(kind: .keyConcepts, title: "Key concepts", body: "> Quote\n\n\n* **A** – one\n  - nested\n1. First [[uni/Readings/x.pdf|X]]\n")
        #expect(section.displayText(linkScheme: nil) == "Quote\n\n• **A** – one\n    • nested\n1. First X")
    }
}

@Suite struct WikiLinkTests {
    @Test func rewritesLinks() {
        let text = "See [[uni/Readings/1__A b.pdf|A b]] and [[Other note]]."
        #expect(WikiLink.markdown(text, scheme: nil) == "See A b and Other note.")
        #expect(WikiLink.markdown(text, scheme: "laer-note") == "See [A b](laer-note:uni/Readings/1__A%20b.pdf) and [Other note](laer-note:Other%20note).")
        #expect(WikiLink.markdown("[[a#Heading|x]]", scheme: nil) == "x")
        #expect(WikiLink.markdown("[[uni/Readings/A (2013 b.pdf|A]]", scheme: "s") == "[A](s:uni/Readings/A%20%282013%20b.pdf)")
    }

    @Test func resolvesInsideThePickedFolder() {
        let folder = URL(fileURLWithPath: "/tmp/vault/uni")
        #expect(WikiLink.candidates("uni/Readings/a.pdf", in: folder).map(\.path) == ["/tmp/vault/uni/Readings/a.pdf"])
        #expect(WikiLink.candidates("a.pdf", in: folder).map(\.path) == ["/tmp/vault/uni/a.pdf", "/tmp/vault/uni/Readings/a.pdf"])
        #expect(WikiLink.candidates("../secret.pdf", in: folder).isEmpty)
    }
}

@Suite struct LectureNoteScannerTests {
    @Test func readsOnlyLectureFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("laer-notes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let lectures = root.appendingPathComponent("Courses/Example/Lectures", isDirectory: true)
        try FileManager.default.createDirectory(at: lectures, withIntermediateDirectories: true)
        try danishNote.write(to: lectures.appendingPathComponent("2026-03-10 - 9 - Eksempel.md"), atomically: true, encoding: .utf8)
        try "# not frontmatter".write(to: lectures.appendingPathComponent("plain.md"), atomically: true, encoding: .utf8)
        try danishNote.write(to: root.appendingPathComponent("Courses/Example/Index.md"), atomically: true, encoding: .utf8)
        let before = try FileManager.default.contentsOfDirectory(atPath: lectures.path).sorted()

        let notes = LectureNoteScanner.scan(root)
        #expect(notes.map(\.path) == ["Courses/Example/Lectures/2026-03-10 - 9 - Eksempel.md"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: lectures.path).sorted() == before)
        #expect(LectureNoteScanner.scan(root.appendingPathComponent("missing")).isEmpty)
    }
}
