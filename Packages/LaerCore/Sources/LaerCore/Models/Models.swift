import Foundation

/// An itslearning institution, resolved at runtime through the public site lookup.
public struct Site: Codable, Sendable, Hashable {
    public var shortName: String
    public var title: String
    public var baseURL: URL
    public var customerId: Int
    public var isPersonalRestApiEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case shortName = "ShortName"
        case title = "Title"
        case baseURL = "BaseUrl"
        case customerId = "CustomerId"
        case isPersonalRestApiEnabled = "IsPersonalRestApiEnabled"
    }

    public init(shortName: String, title: String, baseURL: URL, customerId: Int, isPersonalRestApiEnabled: Bool? = nil) {
        self.shortName = shortName
        self.title = title
        self.baseURL = baseURL
        self.customerId = customerId
        self.isPersonalRestApiEnabled = isPersonalRestApiEnabled
    }
}

public struct Person: Codable, Sendable, Hashable {
    public var personId: Int
    public var fullName: String?
    public var timeZoneId: String?
    /// The person's picture, absolute or relative to the site. Absent when they have none.
    public var profileImageUrl: String?

    enum CodingKeys: String, CodingKey {
        case personId = "PersonId"
        case fullName = "FullName"
        case timeZoneId = "TimeZoneId"
        case profileImageUrl = "ProfileImageUrl"
    }

    public init(personId: Int, fullName: String? = nil, timeZoneId: String? = nil, profileImageUrl: String? = nil) {
        self.personId = personId
        self.fullName = fullName
        self.timeZoneId = timeZoneId
        self.profileImageUrl = profileImageUrl
    }
}

public struct Course: Codable, Sendable, Hashable, Identifiable {
    public var courseId: Int
    public var title: String
    public var friendlyName: String?
    public var courseCode: String?
    public var url: String?
    public var lastUpdated: Date?
    public var newNotificationsCount: Int?
    public var newBulletinsCount: Int?

    public var id: Int { courseId }
    public var displayTitle: String {
        if let friendlyName, !friendlyName.isEmpty { return friendlyName }
        return title
    }

    enum CodingKeys: String, CodingKey {
        case courseId = "CourseId"
        case title = "Title"
        case friendlyName = "FriendlyName"
        case courseCode = "CourseCode"
        case url = "Url"
        case lastUpdated = "LastUpdatedUtc"
        case newNotificationsCount = "NewNotificationsCount"
        case newBulletinsCount = "NewBulletinsCount"
    }

    public init(courseId: Int, title: String, friendlyName: String? = nil, courseCode: String? = nil, url: String? = nil, lastUpdated: Date? = nil) {
        self.courseId = courseId
        self.title = title
        self.friendlyName = friendlyName
        self.courseCode = courseCode
        self.url = url
        self.lastUpdated = lastUpdated
    }
}

public struct CourseUpdate: Codable, Sendable, Hashable, Identifiable {
    public struct Author: Codable, Sendable, Hashable {
        public var fullName: String?
        public var profileImageUrl: String?
        public var profileImageUrlSmall: String?
        enum CodingKeys: String, CodingKey {
            case fullName = "FullName"
            case profileImageUrl = "ProfileImageUrl"
            case profileImageUrlSmall = "ProfileImageUrlSmall"
        }

        /// The full-size picture when the site gives one, else the small one.
        public var imageURLString: String? { ProfileImage.firstUsable(profileImageUrl, profileImageUrlSmall) }
    }

    public struct Bulletin: Codable, Sendable, Hashable {
        public var text: String?
        enum CodingKeys: String, CodingKey { case text = "Text" }
    }

    public var notificationId: Int
    public var text: String?
    public var locationTitle: String?
    public var published: Date?
    public var publishedBy: Author?
    public var url: String?
    public var contentUrl: String?
    public var elementId: Int?
    public var elementType: String?
    public var lightBulletin: Bulletin?

    public var id: Int { notificationId }

    /// Native text only. Rich content stays on the website.
    public var displayText: String {
        if let body = lightBulletin?.text, !body.isEmpty { return PlainText.from(body) }
        return PlainText.from(text ?? "")
    }

    enum CodingKeys: String, CodingKey {
        case notificationId = "NotificationId"
        case text = "Text"
        case locationTitle = "LocationTitle"
        case published = "PublishedDate"
        case publishedBy = "PublishedBy"
        case url = "Url"
        case contentUrl = "ContentUrl"
        case elementId = "ElementId"
        case elementType = "ElementType"
        case lightBulletin = "LightBulletin"
    }
}

public struct Resource: Codable, Sendable, Hashable, Identifiable {
    public var elementId: Int
    public var elementType: String
    public var title: String
    public var courseId: Int?
    public var url: String?
    public var contentUrl: String?
    public var path: String?
    public var learningToolId: Int?
    public var learningObjectId: Int?
    public var learningObjectInstanceId: Int?
    public var active: Bool?
    public var isTopicOrPlanFolder: Bool?

    /// An element ID is unique only together with its type.
    public var id: String { "\(elementType)-\(elementId)" }

    public var isFolder: Bool {
        elementType.caseInsensitiveCompare("Folder") == .orderedSame
    }

    enum CodingKeys: String, CodingKey {
        case elementId = "ElementId"
        case elementType = "ElementType"
        case title = "Title"
        case courseId = "CourseId"
        case url = "Url"
        case contentUrl = "ContentUrl"
        case path = "Path"
        case learningToolId = "LearningToolId"
        case learningObjectId = "LearningObjectId"
        case learningObjectInstanceId = "LearningObjectInstanceId"
        case active = "Active"
        case isTopicOrPlanFolder = "IsTopicOrPlanFolder"
    }

    public init(elementId: Int, elementType: String, title: String, courseId: Int? = nil, url: String? = nil, contentUrl: String? = nil, learningObjectId: Int? = nil, learningObjectInstanceId: Int? = nil) {
        self.elementId = elementId
        self.elementType = elementType
        self.title = title
        self.courseId = courseId
        self.url = url
        self.contentUrl = contentUrl
        self.learningObjectId = learningObjectId
        self.learningObjectInstanceId = learningObjectInstanceId
    }
}

public struct StudyTask: Codable, Sendable, Hashable, Identifiable {
    public var taskId: Int
    public var title: String
    public var url: String?
    public var contentUrl: String?
    public var elementId: Int?
    public var elementType: String?
    public var courseId: Int?
    public var courseTitle: String?
    public var status: String?
    public var deadline: Date?
    public var isHomework: Bool?

    public var id: Int { taskId }

    enum CodingKeys: String, CodingKey {
        case taskId = "TaskId"
        case title = "Title"
        case url = "Url"
        case contentUrl = "ContentUrl"
        case elementId = "ElementId"
        case elementType = "ElementType"
        case courseId = "LocationId"
        case courseTitle = "LocationTitle"
        case status = "Status"
        case deadline = "Deadline"
        case isHomework = "Homework"
    }
}

/// A teaching plan from the full plan route. Its fields are camel case, unlike most routes.
public struct PlanPreview: Codable, Sendable, Hashable, Identifiable {
    public struct Topic: Codable, Sendable, Hashable {
        public var id: Int?
        public var name: String?
    }

    public struct Element: Codable, Sendable, Hashable, Identifiable {
        public var id: Int
        public var title: String?
        public var type: String?
        public var typeName: String?
        public var url: String?
        public var isFolder: Bool?
        public var isResource: Bool?
        public var isHomework: Bool?
    }

    public var planId: Int
    public var name: String?
    public var planDescription: String?
    public var start: Date?
    public var stop: Date?
    public var courseId: Int?
    public var order: Int?
    public var url: String?
    public var isCurrentPlan: Bool?
    public var topic: Topic?
    public var elements: [Element]?

    public var id: Int { planId }

    enum CodingKeys: String, CodingKey {
        case planId = "id"
        case name = "title"
        case planDescription = "displayDescription"
        case start
        case stop
        case courseId
        case order = "orderNumber"
        case url
        case isCurrentPlan
        case topic
        case elements
    }
}

extension Resource {
    /// A plan's element in the shape the material routes expect.
    public init(planElement element: PlanPreview.Element, courseId: Int?) {
        self.init(
            elementId: element.id,
            elementType: element.isFolder == true ? "Folder" : "LearningToolElement",
            title: element.title ?? "Material",
            courseId: courseId,
            url: element.url
        )
    }
}

/// Reduces API text that may contain markup to plain text for native display.
public enum PlainText {
    public static func from(_ source: String) -> String {
        guard source.contains("<") || source.contains("&") else {
            return source.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var text = source.replacingOccurrences(of: #"<(br|/p|/div|/li)[^>]*>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"]
        for (entity, value) in entities {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
