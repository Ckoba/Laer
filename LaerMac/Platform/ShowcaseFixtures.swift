import Foundation
import LaerCore

/// A believable student's week for design review screenshots, switched on with
/// `-LaerFixtureShowcase YES` beside fixture mode: eight courses, all favourited as itslearning
/// does by default, with tasks, events, updates and messages around today. Every value is invented.
enum ShowcaseFixtures {
    static var isOn: Bool { UserDefaults.standard.bool(forKey: "LaerFixtureShowcase") }

    static let courses: [(id: Int, title: String, code: String)] = [
        (21, "Biology B", "BIO-B"),
        (22, "Danish A", "DAN-A"),
        (23, "Mathematics A", "MAT-A"),
        (24, "English B", "ENG-B"),
        (25, "History A", "HIS-A"),
        (26, "Chemistry C", "CHE-C"),
        (27, "Physical Education", "PE"),
        (28, "Social Studies B", "SAM-B"),
    ]

    private static func title(_ id: Int) -> String { courses.first { $0.id == id }?.title ?? "Course" }

    /// This week's and next week's plan topic, and a recent update, per course.
    private static let topics: [Int: (now: String, next: String, update: String)] = [
        21: ("Cell respiration and enzymes", "Photosynthesis", "New material: slides on cell respiration"),
        22: ("The modern short story", "Poetry after 1950", "Feedback on your analyses is ready"),
        23: ("Integration by substitution", "Differential equations", "Solutions to problem set 5 are posted"),
        24: ("Persuasive writing", "Shakespeare's sonnets", "Reading list for the essay"),
        25: ("The Cold War, 1947 to 1962", "Decolonisation", "Chapter 4 is now in Materials"),
        26: ("Acids and bases", "Redox reactions", "Lab safety form for next week"),
        27: ("Endurance training", "Team sports", "Bring indoor shoes on Thursday"),
        28: ("Media and democracy", "Welfare models", "Group work: choose your topic by Friday"),
    ]

    /// A course's topics in order, and which topic each of its five plans sits under: the
    /// introduction, an earlier plan, this week's, next week's and a later one. The first topic is
    /// all past, so it starts collapsed.
    private static let units: [Int: (topics: [String], slots: [Int], earlier: String, later: String)] = [
        21: (["Basics of biology", "Cell biology", "Ecology"], [0, 0, 1, 1, 2], "The cell and its organelles", "Populations and food webs"),
        22: (["Prose", "Poetry"], [0, 0, 0, 1, 1], "Reading the novel excerpt", "Contemporary poets"),
        23: (["Algebra review", "Calculus"], [0, 0, 1, 1, 1], "Rules of differentiation", "Applications of integrals"),
        24: (["Writing", "Literature"], [0, 0, 0, 1, 1], "Structure of an essay", "Reading a novel"),
        25: (["Europe after 1945", "The Cold War", "Empire and decolonisation"], [0, 0, 1, 2, 2], "Postwar reconstruction", "The Suez crisis"),
        26: (["Laboratory basics", "Chemical reactions"], [0, 0, 1, 1, 1], "Measuring and safety", "Titration"),
        27: (["Fitness", "Games"], [0, 0, 0, 1, 1], "Testing your fitness", "Tactics in team games"),
        28: (["Society", "Politics", "Economy"], [0, 0, 1, 1, 2], "Social structure", "The labour market"),
    ]
    private static let defaultUnit = (topics: ["Unit one", "Unit two"], slots: [0, 0, 1, 1, 1], earlier: "Earlier plan", later: "Later plan")

    private static func date(days: Double = 0, hours: Double = 0) -> String {
        let start = Calendar.current.startOfDay(for: Date())
        return ISO8601DateFormatter().string(from: start.addingTimeInterval(days * 86_400 + hours * 3600))
    }

    /// The course id in a `/courses/{id}/` or `/course/{id}/` path, if any.
    private static func courseId(_ path: String) -> Int? {
        guard let range = path.range(of: #"/courses?/(\d+)/"#, options: .regularExpression) else { return nil }
        return Int(path[range].filter(\.isNumber))
    }

    static func body(for request: ReadRequest) -> String? {
        let path = request.path
        switch request.routeTemplate {
        case "person/v1":
            return #"{"PersonId": 1001, "FullName": "Alex Example", "TimeZoneId": "UTC"}"#
        case "courses/v4":
            let items = courses.map { #"{"CourseId": \#($0.id), "Title": "\#($0.title)", "CourseCode": "\#($0.code)", "Url": "/main.aspx?CourseID=\#($0.id)"}"# }
            return FixtureTransport.page(items.joined(separator: ","), count: courses.count)
        case "courses/cards/starred/v1":
            let starred = courses.map(\.id).filter { FixtureWrites.shared.isStarred(courseId: $0, initially: true) }
            let items = starred.map { #"{"CourseId": \#($0), "IsFavouriteCourse": true}"# }.joined(separator: ",")
            return FixtureTransport.page(items, count: starred.count)
        case "tasks/v1":
            return FixtureTransport.page(#"""
            {"TaskId": 901, "Title": "Lab report: enzyme activity", "LocationId": 21, "LocationTitle": "Biology B",
             "ElementId": 70, "ElementType": "LearningToolElement", "Deadline": "\#(date(days: -1, hours: 23))", "Status": "InProgress"},
            {"TaskId": 902, "Title": "Analysis of a short story", "LocationId": 22, "LocationTitle": "Danish A",
             "ElementId": 71, "ElementType": "CustomActivity", "Deadline": "\#(date(days: 1, hours: 12))", "Status": "NotStarted"},
            {"TaskId": 903, "Title": "Problem set 6: integrals", "LocationId": 23, "LocationTitle": "Mathematics A",
             "ElementId": 72, "ElementType": "CustomActivity", "Deadline": "\#(date(days: 3, hours: 8))", "Status": "NotStarted"},
            {"TaskId": 904, "Title": "Read chapter 4 before class", "LocationId": 25, "LocationTitle": "History A", "Homework": true},
            {"TaskId": 905, "Title": "Essay outline: media and democracy", "LocationId": 28, "LocationTitle": "Social Studies B",
             "ElementId": 73, "ElementType": "CustomActivity", "Deadline": "\#(date(days: 6, hours: 22))", "Status": "NotStarted"},
            {"TaskId": 906, "Title": "Vocabulary quiz", "LocationId": 24, "LocationTitle": "English B",
             "ElementId": 74, "ElementType": "CustomActivity", "Deadline": "\#(date(days: -1, hours: 10))", "Status": "NotStarted"}
            """#, count: 6)
        case "calendar/events/v1":
            // A school timetable: mornings and early afternoons, Monday to Friday around today.
            let slots: [(Int, Double, Double)] = [(23, 8, 9.5), (21, 9.75, 11.25), (22, 12, 13.5), (24, 13.75, 15)]
            var items: [String] = []
            for day in -3..<10 {
                let weekday = Calendar.current.component(.weekday, from: Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(day) * 86_400))
                if weekday == 1 || weekday == 7 { continue }
                for (index, slot) in slots.enumerated() {
                    let course = courses[(index + day + 30) % courses.count]
                    let id = 2000 + (day + 3) * 10 + index
                    let use = index == 0 ? slot.0 : course.id
                    items.append(#"""
                    {"EventId": \#(id), "EventTitle": "\#(title(use))", "FromDate": "\#(date(days: Double(day), hours: slot.1))", "ToDate": "\#(date(days: Double(day), hours: slot.2))",
                     "EventType": "Course", "LocationId": \#(use), "LocationTitle": "\#(title(use))"}
                    """#)
                }
            }
            items.append(#"{"EventId": 2999, "EventTitle": "Study trip to the natural history museum", "FromDate": "\#(date(days: 2))", "ToDate": "\#(date(days: 2, hours: 23.99))"}"#)
            return FixtureTransport.page(items.joined(separator: ","), count: items.count)
        case "courses/{id}/calendarevents/v1":
            let id = courseId(path) ?? 21
            return FixtureTransport.page(#"""
            {"Id": \#(id * 10 + 1), "EventTitle": "\#(title(id))", "FromDate": "\#(date(days: 1, hours: 9.75))", "ToDate": "\#(date(days: 1, hours: 11.25))", "CourseId": \#(id)},
            {"Id": \#(id * 10 + 2), "EventTitle": "\#(title(id))", "FromDate": "\#(date(days: 3, hours: 12))", "ToDate": "\#(date(days: 3, hours: 13.5))", "CourseId": \#(id)}
            """#, count: 2)
        case "courses/{id}/stream/v1":
            let id = courseId(path) ?? 21
            return FixtureTransport.page(#"""
            {"NotificationId": \#(id * 100 + 1), "Text": "\#(topics[id]?.update ?? "New material")", "PublishedDate": "\#(date(hours: -3))",
             "PublishedBy": {"FullName": "Sam Teacher"\#(FixtureAvatars.field(for: "Sam Teacher"))}, "Url": "/note/\#(id * 100 + 1)"},
            {"NotificationId": \#(id * 100 + 2), "Text": "Plan updated for next week", "PublishedDate": "\#(date(days: -2))",
             "PublishedBy": {"FullName": "Sam Teacher"\#(FixtureAvatars.field(for: "Sam Teacher"))}}
            """#, count: 2)
        case "courses/{id}/bulletins/v1":
            let id = courseId(path) ?? 21
            guard id == 21 || id == 23 else { return FixtureTransport.page("", count: 0) }
            return FixtureTransport.page(#"""
            {"LightBulletinId": \#(id), "Text": "<p>Remember: the \#(id == 21 ? "lab" : "test") is moved to <b>Thursday</b>. Bring a calculator and your notes from last week.</p>",
             "Pinned": true, "AllowComments": true, "CommentsCount": 2, "PublishedDate": "\#(date(days: -1, hours: 15))",
             "PublishedBy": {"FullName": "Sam Teacher"\#(FixtureAvatars.field(for: "Sam Teacher"))}}
            """#, count: 1)
        case "courses/{id}/resources/v1":
            return #"""
            {"Resources": \#(FixtureTransport.page(#"""
            {"ElementId": 701, "ElementType": "Folder", "Title": "Week 47"},
            {"ElementId": 702, "ElementType": "LearningToolElement", "Title": "Syllabus.pdf", "LearningObjectId": 9001, "LearningObjectInstanceId": 9101},
            {"ElementId": 705, "ElementType": "LearningToolElement", "Title": "Slides: cell respiration.pdf", "LearningObjectId": 9003, "LearningObjectInstanceId": 9103},
            {"ElementId": 706, "ElementType": "LearningToolElement", "Title": "Exam guidelines.pdf", "LearningObjectId": 9004, "LearningObjectInstanceId": 9104},
            {"ElementId": 703, "ElementType": "LearningToolElement", "Title": "Course page", "Url": "/page/703"}
            """#, count: 5))}
            """#
        case "course/{id}/plans/all/v1":
            let id = courseId(path) ?? 21
            let unit = units[id] ?? Self.defaultUnit
            func topic(_ slot: Int) -> String {
                let index = unit.slots[slot]
                return #""topic": {"id": \#(id * 100 + index + 1), "name": "\#(unit.topics[index])"}"#
            }
            return #"""
            {"entityArray": [
              {"id": \#(id * 10 + 1), "title": "\#(topics[id]?.now ?? "This week")", "start": "\#(date(days: -2))", "stop": "\#(date(days: 4))",
               "displayDescription": "<p>Read pages 112 to 130 before class and bring your notes.</p>", "courseId": \#(id), "orderNumber": 4,
               "elements": [{"id": 705, "title": "Slides: cell respiration.pdf", "isResource": true}, {"id": 702, "title": "Syllabus.pdf", "isResource": true}],
               \#(topic(2))},
              {"id": \#(id * 10 + 2), "title": "\#(topics[id]?.next ?? "Next week")", "start": "\#(date(days: 7))", "stop": "\#(date(days: 13))",
               "courseId": \#(id), "orderNumber": 5, "elements": [], \#(topic(3))},
              {"id": \#(id * 10 + 3), "title": "Introduction to the course", "start": "\#(date(days: -14))", "stop": "\#(date(days: -8))",
               "courseId": \#(id), "orderNumber": 1, "elements": [], \#(topic(0))},
              {"id": \#(id * 10 + 4), "title": "\#(unit.earlier)", "start": "\#(date(days: -7))", "stop": "\#(date(days: -3))",
               "courseId": \#(id), "orderNumber": 2, "elements": [], \#(topic(1))},
              {"id": \#(id * 10 + 5), "title": "\#(unit.later)", "start": "\#(date(days: 14))", "stop": "\#(date(days: 20))",
               "courseId": \#(id), "orderNumber": 6, "elements": [], \#(topic(4))}
            ], "total": 5, "currentPageIndex": 0, "pageSize": 100}
            """#
        case "courses/{id}/topics/v1":
            let id = courseId(path) ?? 21
            let unit = units[id] ?? Self.defaultUnit
            let items = unit.topics.enumerated().map { index, name in
                #"{"TopicId": \#(id * 100 + index + 1), "TopicName": "\#(name)", "FolderId": \#(7000 + id * 10 + index)}"#
            }.joined(separator: ",")
            return FixtureTransport.page(items, count: unit.topics.count)
        case "notifications/v2":
            return FixtureTransport.page(#"""
            {"NotificationId": 1, "Text": "New update in Biology B", "PublishedDate": "\#(date(hours: -3))", "IsRead": false, "PublishedBy": {"FullName": "Sam Teacher"\#(FixtureAvatars.field(for: "Sam Teacher"))}, "Url": "/n/1"},
            {"NotificationId": 2, "Text": "Feedback on your Danish A assignment", "PublishedDate": "\#(date(days: -1))", "IsRead": false, "PublishedBy": {"FullName": "Sam Teacher"\#(FixtureAvatars.field(for: "Sam Teacher"))}},
            {"NotificationId": 3, "Text": "Plan updated in Mathematics A", "PublishedDate": "\#(date(days: -2))", "IsRead": true}
            """#, count: 3)
        case "instantmessages/messagethreads/unread/count/v1": return "2"
        case "instantmessages/messagethreads/v4":
            let people = ["Sam Teacher", "Robin Example", "Kim Example", "Jo Example", "Noa Example"]
            let lines = ["See you on Thursday.", "Can you share the notes from today?", "I added my part to the slides.",
                         "Thanks, that helped a lot!", "Are we meeting in the library?"]
            let threads = people.enumerated().map { index, name in
                #"""
                {"InstantMessageThreadId": \#(300 + index), \#(index == 2 ? #""Name": "Biology group","# : "") "SortIndex": \#(900 - index),
                 "LastReadInstantMessageId": \#(index < 2 ? 0 : 20 + index),
                 "Participants": [{"PersonId": \#(2 + index), "FullName": "\#(name)"\#(FixtureAvatars.field(for: name))},{"PersonId": 1001, "FullName": "Alex Example"}],
                 "LastMessage": {"MessageId": \#(20 + index), "Text": "\#(lines[index])", "CreatedByName": "\#(name)", "Created": "\#(date(days: Double(-index), hours: 10))"}}
                """#
            }.joined(separator: ",")
            return #"{"Threads": {"EntityArray": [\#(threads)], "Total": 5}, "HasMore": false}"#
        default:
            return nil
        }
    }
}
