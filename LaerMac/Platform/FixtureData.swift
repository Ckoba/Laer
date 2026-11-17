import AppKit
import Foundation
import LaerCore

/// Synthetic data for UI tests and screenshots, switched on with `-LaerFixtureMode YES`.
/// Every value is invented. The host is example.itslearning.com.
struct FixtureTransport: ReadTransport {
    static let site = Site(
        shortName: "example", title: "Example Institution",
        baseURL: URL(string: "https://example.itslearning.com")!, customerId: 1)

    /// Set to make every read answer as a lost session, for the signed-out recovery test.
    let isSignedOut: @Sendable () -> Bool

    init(isSignedOut: @escaping @Sendable () -> Bool = { false }) {
        self.isSignedOut = isSignedOut
    }

    func send(_ request: ReadRequest) async throws -> ReadResponse {
        if isSignedOut() {
            return ReadResponse(status: 200, contentType: "text/html", body: Data("<html><form></form></html>".utf8))
        }
        guard let body = Self.body(for: request) else {
            let status = request.routeTemplate == "assignments/{id}/v1" ? 403 : 404
            return ReadResponse(status: status, contentType: "application/json", body: Data("{}".utf8))
        }
        return ReadResponse(status: 200, contentType: "application/json; charset=utf-8", body: Data(body.utf8))
    }

    static func body(for request: ReadRequest) -> String? {
        if StressFixtures.isOn, let stressed = StressFixtures.body(for: request) { return stressed }
        switch request.routeTemplate {
        case "person/v1":
            return #"{"PersonId": 1001, "FullName": "Alex Example", "TimeZoneId": "UTC"}"#
        case "courses/v4":
            return page(#"""
            {"CourseId": 11, "Title": "Course one", "CourseCode": "C-101", "Url": "/main.aspx?CourseID=11"},
            {"CourseId": 12, "Title": "Course two", "CourseCode": "C-102", "Url": "/main.aspx?CourseID=12"},
            {"CourseId": 13, "Title": "Empty course"}
            """#, count: 3)
        case "courses/{id}/stream/v1":
            if request.path.contains("/13/") { return page("", count: 0) }
            return page(#"""
            {"NotificationId": 501, "Text": "Week two reading is posted.", "PublishedDate": "2026-10-20T08:00:00Z",
             "PublishedBy": {"FullName": "Sam Teacher"}, "Url": "/note/501"},
            {"NotificationId": 502, "Text": "Room change for Thursday.", "PublishedDate": "2026-10-18T08:00:00Z",
             "PublishedBy": {"FullName": "Sam Teacher"}}
            """#, count: 2)
        case "courses/{id}/resources/v1":
            if request.path.contains("/13/") { return #"{"Resources": \#(page("", count: 0))}"# }
            return #"""
            {"Resources": \#(page(#"""
            {"ElementId": 701, "ElementType": "Folder", "Title": "Week one"},
            {"ElementId": 702, "ElementType": "LearningToolElement", "Title": "Syllabus.pdf",
             "LearningObjectId": 9001, "LearningObjectInstanceId": 9101},
            {"ElementId": 703, "ElementType": "LearningToolElement", "Title": "Course page", "Url": "/page/703"}
            """#, count: 3))}
            """#
        case "courses/{id}/folders/{id}/resources/v1":
            return #"""
            {"Resources": \#(page(#"""
            {"ElementId": 704, "ElementType": "LearningToolElement", "Title": "Notes.pdf",
             "LearningObjectId": 9002, "LearningObjectInstanceId": 9102}
            """#, count: 1))}
            """#
        case "tasks/v1":
            return page(#"""
            {"TaskId": 801, "Title": "Essay draft", "LocationId": 11, "LocationTitle": "Course one",
             "ElementId": 70, "ElementType": "LearningToolElement", "Deadline": "2026-11-05T22:00:00Z", "Status": "Not submitted"},
            {"TaskId": 802, "Title": "Reading quiz", "LocationId": 12, "LocationTitle": "Course two", "Homework": true}
            """#, count: 2)
        case "course/{id}/plans/all/v1":
            return #"""
            {"entityArray": [
              {"id": 601, "title": "Week one", "start": "2026-10-05T00:00:00Z", "stop": "2026-10-11T00:00:00Z",
               "displayDescription": "<p>Introduction and <b>reading</b>.</p>", "courseId": 11, "orderNumber": 1,
               "elements": [{"id": 702, "title": "Syllabus.pdf", "isResource": true}, {"id": 701, "title": "Week one", "isFolder": true}]}
            ], "total": 1, "currentPageIndex": 0, "pageSize": 100}
            """#
        default:
            return ParityFixtures.body(for: request)
        }
    }

    static func page(_ items: String, count: Int) -> String {
        #"{"EntityArray": [\#(items)], "Total": \#(count), "CurrentPageIndex": 0, "PageSize": 100}"#
    }
}

/// Synthetic answers for the parity routes.
enum ParityFixtures {
    static func body(for request: ReadRequest) -> String? {
        switch request.routeTemplate {
        case "instantmessages/messagethreads/v4":
            return #"""
            {"Threads": {"EntityArray": [
              {"InstantMessageThreadId": 300, "Name": "Group work", "SortIndex": 900, "LastReadInstantMessageId": 10,
               "Participants": [{"PersonId": 2, "FullName": "Sam Teacher"}, {"PersonId": 1001, "FullName": "Alex Example"}],
               "LastMessage": {"MessageId": 12, "Text": "See you on Thursday.", "CreatedByName": "Sam Teacher", "Created": "2026-10-30T10:00:00Z"},
               "Messages": {"EntityArray": [\#(FixtureWrites.shared.sentMessagesJSON)
                 {"MessageId": 12, "Text": "See you on Thursday.", "CreatedByName": "Sam Teacher", "Created": "2026-10-30T10:00:00Z"},
                 {"MessageId": 11, "Text": "Here is the outline.", "CreatedByName": "Alex Example", "Created": "2026-10-29T15:00:00Z",
                  "AttachmentName": "outline.pdf", "AttachmentUrl": "/file/11"}
               ], "Total": 2}},
              {"InstantMessageThreadId": 301, "SortIndex": 800, "LastReadInstantMessageId": 20,
               "Participants": [{"PersonId": 3, "FullName": "Robin Example"}],
               "LastMessage": {"MessageId": 20, "Text": "Thanks", "CreatedByName": "Robin Example", "Created": "2026-10-20T09:00:00Z"}}
            ], "Total": 2}, "HasMore": false}
            """#
        case "courses/{id}/calendarevents/v1":
            return FixtureTransport.page(#"""
            {"Id": 51, "EventTitle": "Seminar", "FromDate": "2026-11-04T12:00:00Z", "ToDate": "2026-11-04T14:00:00Z", "CourseId": 11},
            {"Id": 52, "EventTitle": "Lecture", "FromDate": "2026-11-06T08:00:00Z", "ToDate": "2026-11-06T10:00:00Z", "CourseId": 11}
            """#, count: 2)
        case "calendar/events/v1":
            return FixtureTransport.page(#"""
            {"EventId": 41, "EventTitle": "Lecture", "FromDate": "2026-11-02T09:00:00Z", "ToDate": "2026-11-02T10:00:00Z",
             "EventType": "Course", "LocationId": 11, "LocationTitle": "Course one"}
            """#, count: 1)
        case "courses/{id}/participants/v3":
            return FixtureTransport.page(#"""
            {"PersonId": 2, "FullName": "Sam Teacher", "Role": "Teacher"},
            {"PersonId": 1001, "FullName": "Alex Example", "Role": "Student"},
            {"PersonId": 3, "FullName": "Robin Example", "Role": "Student"}
            """#, count: 3)
        case "notifications/v2":
            return FixtureTransport.page(#"""
            {"NotificationId": 1, "Text": "New update in Course one", "PublishedDate": "2026-10-30T10:00:00Z", "IsRead": false,
             "PublishedBy": {"FullName": "Sam Teacher"}, "Url": "/n/1"},
            {"NotificationId": 2, "Text": "Plan updated", "PublishedDate": "2026-10-25T10:00:00Z", "IsRead": true}
            """#, count: 2)
        case "courses/{id}/bulletins/v1":
            if request.path.contains("/13/") { return FixtureTransport.page("", count: 0) }
            return FixtureTransport.page(#"""
            {"LightBulletinId": 5, "Text": "<p>Exam moved to <b>Friday</b>.</p>", "Pinned": true, "AllowComments": true,
             "CommentsCount": 1, "PublishedDate": "2026-10-28T08:00:00Z", "PublishedBy": {"FullName": "Sam Teacher"}}
            """#, count: 1)
        case "lightbulletins/{id}/comments/v1":
            return FixtureTransport.page(#"""
            {"Id": 76, "CommentText": "Noted", "AllowEditComment": false, "AllowDeleteComment": false,
             "CreatedDateTime": "2026-10-28T09:00:00Z", "Author": {"PersonId": 3, "FullName": "Robin Example"}}
            """#, count: 1)
        case "assignments/{id}/v1":
            // Only the CustomActivity task is an assignment; the live site answers others with 403.
            guard request.path.contains("/70/") else { return nil }
            return #"""
            {"ElementId": 70, "Title": "Essay draft", "Text": "<p>Write <b>500</b> words.</p>", "Deadline": "2026-11-05T22:00:00Z",
             "SubmissionType": "Individual", "Files": [{"FileId": 1, "Name": "brief.pdf", "Size": 2048}]}
            """#
        case "courses/cards/starred/v1":
            let starred = [11, 12, 13, 14].filter {
                FixtureWrites.shared.isStarred(courseId: $0, initially: $0 == 12 || (StressFixtures.isOn && $0 == 14))
            }
            let items = starred.map { #"{"CourseId": \#($0), "IsFavouriteCourse": true}"# }.joined(separator: ",")
            return FixtureTransport.page(items, count: starred.count)
        case "instantmessages/recipients/search/v1":
            return #"""
            [{"Id": 3, "Label": "Robin Example", "UserName": "robin", "TypeName": "Person", "CanReceive": true, "RoleInHierarchyTitle": "Student"},
             {"Id": 40, "Label": "Course one", "TypeName": "Course", "CanReceive": true}]
            """#
        case "instantmessages/messagethreads/{id}/messages/v3":
            return #"""
            {"HasMore": false, "Messages": {"CurrentPageIndex": 0, "EntityArray": [
              {"MessageId": 5, "Text": "Earlier message", "CreatedByName": "Sam Teacher", "Created": "2026-10-01T09:00:00Z"}
            ]}}
            """#
        case "pages/{id}/v1":
            return #"""
            {"elementId": 703, "title": "Course page", "layout": "OneColumn", "isActive": true, "contentBlocks": [
              {"contentBlockId": 1, "type": "Text", "title": "Welcome", "order": 1,
               "processedText": "<p>This course meets <b>twice</b> a week.</p><ul><li>Bring the reader</li><li>Arrive on time</li></ul>"}
            ]}
            """#
        default:
            return nil
        }
    }
}

extension FixtureTransport: WriteTransport {
    /// Answers writes from canned bodies and records them, so UI tests can check what was sent.
    func sendWrite(_ request: WriteRequest) async throws -> ReadResponse {
        if isSignedOut() {
            return ReadResponse(status: 401, contentType: "text/html", body: Data())
        }
        FixtureWrites.shared.record(request)
        let body: String
        switch request.routeTemplate {
        case "instantmessages/v2":
            body = #"""
            {"InstantMessageThreadId": 300, "Name": "Group work", "SortIndex": 901, "LastReadInstantMessageId": 13,
             "LastMessage": {"MessageId": 13, "Text": "Sent from Laer", "CreatedByName": "Alex Example", "Created": "2026-10-31T09:00:00Z"}}
            """#
        case "instantmessages/attachment/v1":
            body = #"[{"m_Item1": "00000000-0000-0000-0000-000000000001", "m_Item2": "attachment.pdf"}]"#
        case "instantmessages/{id}/v1", "instantmessages/togglemessagestar/{id}/v1":
            body = #"{"MessageId": 11, "Text": "Here is the outline.", "IsDeleted": \#(request.method == .delete), "IsStarred": true}"#
        case "fileupload/temp/v1":
            body = #"{"FileRepoId": "repo-1", "SignedFileRepoId": "signed-1", "Name": "answer.pdf", "MimeType": "application/pdf"}"#
        case "assignments/{id}/answers/v1":
            body = #"{"AnswerId": 900}"#
        case "lightbulletins/{id}/comments/v2":
            body = #"{"Id": 77, "CommentText": "Thanks", "AllowEditComment": true, "AllowDeleteComment": true, "Author": {"PersonId": 1001, "FullName": "Alex Example"}}"#
        default:
            body = ""
        }
        return ReadResponse(status: 200, contentType: "application/json", body: Data(body.utf8))
    }
}

/// Writes made in fixture mode, newest last. Memory only.
final class FixtureWrites: @unchecked Sendable {
    static let shared = FixtureWrites()
    private let lock = NSLock()
    private var requests: [WriteRequest] = []

    func record(_ request: WriteRequest) {
        lock.withLock { requests.append(request) }
    }

    var all: [WriteRequest] { lock.withLock { requests } }

    /// Starred state after the favourite toggles made in this run.
    func isStarred(courseId: Int, initially: Bool) -> Bool {
        let toggles = all.filter { $0.routeTemplate == "courses/{id}/toggleFavorite/v1" && $0.path.contains("/courses/\(courseId)/") }.count
        return toggles % 2 == 0 ? initially : !initially
    }

    /// Messages sent in this run, as thread-listing JSON items followed by a comma, newest first.
    var sentMessagesJSON: String {
        let texts: [String] = all.filter { $0.routeTemplate == "instantmessages/v2" }.compactMap { request in
            guard case .json(let data) = request.body,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return object["Text"] as? String
        }
        return texts.enumerated().reversed().map { index, text in
            let quoted = (try? String(decoding: JSONSerialization.data(withJSONObject: [text], options: [.fragmentsAllowed]), as: UTF8.self)) ?? "[\"\"]"
            return #"{"MessageId": \#(100 + index), "Text": \#(quoted.dropFirst().dropLast()), "CreatedByName": "Alex Example", "Created": "2026-10-31T09:00:00Z"},"#
        }.joined()
    }
}

/// Saved-file bytes for fixture mode, so "open saved material" works without the network.
enum FixtureFiles {
    /// A real three-page PDF, so the viewer's pages and thumbnails have something to show.
    static func pdf(title: String) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        for page in 1...3 {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let text = NSAttributedString(string: "\(title), page \(page)", attributes: [.font: NSFont.systemFont(ofSize: 24)])
            text.draw(at: CGPoint(x: 72, y: 700))
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}

/// Extremes for checking layout by eye, switched on with `-LaerFixtureStress YES` beside fixture mode:
/// a very long course name, a current plan with 40 files, long unbroken words, overlapping and
/// all-day events this week and 30 conversations. Dates are relative to now.
enum StressFixtures {
    static var isOn: Bool { UserDefaults.standard.bool(forKey: "LaerFixtureStress") }

    static let longCourse = "Comparative Institutional Economics, Political Economy and the History of Economic Thought in Practice, autumn 2026. Example City"
    static let longWord = String(repeating: "Unbrokenword", count: 7)

    private static func date(days: Double = 0, hours: Double = 0) -> String {
        let start = Calendar.current.startOfDay(for: Date())
        return ISO8601DateFormatter().string(from: start.addingTimeInterval(days * 86_400 + hours * 3600))
    }

    static func body(for request: ReadRequest) -> String? {
        let path = request.path
        switch request.routeTemplate {
        case "courses/v4":
            return FixtureTransport.page(#"""
            {"CourseId": 11, "Title": "Course one", "CourseCode": "C-101", "Url": "/main.aspx?CourseID=11"},
            {"CourseId": 12, "Title": "Course two", "CourseCode": "C-102", "Url": "/main.aspx?CourseID=12"},
            {"CourseId": 13, "Title": "Empty course"},
            {"CourseId": 14, "Title": "\#(longCourse)", "CourseCode": "ECON-4021-COMPARATIVE-INSTITUTIONS-AUTUMN", "Url": "/main.aspx?CourseID=14"}
            """#, count: 4)
        case "course/{id}/plans/all/v1" where path.contains("/14/"):
            let files = (1...40).map { #"{"id": \#(7000 + $0), "title": "Lecture slides part \#($0) with a fairly long file name.pptx", "isResource": true}"# }
                .joined(separator: ",")
            return #"""
            {"entityArray": [
              {"id": 640, "title": "Lecture on \#(longWord) and the long title of a plan that keeps going", "start": "\#(date(hours: -1))", "stop": "\#(date(days: 1))",
               "displayDescription": "<p>\#(longWord) \#(longWord)</p>", "courseId": 14, "orderNumber": 1, "elements": [\#(files)]},
              {"id": 641, "title": "Next week", "start": "\#(date(days: 7))", "stop": "\#(date(days: 8))", "courseId": 14, "orderNumber": 2, "elements": []},
              {"id": 642, "title": "Earlier week", "start": "\#(date(days: -14))", "stop": "\#(date(days: -13))", "courseId": 14, "orderNumber": 0, "elements": []}
            ], "total": 3, "currentPageIndex": 0, "pageSize": 100}
            """#
        case "tasks/v1":
            return FixtureTransport.page(#"""
            {"TaskId": 801, "Title": "Essay draft", "LocationId": 11, "LocationTitle": "Course one",
             "ElementId": 70, "ElementType": "LearningToolElement", "Deadline": "\#(date(days: 2, hours: 22))", "Status": "NotStarted"},
            {"TaskId": 802, "Title": "Reading quiz", "LocationId": 12, "LocationTitle": "Course two", "Homework": true},
            {"TaskId": 803, "Title": "Submit the \#(longWord) report on comparative institutions with all appendices attached", "LocationId": 14,
             "LocationTitle": "\#(longCourse)", "ElementId": 71, "ElementType": "CustomActivity", "Deadline": "\#(date(days: -1, hours: 12))", "Status": "InProgress"},
            {"TaskId": 804, "Title": "Due later", "LocationId": 14, "LocationTitle": "\#(longCourse)", "Deadline": "\#(date(days: 20))"}
            """#, count: 4)
        case "courses/{id}/bulletins/v1" where path.contains("/14/"):
            return FixtureTransport.page(#"""
            {"LightBulletinId": 6, "Text": "<p>\#(longWord) \#(longWord). A long update that runs past one line on any window.</p>", "Pinned": true,
             "AllowComments": true, "CommentsCount": 0, "PublishedDate": "\#(date(days: -1))",
             "PublishedBy": {"FullName": "Maximilian Alexander Example-Teacher von Longname"}}
            """#, count: 1)
        case "calendar/events/v1":
            let week = (0..<5).map { day -> String in
                #"""
                {"EventId": \#(900 + day * 10), "EventTitle": "\#(longCourse)", "FromDate": "\#(date(days: Double(day), hours: 9))", "ToDate": "\#(date(days: Double(day), hours: 15))",
                 "EventType": "Course", "LocationId": 14, "LocationTitle": "\#(longCourse)"},
                {"EventId": \#(901 + day * 10), "EventTitle": "Seminar", "FromDate": "\#(date(days: Double(day), hours: 10))", "ToDate": "\#(date(days: Double(day), hours: 12))",
                 "EventType": "Course", "LocationId": 11, "LocationTitle": "Course one"},
                {"EventId": \#(902 + day * 10), "EventTitle": "Lab", "FromDate": "\#(date(days: Double(day), hours: 11))", "ToDate": "\#(date(days: Double(day), hours: 13))",
                 "EventType": "Course", "LocationId": 12, "LocationTitle": "Course two"},
                {"EventId": \#(903 + day * 10), "EventTitle": "Open day", "FromDate": "\#(date(days: Double(day)))", "ToDate": "\#(date(days: Double(day), hours: 23.99))"}
                """#
            }
            let past = (-7..<0).map { day in
                #"{"EventId": \#(800 + day + 7), "EventTitle": "Lecture", "FromDate": "\#(date(days: Double(day), hours: 9))", "ToDate": "\#(date(days: Double(day), hours: 10))"}"#
            }
            let future = (5..<14).map { day in
                #"{"EventId": \#(1000 + day), "EventTitle": "Lecture", "FromDate": "\#(date(days: Double(day), hours: 9))", "ToDate": "\#(date(days: Double(day), hours: 10))"}"#
            }
            let items = (past + week + future).joined(separator: ",")
            return FixtureTransport.page(items, count: 7 + 20 + 9)
        case "instantmessages/messagethreads/v4":
            let threads = (0..<30).map { index in
                #"""
                {"InstantMessageThreadId": \#(400 + index), "Name": "\#(index == 0 ? "A conversation with a very long name about \(longWord)" : "Conversation \(index + 1)")",
                 "SortIndex": \#(2000 - index), "LastReadInstantMessageId": \#(index.isMultiple(of: 3) ? 0 : 5000 + index),
                 "Participants": [{"PersonId": 3, "FullName": "Robin Example"}],
                 "LastMessage": {"MessageId": \#(5000 + index), "Text": "\#(longWord) message number \#(index + 1)", "CreatedByName": "Robin Example", "Created": "\#(date(days: Double(-index)))"}}
                """#
            }.joined(separator: ",")
            return #"{"Threads": {"EntityArray": [\#(threads)], "Total": 30}, "HasMore": false}"#
        default:
            return nil
        }
    }
}
