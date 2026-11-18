import Foundation

// Read-only models for the parity routes. Shapes follow the public REST help pages.
// Identity fields are required; everything else is optional, because institutions and
// roles see different subsets.

/// A person as the parity routes embed them: identity, display name and where their picture is.
public struct ParityPerson: Codable, Sendable, Hashable {
    public var personId: Int?
    public var fullName: String?
    /// The person's picture, absolute or relative to the site. Absent or empty when they have none.
    public var profileImageUrl: String?
    public var profileImageUrlSmall: String?

    /// The full-size picture when the site gives one, else the small one.
    public var imageURLString: String? { ProfileImage.firstUsable(profileImageUrl, profileImageUrlSmall) }

    enum CodingKeys: String, CodingKey {
        case personId = "PersonId"
        case fullName = "FullName"
        case profileImageUrl = "ProfileImageUrl"
        case profileImageUrlSmall = "ProfileImageUrlSmall"
    }

    public init(personId: Int? = nil, fullName: String? = nil, profileImageUrl: String? = nil, profileImageUrlSmall: String? = nil) {
        self.personId = personId
        self.fullName = fullName
        self.profileImageUrl = profileImageUrl
        self.profileImageUrlSmall = profileImageUrlSmall
    }
}

enum ProfileImage {
    /// The first value that is more than whitespace.
    static func firstUsable(_ values: String?...) -> String? {
        values.lazy.compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

// MARK: - Calendar

/// A personal or course calendar event. The personal route names the ID `EventId`,
/// the course route names it `Id`; both decode here.
public struct CalendarEvent: Codable, Sendable, Hashable, Identifiable {
    public var eventId: Int
    public var title: String?
    public var eventDescription: String?
    public var fromDate: Date?
    public var toDate: Date?
    public var eventType: String?
    public var courseId: Int?
    public var locationTitle: String?
    public var locationFriendlyName: String?

    public var id: Int { eventId }
    public var displayLocation: String? {
        if let locationFriendlyName, !locationFriendlyName.isEmpty { return locationFriendlyName }
        return locationTitle
    }

    enum CodingKeys: String, CodingKey {
        case eventId = "EventId"
        case id = "Id"
        case title = "EventTitle"
        case eventDescription = "Description"
        case fromDate = "FromDate"
        case toDate = "ToDate"
        case eventType = "EventType"
        case locationId = "LocationId"
        case courseId = "CourseId"
        case locationTitle = "LocationTitle"
        case locationFriendlyName = "LocationFriendlyName"
    }

    public init(eventId: Int, title: String? = nil, fromDate: Date? = nil, toDate: Date? = nil, courseId: Int? = nil) {
        self.eventId = eventId
        self.title = title
        self.fromDate = fromDate
        self.toDate = toDate
        self.courseId = courseId
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try c.decodeIfPresent(Int.self, forKey: .eventId) {
            eventId = value
        } else {
            eventId = try c.decode(Int.self, forKey: .id)
        }
        title = try c.decodeIfPresent(String.self, forKey: .title)
        eventDescription = try c.decodeIfPresent(String.self, forKey: .eventDescription)
        fromDate = try c.decodeIfPresent(Date.self, forKey: .fromDate)
        toDate = try c.decodeIfPresent(Date.self, forKey: .toDate)
        eventType = try c.decodeIfPresent(String.self, forKey: .eventType)
        // A course event carries CourseId; a personal course event carries LocationId.
        courseId = try c.decodeIfPresent(Int.self, forKey: .courseId)
        if courseId == nil, eventType?.caseInsensitiveCompare("Course") == .orderedSame {
            courseId = try c.decodeIfPresent(Int.self, forKey: .locationId)
        }
        locationTitle = try c.decodeIfPresent(String.self, forKey: .locationTitle)
        locationFriendlyName = try c.decodeIfPresent(String.self, forKey: .locationFriendlyName)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(eventId, forKey: .eventId)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(eventDescription, forKey: .eventDescription)
        try c.encodeIfPresent(fromDate, forKey: .fromDate)
        try c.encodeIfPresent(toDate, forKey: .toDate)
        try c.encodeIfPresent(eventType, forKey: .eventType)
        try c.encodeIfPresent(courseId, forKey: .courseId)
        try c.encodeIfPresent(locationTitle, forKey: .locationTitle)
        try c.encodeIfPresent(locationFriendlyName, forKey: .locationFriendlyName)
    }
}

// MARK: - Pages

/// A page element. This route uses camelCase keys.
public struct PageContent: Codable, Sendable, Hashable, Identifiable {
    public var elementId: Int
    public var title: String?
    public var layout: String?
    public var contentBlocks: [ContentBlock]?
    public var isActive: Bool?

    public var id: Int { elementId }

    /// Blocks in reading order: by `order`, then as the site lists them.
    public var orderedBlocks: [ContentBlock] {
        (contentBlocks ?? []).enumerated().sorted { lhs, rhs in
            if let a = lhs.element.order, let b = rhs.element.order, a != b { return a < b }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}

/// One block on a page. Keys follow a recorded live shape; block types other than text may
/// carry more fields, so everything but the ID is optional.
public struct ContentBlock: Codable, Sendable, Hashable, Identifiable {
    public var contentBlockId: Int
    public var type: String?
    public var title: String?
    public var rawText: String?
    /// The site's rendered HTML. Draw it natively; never in the signed-in web view.
    public var processedText: String?
    public var order: Int?
    public var layoutZone: String?
    public var files: [ContentFile]?

    public var id: Int { contentBlockId }
    public var html: String? { processedText ?? rawText }

    public init(contentBlockId: Int, type: String? = nil, title: String? = nil, processedText: String? = nil, order: Int? = nil, files: [ContentFile]? = nil) {
        self.contentBlockId = contentBlockId
        self.type = type
        self.title = title
        self.processedText = processedText
        self.order = order
        self.files = files
    }
}

public struct ContentFile: Codable, Sendable, Hashable {
    public var fileId: Int?
    public var name: String?
    public var mimeType: String?
    public var size: Int64?
    public var url: String?

    enum CodingKeys: String, CodingKey {
        case fileId, name, mimeType, size, url
    }
}

// MARK: - Assignments

public struct AssignmentFile: Codable, Sendable, Hashable, Identifiable {
    public var fileId: Int
    public var name: String?
    public var mimeType: String?
    public var size: Int64?
    public var lastModified: Date?

    public var id: Int { fileId }

    enum CodingKeys: String, CodingKey {
        case fileId = "FileId"
        case name = "Name"
        case mimeType = "MimeType"
        case size = "Size"
        case lastModified = "LastModified"
    }
}

public struct Assignment: Codable, Sendable, Hashable, Identifiable {
    public var elementId: Int
    public var title: String?
    public var text: String?
    public var isHomework: Bool?
    public var isMandatory: Bool?
    public var deadline: Date?
    public var maxScore: Double?
    public var isActive: Bool?
    public var activeFrom: Date?
    public var activeTo: Date?
    public var isSubmissionAfterDeadlineAllowed: Bool?
    public var canParticipate: Bool?
    public var canSubmitOrEditAnswer: Bool?
    public var submissionType: String?
    public var files: [AssignmentFile]?
    public var answerId: Int?

    public var id: Int { elementId }

    enum CodingKeys: String, CodingKey {
        case elementId = "ElementId"
        case title = "Title"
        case text = "Text"
        case isHomework = "IsHomework"
        case isMandatory = "IsMandatory"
        case deadline = "Deadline"
        case maxScore = "MaxScore"
        case isActive = "IsActive"
        case activeFrom = "ActiveFrom"
        case activeTo = "ActiveTo"
        case isSubmissionAfterDeadlineAllowed = "IsSubmissionAfterDeadlineAllowed"
        case canParticipate = "CanParticipate"
        case canSubmitOrEditAnswer = "CanSubmitOrEditAnswer"
        case submissionType = "SubmissionType"
        case files = "Files"
        case answerId = "AnswerId"
    }
}

/// The signed-in person's own answer to an assignment.
public struct AssignmentAnswer: Codable, Sendable, Hashable, Identifiable {
    public var answerId: Int
    public var isDraft: Bool?
    public var submitted: Date?
    public var text: String?
    public var files: [AssignmentFile]?

    public var id: Int { answerId }

    enum CodingKeys: String, CodingKey {
        case answerId = "AnswerId"
        case isDraft = "IsDraft"
        case submitted = "Submitted"
        case text = "Text"
        case files = "Files"
    }
}

// MARK: - Topics and participants

public struct Topic: Codable, Sendable, Hashable, Identifiable {
    public var topicId: Int
    public var name: String?
    public var folderId: Int?

    public var id: Int { topicId }

    enum CodingKeys: String, CodingKey {
        case topicId = "TopicId"
        case name = "TopicName"
        case folderId = "FolderId"
    }
}

public struct Participant: Codable, Sendable, Hashable, Identifiable {
    public var personId: Int
    public var fullName: String?
    public var role: String?
    public var roleId: Int?
    public var lastVisited: Date?

    public var id: Int { personId }

    enum CodingKeys: String, CodingKey {
        case personId = "PersonId"
        case fullName = "FullName"
        case role = "Role"
        case roleId = "RoleId"
        case lastVisited = "LastVisited"
    }
}

// MARK: - Messages

public struct InstantMessage: Codable, Sendable, Hashable, Identifiable {
    public var messageId: Int64
    public var threadId: Int?
    public var created: Date?
    public var createdBy: Int?
    public var createdByName: String?
    /// The sender's picture as the message itself names it. Use `MessageThread.senderImageURLString(for:)`.
    public var createdByAvatar: String?
    public var text: String?
    public var attachmentUrl: String?
    public var attachmentName: String?
    public var link: String?
    public var linkTitle: String?
    public var isSystemMessage: Bool?
    public var isDeleted: Bool?
    public var isEdited: Bool?
    public var isStarred: Bool?
    public var canDelete: Bool?

    public var id: Int64 { messageId }

    enum CodingKeys: String, CodingKey {
        case messageId = "MessageId"
        case threadId = "InstantMessageThreadId"
        case created = "Created"
        case createdBy = "CreatedBy"
        case createdByName = "CreatedByName"
        case createdByAvatar = "CreatedByAvatar"
        case text = "Text"
        case attachmentUrl = "AttachmentUrl"
        case attachmentName = "AttachmentName"
        case link = "Link"
        case linkTitle = "LinkTitle"
        case isSystemMessage = "IsSystemMessage"
        case isDeleted = "IsDeleted"
        case isEdited = "IsEdited"
        case isStarred = "IsStarred"
        case canDelete = "CanDelete"
    }
}

public struct MessageThread: Codable, Sendable, Hashable, Identifiable {
    public var threadId: Int
    public var name: String?
    public var created: Date?
    public var lastMessage: InstantMessage?
    /// The newest messages, embedded in the thread listing.
    public var recentMessages: MessageBatch?
    public var participants: [ParityPerson]?
    public var sortIndex: Int64?
    public var lastReadMessageId: Int64?

    /// Unread when the newest message is newer than the last one this person read.
    public var hasUnread: Bool {
        guard let last = lastMessage?.messageId else { return false }
        guard let read = lastReadMessageId else { return true }
        return last > read
    }

    public var id: Int { threadId }

    /// Where a message's sender's picture is: the message's own avatar field, else the thread's
    /// participant with the sender's person id (or, without an id, the same name).
    public func senderImageURLString(for message: InstantMessage) -> String? {
        if let own = ProfileImage.firstUsable(message.createdByAvatar) { return own }
        let people = participants ?? []
        if let sender = message.createdBy, let match = people.first(where: { $0.personId == sender }) {
            return match.imageURLString
        }
        if message.createdBy == nil, let name = message.createdByName, !name.isEmpty {
            return people.first { $0.fullName == name }?.imageURLString
        }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case threadId = "InstantMessageThreadId"
        case name = "Name"
        case created = "Created"
        case lastMessage = "LastMessage"
        case recentMessages = "Messages"
        case participants = "Participants"
        case sortIndex = "SortIndex"
        case lastReadMessageId = "LastReadInstantMessageId"
    }
}

public struct ThreadList: Decodable, Sendable {
    public var threads: [MessageThread]
    public var hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case threads = "Threads"
        case hasMore = "HasMore"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        threads = try c.decode(Page<MessageThread>.self, forKey: .threads).items
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
    }
}

public struct MessageList: Decodable, Sendable {
    public var messages: [InstantMessage]
    public var hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case messages = "Messages"
        case hasMore = "HasMore"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = try c.decode(Page<InstantMessage>.self, forKey: .messages).items
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
    }
}

/// A list of messages inside another response.
public struct MessageBatch: Codable, Sendable, Hashable {
    public var items: [InstantMessage]?

    enum CodingKeys: String, CodingKey {
        case items = "EntityArray"
    }

    public init(items: [InstantMessage]?) {
        self.items = items
    }
}

// MARK: - Notifications

public struct ParityNotification: Codable, Sendable, Hashable, Identifiable {
    public var notificationId: Int
    public var text: String?
    public var published: Date?
    public var publishedBy: ParityPerson?
    public var type: String?
    public var url: String?
    public var contentUrl: String?
    public var isRead: Bool?
    public var isAnonymous: Bool?

    public var id: Int { notificationId }

    enum CodingKeys: String, CodingKey {
        case notificationId = "NotificationId"
        case text = "Text"
        case published = "PublishedDate"
        case publishedBy = "PublishedBy"
        case type = "Type"
        case url = "Url"
        case contentUrl = "ContentUrl"
        case isRead = "IsRead"
        case isAnonymous = "IsAnonymous"
    }
}

// MARK: - Bulletins

public struct Bulletin: Codable, Sendable, Hashable, Identifiable {
    public struct Image: Codable, Sendable, Hashable {
        public var previewFileUrl: String?
        public var originalFileUrl: String?

        enum CodingKeys: String, CodingKey {
            case previewFileUrl = "PreviewFileUrl"
            case originalFileUrl = "OriginalFileUrl"
        }
    }

    public var bulletinId: Int
    public var text: String?
    public var embedUrl: String?
    public var pinned: Bool?
    public var allowComments: Bool?
    public var resourcesCount: Int?
    public var commentsCount: Int?
    public var attachedImages: [Image]?
    public var activeFrom: Date?
    public var activeTo: Date?
    public var published: Date?
    public var publishedBy: ParityPerson?

    public var id: Int { bulletinId }

    enum CodingKeys: String, CodingKey {
        case bulletinId = "LightBulletinId"
        case text = "Text"
        case embedUrl = "EmbedUrl"
        case pinned = "Pinned"
        case allowComments = "AllowComments"
        case resourcesCount = "ResourcesCount"
        case commentsCount = "CommentsCount"
        case attachedImages = "AttachedImages"
        case activeFrom = "ActiveFromDate"
        case activeTo = "ActiveToDate"
        case published = "PublishedDate"
        case publishedBy = "PublishedBy"
    }
}

public struct BulletinComment: Codable, Sendable, Hashable, Identifiable {
    public var commentId: Int
    public var author: ParityPerson?
    public var text: String?
    public var allowEdit: Bool?
    public var allowDelete: Bool?
    public var created: Date?

    public var id: Int { commentId }

    enum CodingKeys: String, CodingKey {
        case commentId = "Id"
        case author = "Author"
        case text = "CommentText"
        case allowEdit = "AllowEditComment"
        case allowDelete = "AllowDeleteComment"
        case created = "CreatedDateTime"
    }
}

/// A material attached to a bulletin.
public struct BulletinElement: Codable, Sendable, Hashable, Identifiable {
    public var elementId: Int
    public var elementType: String
    public var title: String?
    public var url: String?
    public var contentUrl: String?

    public var id: String { "\(elementType)-\(elementId)" }

    enum CodingKeys: String, CodingKey {
        case elementId = "ElementId"
        case elementType = "ElementType"
        case title = "Title"
        case url = "Url"
        case contentUrl = "ContentUrl"
    }
}

// MARK: - Assessment

/// A gradebook column.
public struct GradeItem: Codable, Sendable, Hashable, Identifiable {
    public var gradeBookItemId: Int
    public var title: String?
    public var weight: Double?
    public var isFinal: Bool?
    public var elementType: String?
    public var elementId: Int?
    public var maxScore: Double?
    public var useScore: Bool?
    public var isAssessmentVisible: Bool?
    public var deadline: Date?

    public var id: Int { gradeBookItemId }

    enum CodingKeys: String, CodingKey {
        case gradeBookItemId = "GradeBookItemId"
        case title = "Title"
        case weight = "Weight"
        case isFinal = "IsFinal"
        case elementType = "ElementType"
        case elementId = "ElementId"
        case maxScore = "MaxScore"
        case useScore = "UseScore"
        case isAssessmentVisible = "IsAssessmentVisible"
        case deadline = "Deadline"
    }
}

public struct AssessmentScale: Codable, Sendable, Hashable, Identifiable {
    public struct Value: Codable, Sendable, Hashable {
        public var assessmentItemId: Int
        public var title: String?
        public var orderPosition: Int?

        enum CodingKeys: String, CodingKey {
            case assessmentItemId = "AssessmentItemId"
            case title = "Title"
            case orderPosition = "OrderPosition"
        }
    }

    public var scaleId: Int
    public var title: String?
    public var values: [Value]?

    public var id: Int { scaleId }

    enum CodingKeys: String, CodingKey {
        case scaleId = "AssessmentScaleId"
        case title = "Title"
        case values = "Values"
    }
}

/// What a course grades: its gradebook columns and scales.
public struct AssessmentRecord: Codable, Sendable, Hashable {
    public var items: [GradeItem]?
    public var finalItems: [GradeItem]?
    public var scales: [AssessmentScale]?
    public var isScoreInUse: Bool?

    enum CodingKeys: String, CodingKey {
        case items = "AssessmentRecordItems"
        case finalItems = "FinalAssessmentRecordItems"
        case scales = "AssessmentScales"
        case isScoreInUse = "IsScoreInUse"
    }
}

/// One person's results in a course's gradebook.
public struct PersonAssessments: Codable, Sendable, Hashable, Identifiable {
    public struct Result: Codable, Sendable, Hashable {
        public var gradeBookItemId: Int
        public var isExempt: Bool?
        public var score: Double?
        public var overwrittenAssessmentItemId: Int?
        public var overwrittenScore: Double?
        public var answerSubmitted: Bool?
        public var assessmentVisible: Bool?

        enum CodingKeys: String, CodingKey {
            case gradeBookItemId = "GradeBookItemId"
            case isExempt = "IsExempt"
            case score = "Score"
            case overwrittenAssessmentItemId = "OverwrittenAssessmentItemId"
            case overwrittenScore = "OverwrittenScore"
            case answerSubmitted = "AnswerSubmitted"
            case assessmentVisible = "AssessmentVisible"
        }
    }

    public var personId: Int
    public var results: [Result]?

    public var id: Int { personId }

    enum CodingKeys: String, CodingKey {
        case personId = "PersonId"
        case results = "PersonAssessments"
    }
}

// MARK: - Course cards

/// A course card from the starred or unstarred listing.
public struct CourseCard: Codable, Sendable, Hashable, Identifiable {
    public var courseId: Int
    public var title: String?
    public var isFavourite: Bool?
    public var isCompleted: Bool?

    public var id: Int { courseId }

    enum CodingKeys: String, CodingKey {
        case courseId = "CourseId"
        case title = "Title"
        case isFavourite = "IsFavouriteCourse"
        case isCompleted = "IsCompletedCourse"
    }
}

// MARK: - Message recipients

/// A result from the recipient search. People carry a user name; groups and courses do not.
public struct Recipient: Codable, Sendable, Hashable, Identifiable {
    public var recipientId: Int
    public var label: String?
    public var shortLabel: String?
    public var userName: String?
    public var typeName: String?
    public var organization: String?
    public var role: String?
    public var canReceive: Bool?

    public var id: Int { recipientId }
    public var isPerson: Bool { !(userName ?? "").isEmpty }

    enum CodingKeys: String, CodingKey {
        case recipientId = "Id"
        case label = "Label"
        case shortLabel = "ShortLabel"
        case userName = "UserName"
        case typeName = "TypeName"
        case organization = "Organization"
        case role = "RoleInHierarchyTitle"
        case canReceive = "CanReceive"
    }

    public init(recipientId: Int, label: String?, userName: String? = nil, canReceive: Bool? = true) {
        self.recipientId = recipientId
        self.label = label
        self.userName = userName
        self.canReceive = canReceive
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The ID may arrive as a number or a numeric string.
        if let number = try? c.decode(Int.self, forKey: .recipientId) {
            recipientId = number
        } else if let text = try? c.decode(String.self, forKey: .recipientId), let number = Int(text) {
            recipientId = number
        } else {
            throw DecodingError.dataCorruptedError(forKey: .recipientId, in: c, debugDescription: "Recipient ID is not numeric")
        }
        label = try c.decodeIfPresent(String.self, forKey: .label)
        shortLabel = try c.decodeIfPresent(String.self, forKey: .shortLabel)
        userName = try c.decodeIfPresent(String.self, forKey: .userName)
        typeName = try c.decodeIfPresent(String.self, forKey: .typeName)
        organization = try c.decodeIfPresent(String.self, forKey: .organization)
        role = try c.decodeIfPresent(String.self, forKey: .role)
        canReceive = try c.decodeIfPresent(Bool.self, forKey: .canReceive)
    }
}
