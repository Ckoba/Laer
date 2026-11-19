import Foundation
import Testing
@testable import LaerCore

/// Records requests and answers from a route-keyed table of synthetic JSON.
final class RecordingTransport: ReadTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ReadRequest] = []
    let responses: [String: String]

    init(_ responses: [String: String]) {
        self.responses = responses
    }

    var requests: [ReadRequest] { lock.withLock { recorded } }

    func send(_ request: ReadRequest) async throws -> ReadResponse {
        lock.withLock { recorded.append(request) }
        guard let body = responses[request.routeTemplate] else {
            return ReadResponse(status: 404, contentType: "application/json", body: Data())
        }
        return .json(body)
    }
}

private func page(_ items: String, total: Int) -> String {
    #"{"EntityArray": [\#(items)], "Total": \#(total), "CurrentPageIndex": 0, "PageSize": 100}"#
}

@Suite struct ParityTests {
    @Test func personalCalendarSendsFromDateAndDecodes() async throws {
        let transport = RecordingTransport(["calendar/events/v1": page(#"""
            {"EventId": 41, "EventTitle": "Lecture", "FromDate": "2026-11-02T09:00:00Z", "ToDate": "2026-11-02T10:00:00Z",
             "EventType": "Course", "LocationId": 11, "LocationTitle": "Course one"},
            {"EventId": 42, "EventTitle": "Personal", "FromDate": "2026-11-03T09:00:00Z", "EventType": "Personal", "LocationId": 5}
            """#, total: 2)])
        let client = ItslearningClient(transport: transport)
        let result = try await client.calendarEvents(from: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(result.isComplete)
        #expect(result.items.map(\.eventId) == [41, 42])
        #expect(result.items[0].courseId == 11)
        #expect(result.items[1].courseId == nil)
        let query = try #require(transport.requests.first?.query)
        #expect(query.contains { $0.name == "fromDate" && ($0.value ?? "").hasSuffix("Z") })
    }

    @Test func courseCalendarUsesIdKey() async throws {
        let transport = RecordingTransport(["courses/{id}/calendarevents/v1": page(#"""
            {"Id": 51, "EventTitle": "Seminar", "FromDate": "2026-11-04T12:00:00Z", "CourseId": 11}
            """#, total: 1)])
        let result = try await ItslearningClient(transport: transport)
            .courseCalendarEvents(courseId: 11, from: .now, to: .now.addingTimeInterval(86_400))
        #expect(result.items.first?.eventId == 51)
        #expect(result.items.first?.courseId == 11)
        let names = Set(transport.requests.first?.query.map(\.name) ?? [])
        #expect(names.isSuperset(of: ["fromDate", "toDate", "PageIndex", "PageSize"]))
    }

    @Test func calendarEventRoundTripsThroughSnapshotEncoding() throws {
        let event = CalendarEvent(eventId: 7, title: "A", fromDate: Date(timeIntervalSince1970: 0), courseId: 3)
        let decoded = try JSONDecoder().decode(CalendarEvent.self, from: JSONEncoder().encode(event))
        #expect(decoded == event)
    }

    @Test func pageDecodesRecordedBlockShape() async throws {
        let transport = RecordingTransport(["pages/{id}/v1": #"""
            {"elementId": 90, "title": "Week page", "layout": "OneColumn", "isActive": true, "contentBlocks": [
              {"contentBlockId": 2, "type": "Text", "title": "Second", "rawText": "raw", "processedText": "<p>Two</p>",
               "order": 2, "layoutZone": "Main", "color": "None"},
              {"contentBlockId": 1, "type": "Text", "rawText": "<p>One</p>", "order": 1},
              {"contentBlockId": 3, "type": "Files", "order": 3, "files": [{"fileId": 3, "name": "notes.pdf", "size": 1200}]}
            ]}
            """#])
        let page = try await ItslearningClient(transport: transport).page(elementId: 90)
        let blocks = page.orderedBlocks
        #expect(blocks.map(\.contentBlockId) == [1, 2, 3])
        #expect(blocks[0].html == "<p>One</p>")
        #expect(blocks[1].html == "<p>Two</p>")
        #expect(blocks[2].files?.first?.name == "notes.pdf")
    }

    @Test func pageWithoutBlocksIsValid() async throws {
        let transport = RecordingTransport(["pages/{id}/v1": #"{"elementId": 91, "title": "Empty", "contentBlocks": null}"#])
        let page = try await ItslearningClient(transport: transport).page(elementId: 91)
        #expect(page.contentBlocks == nil)
    }

    @Test func pageMissingIdentityIsSchemaError() async throws {
        let transport = RecordingTransport(["pages/{id}/v1": #"{"title": "No id"}"#])
        await #expect(throws: APIError.schema("pages/{id}/v1: missing elementId")) {
            try await ItslearningClient(transport: transport).page(elementId: 1)
        }
    }

    @Test func assignmentAndAnswerDecode() async throws {
        let transport = RecordingTransport([
            "assignments/{id}/v1": #"""
                {"ElementId": 70, "Title": "Essay", "Text": "<p>Write 500 words.</p>", "Deadline": "2026-11-10T22:00:00Z",
                 "MaxScore": 10.0, "SubmissionType": "Individual",
                 "Files": [{"FileId": 1, "Name": "brief.pdf", "MimeType": "application/pdf", "Size": 2048}], "AnswerId": 5}
                """#,
            "assignments/{id}/answers/persons/{id}/v1": #"{"AnswerId": 5, "IsDraft": false, "Submitted": "2026-11-09T10:00:00Z", "Files": []}"#,
        ])
        let client = ItslearningClient(transport: transport)
        let assignment = try await client.assignment(elementId: 70)
        #expect(assignment.files?.first?.name == "brief.pdf")
        #expect(assignment.maxScore == 10)
        let answer = try await client.assignmentAnswer(elementId: 70, personId: 1001)
        #expect(answer.isDraft == false)
        #expect(answer.submitted != nil)
    }

    @Test func topicsAndParticipantsDecode() async throws {
        let transport = RecordingTransport([
            "courses/{id}/topics/v1": page(#"{"TopicId": 1, "TopicName": "Unit one", "FolderId": 701, "Color": "x", "TopicMode": 1}"#, total: 1),
            "courses/{id}/participants/v3": page(#"""
                {"PersonId": 1, "FullName": "Sam Teacher", "Role": "Teacher", "RoleId": 2},
                {"PersonId": 2, "FullName": "Alex Example", "Role": "Student", "LastVisited": "2026-10-01T08:00:00Z"}
                """#, total: 2),
        ])
        let client = ItslearningClient(transport: transport)
        #expect(try await client.topics(courseId: 11).items.first?.name == "Unit one")
        let participants = try await client.participants(courseId: 11)
        #expect(participants.items.map(\.personId) == [1, 2])
        let query = transport.requests.last?.query.map(\.name) ?? []
        #expect(query.contains("paging.PageIndex") && query.contains("paging.PageSize"))
    }

    @Test func messageThreadsDecodeWithEmbeddedMessages() async throws {
        let transport = RecordingTransport(["instantmessages/messagethreads/v4": #"""
            {"Threads": {"EntityArray": [
              {"InstantMessageThreadId": 300, "Name": "Group work", "SortIndex": 900, "LastReadInstantMessageId": 10,
               "Participants": [{"PersonId": 1, "FullName": "Sam Teacher"}],
               "LastMessage": {"MessageId": 12, "Text": "See you", "CreatedByName": "Sam Teacher", "Created": "2026-10-30T10:00:00Z"},
               "Messages": {"EntityArray": [{"MessageId": 12, "Text": "See you"}, {"MessageId": 11, "Text": "Hello"}], "Total": 2}},
              {"InstantMessageThreadId": 301, "SortIndex": 800, "LastReadInstantMessageId": 20,
               "LastMessage": {"MessageId": 20, "Text": "Done"}}
            ], "Total": 2}, "HasMore": false}
            """#])
        let list = try await ItslearningClient(transport: transport).messageThreads(before: 1000)
        #expect(list.threads.count == 2)
        #expect(list.hasMore == false)
        #expect(list.threads[0].hasUnread)
        #expect(!list.threads[1].hasUnread)
        #expect(list.threads[0].recentMessages?.items?.map(\.messageId) == [12, 11])
        #expect(transport.requests.first?.query.contains { $0.name == "fromSortIndex" && $0.value == "1000" } == true)
    }

    @Test func threadMessagesDecode() async throws {
        let transport = RecordingTransport(["instantmessages/messagethreads/{id}/messages/v3": #"""
            {"Messages": {"EntityArray": [{"MessageId": 9, "InstantMessageThreadId": 300, "Text": "Older",
              "AttachmentName": "a.pdf", "AttachmentUrl": "/file/1"}], "Total": 1}, "HasMore": true}
            """#])
        let list = try await ItslearningClient(transport: transport).messages(threadId: 300, before: 10)
        #expect(list.messages.first?.attachmentName == "a.pdf")
        #expect(list.hasMore)
    }

    @Test func unreadCountIsABareInteger() async throws {
        let transport = RecordingTransport(["instantmessages/messagethreads/unread/count/v1": "3"])
        #expect(try await ItslearningClient(transport: transport).unreadThreadCount() == 3)
    }

    @Test func loginPageOnParityRouteIsSignedOut() async throws {
        struct LoginTransport: ReadTransport {
            func send(_ request: ReadRequest) async throws -> ReadResponse {
                ReadResponse(status: 200, contentType: "text/html", body: Data("<html></html>".utf8))
            }
        }
        await #expect(throws: APIError.signedOut) {
            try await ItslearningClient(transport: LoginTransport()).messageThreads()
        }
    }

    @Test func notificationsAndCountDecode() async throws {
        let transport = RecordingTransport([
            "notifications/v2": page(#"""
                {"NotificationId": 1, "Text": "New update", "PublishedDate": "2026-10-30T10:00:00Z", "IsRead": false,
                 "PublishedBy": {"PersonId": 2, "FullName": "Sam Teacher"}, "Type": "Bulletin", "Url": "/n/1"}
                """#, total: 1),
            "notifications/unread/count/v1": "4",
        ])
        let client = ItslearningClient(transport: transport)
        let items = try await client.notifications()
        #expect(items.first?.isRead == false)
        #expect(items.first?.publishedBy?.fullName == "Sam Teacher")
        #expect(try await client.unreadNotificationCount() == 4)
    }

    @Test func bulletinsAndElementsDecode() async throws {
        let transport = RecordingTransport([
            "courses/{id}/bulletins/v1": page(#"""
                {"LightBulletinId": 5, "Text": "<p>Exam moved</p>", "Pinned": true, "CommentsCount": 2,
                 "AttachedImages": [{"PreviewFileUrl": "/p/1"}], "PublishedDate": "2026-10-28T08:00:00Z"}
                """#, total: 1),
            "courses/bulletins/{id}/elements/v1": page(#"{"ElementId": 9, "ElementType": "LearningToolElement", "Title": "Slides"}"#, total: 1),
        ])
        let client = ItslearningClient(transport: transport)
        let bulletin = try #require(try await client.bulletins(courseId: 11).items.first)
        #expect(bulletin.pinned == true)
        #expect(bulletin.attachedImages?.count == 1)
        #expect(try await client.bulletinElements(bulletinId: 5).items.first?.title == "Slides")
    }

    @Test func assessmentRecordDecodes() async throws {
        let transport = RecordingTransport([
            "course/{id}/assessmentrecord/assessmentrecordelements/v1": #"""
                {"AssessmentRecordItems": [{"GradeBookItemId": 1, "Title": "Essay", "MaxScore": 10, "UseScore": true}],
                 "FinalAssessmentRecordItems": [], "AssessmentScales": [{"AssessmentScaleId": 3, "Title": "A-F",
                 "Values": [{"AssessmentItemId": 31, "Title": "A", "OrderPosition": 1}]}], "IsScoreInUse": true}
                """#,
            "course/{id}/assessmentrecord/assessmentrecordpersonitems/v1": page(#"""
                {"PersonId": 1001, "PersonAssessments": [{"GradeBookItemId": 1, "Score": 8.5, "AssessmentVisible": true}]}
                """#, total: 1),
        ])
        let client = ItslearningClient(transport: transport)
        let record = try await client.assessmentRecord(courseId: 11)
        #expect(record.items?.first?.title == "Essay")
        #expect(record.scales?.first?.values?.first?.title == "A")
        let rows = try await client.personAssessments(courseId: 11)
        #expect(rows.items.first?.results?.first?.score == 8.5)
    }

    @Test func starredCardsAndRecipientsDecode() async throws {
        let transport = RecordingTransport([
            "courses/cards/starred/v1": page(#"{"CourseId": 11, "Title": "Course one", "IsFavouriteCourse": true, "NumberOfTasks": 2}"#, total: 1),
            "instantmessages/recipients/search/v1": #"""
                [{"Id": 2, "Label": "Sam Teacher", "UserName": "sam", "TypeName": "Person", "CanReceive": true},
                 {"Id": "40", "Label": "Course one", "TypeName": "Course", "ParticipantsCount": 30}]
                """#,
        ])
        let client = ItslearningClient(transport: transport)
        #expect(try await client.starredCourses().items.first?.isFavourite == true)
        let recipients = try await client.searchRecipients("sa")
        #expect(recipients.map(\.recipientId) == [2, 40])
        #expect(recipients.map(\.isPerson) == [true, false])
        #expect(transport.requests.last?.query.first { $0.name == "searchText" }?.value == "sa")
    }

    @Test func filePathsAreRouteShaped() {
        #expect(ParityFilePaths.assignmentFile(elementId: 1, fileId: 2) == "/restapi/personal/assignments/1/files/2/v1")
        #expect(ParityFilePaths.pageFile(elementId: 1, blockId: 2, fileId: 3) == "/restapi/personal/pages/1/contentblocks/2/files/3/v1")
    }
}

@Suite struct RichTextTests {
    @Test func paragraphsHeadingsAndInlineStyles() {
        let blocks = RichText.blocks(fromHTML: "<h2>Week&nbsp;two</h2><p>Read <b>chapter 3</b> and <a href=\"https://example.itslearning.com/x\">this</a>.</p><p>  </p>")
        #expect(blocks.count == 2)
        #expect(blocks[0] == .heading(level: 2, runs: [RichRun(text: "Week two")]))
        guard case .paragraph(let runs) = blocks[1] else { Issue.record("not a paragraph"); return }
        #expect(runs.map(\.text).joined() == "Read chapter 3 and this.")
        #expect(runs.first { $0.bold }?.text == "chapter 3")
        #expect(runs.first { $0.link != nil }?.link == "https://example.itslearning.com/x")
    }

    @Test func listsNumberAndNest() {
        let blocks = RichText.blocks(fromHTML: "<ol><li>One</li><li>Two<ul><li>Inner</li></ul></li></ol>")
        #expect(blocks == [
            .listItem(ordered: true, number: 1, depth: 0, runs: [RichRun(text: "One")]),
            .listItem(ordered: true, number: 2, depth: 0, runs: [RichRun(text: "Two")]),
            .listItem(ordered: false, number: 1, depth: 1, runs: [RichRun(text: "Inner")]),
        ])
    }

    @Test func scriptsAndUnsafeLinksAreDropped() {
        let blocks = RichText.blocks(fromHTML: "<script>alert(1)</script><style>p{}</style><p><a href=\"javascript:alert(1)\">x</a></p><img src=\"data:image/png;base64,AA\">")
        #expect(blocks == [.paragraph([RichRun(text: "x")])])
    }

    @Test func imagesEmbedsPreAndEntities() {
        let blocks = RichText.blocks(fromHTML: "<p>a &amp; b &#233; &#x41;</p><img src=\"/file/1\" alt=\"Chart\"><pre>let x = 1\n  y</pre><iframe src=\"https://video.example.com/1\"></iframe><hr>")
        #expect(blocks == [
            .paragraph([RichRun(text: "a & b é A")]),
            .image(source: "/file/1", alt: "Chart"),
            .code("let x = 1\n  y"),
            .embed(source: "https://video.example.com/1"),
            .rule,
        ])
    }

    @Test func plainTextWithoutMarkupIsOneParagraph() {
        #expect(RichText.blocks(fromHTML: "Room change for Thursday.") == [.paragraph([RichRun(text: "Room change for Thursday.")])])
        #expect(RichText.plainText(RichText.blocks(fromHTML: "<p>A</p><p>B</p>")) == "A\n\nB")
    }

    @Test func decorationsKeptAndAuthorColoursDropped() {
        let html = #"<p><u>under</u> <s>gone</s> <span style="color:#f00;font-size:30px;font-family:Comic Sans">plain</span> "#
            + #"<span style="font-weight:700;font-style:italic">both</span> <font color="red" size="7">font</font></p>"#
            + #"<b style="font-weight:normal" id="docs-internal-guid-x"><p>Pasted</p></b>"#
        let blocks = RichText.blocks(fromHTML: html)
        #expect(blocks == [
            .paragraph([
                RichRun(text: "under", underline: true), RichRun(text: " "),
                RichRun(text: "gone", strikethrough: true), RichRun(text: " plain "),
                RichRun(text: "both", bold: true, italic: true), RichRun(text: " font"),
            ]),
            .paragraph([RichRun(text: "Pasted")]),
        ])
    }

    @Test func tablesAndNumberedListStart() {
        let html = "<table><tr><th>Week</th><th>Topic</th></tr><tr><td>1</td><td><p>Intro</p><p>Reading</p></td></tr></table>"
            + "<ol start=\"3\"><li>Three</li><li>Four</li></ol>"
        #expect(RichText.blocks(fromHTML: html) == [
            .table(rows: [
                [RichTableCell(runs: [RichRun(text: "Week")], isHeader: true), RichTableCell(runs: [RichRun(text: "Topic")], isHeader: true)],
                [RichTableCell(runs: [RichRun(text: "1")]), RichTableCell(runs: [RichRun(text: "Intro"), RichRun(text: "\n"), RichRun(text: "Reading")])],
            ]),
            .listItem(ordered: true, number: 3, depth: 0, runs: [RichRun(text: "Three")]),
            .listItem(ordered: true, number: 4, depth: 0, runs: [RichRun(text: "Four")]),
        ])
        #expect(RichText.blocks(fromHTML: "<table><tr><td><b>Layout</b></td></tr></table>") == [.paragraph([RichRun(text: "Layout", bold: true)])])
    }

    @Test func plainTextKeepsBreaksAndLinksAddresses() {
        let blocks = RichText.blocks(fromHTML: "Hi all,\nsee https://example.itslearning.com/a today.\n\nThanks &AElig;&aelig;")
        #expect(blocks == [
            .paragraph([
                RichRun(text: "Hi all,\nsee "),
                RichRun(text: "https://example.itslearning.com/a", link: "https://example.itslearning.com/a"),
                RichRun(text: " today."),
            ]),
            .paragraph([RichRun(text: "Thanks \u{00C6}\u{00E6}")]),
        ])
        #expect(RichText.preview(blocks) == "Hi all, see https://example.itslearning.com/a today. Thanks \u{00C6}\u{00E6}")
    }
}
