import Foundation

// Writes change the account. Each call here is made once, for one explicit user action, and is
// never retried, queued or replayed. See AGENTS.md.

public enum WriteMethod: String, Sendable, Hashable {
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
}

/// One file part of a multipart upload.
public struct UploadPart: Sendable, Hashable {
    public var fieldName: String
    public var fileName: String
    public var contentType: String
    public var data: Data

    public init(fieldName: String = "file", fileName: String, contentType: String, data: Data) {
        self.fieldName = fieldName
        self.fileName = fileName
        self.contentType = contentType
        self.data = data
    }
}

public enum WriteBody: Sendable, Hashable {
    case none
    case json(Data)
    case multipart([UploadPart])
}

/// A write against the signed-in site. `routeTemplate` is the only form that may be logged.
public struct WriteRequest: Sendable, Hashable {
    public var method: WriteMethod
    public var path: String
    public var query: [URLQueryItem]
    public var body: WriteBody
    public var routeTemplate: String

    public init(method: WriteMethod, path: String, query: [URLQueryItem] = [], body: WriteBody = .none, routeTemplate: String) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.routeTemplate = routeTemplate
    }

    /// Path and query, relative to the site origin.
    public var relativeURLString: String {
        var components = URLComponents()
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        return components.string ?? path
    }

    /// The Content-Type header and bytes a transport sends for this body. Nil for no body.
    public func encodedBody(boundary: String = "LaerBoundary-\(UUID().uuidString)") -> (contentType: String, data: Data)? {
        switch body {
        case .none:
            return nil
        case .json(let data):
            return ("application/json; charset=utf-8", data)
        case .multipart(let parts):
            let headers = parts.map { part in
                let name = Self.quoted(part.fieldName)
                let file = Self.quoted(part.fileName)
                return Data(("--\(boundary)\r\n"
                    + "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(file)\"\r\n"
                    + "Content-Type: \(part.contentType)\r\n\r\n").utf8)
            }
            let lineBreak = Data("\r\n".utf8)
            let closing = Data("--\(boundary)--\r\n".utf8)
            let segments = zip(headers, parts)
            let capacity = segments.reduce(closing.count) { size, segment in
                size + segment.0.count + segment.1.data.count + lineBreak.count
            }
            var data = Data()
            data.reserveCapacity(capacity)
            for (header, part) in segments {
                data.append(header)
                data.append(part.data)
                data.append(lineBreak)
            }
            data.append(closing)
            return ("multipart/form-data; boundary=\(boundary)", data)
        }
    }

    /// Quotes and line breaks would end the header early.
    private static func quoted(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

/// A transport that can also change the account. Implementations send exactly once.
public protocol WriteTransport: ReadTransport {
    func sendWrite(_ request: WriteRequest) async throws -> ReadResponse
}

extension ReadResponse {
    /// Validates a write's answer. An empty body is fine; a login page is not.
    public func validatedWrite() throws -> Data {
        switch status {
        case 200..<300: break
        case 300..<400, 401: throw APIError.signedOut
        case 403: throw APIError.forbidden
        case 404: throw APIError.notFound
        case 429: throw APIError.throttled(retryAfter: retryAfter)
        case 400, 409, 422:
            // The service understood and refused, so nothing changed.
            let reason = String(decoding: body.prefix(500), as: UTF8.self)
            throw reason.contains("ManualByStudent") ? WriteError.notStudentCompletable : WriteError.refused
        case 500..<600: throw APIError.server(status: status)
        default: throw APIError.unexpectedStatus(status)
        }
        if contentType.lowercased().contains("text/html") { throw APIError.signedOut }
        return body
    }
}

// MARK: - Write models

/// A file in temporary storage, ready to attach to an answer.
public struct UploadedTempFile: Codable, Sendable, Hashable {
    public var fileRepoId: String
    public var signedFileRepoId: String?
    public var name: String?
    public var mimeType: String?
    public var sourceType: Int?
    public var isTemplate: Bool?

    enum CodingKeys: String, CodingKey {
        case fileRepoId = "FileRepoId"
        case signedFileRepoId = "SignedFileRepoId"
        case name = "Name"
        case mimeType = "MimeType"
        case sourceType = "SourceType"
        case isTemplate = "IsTemplate"
    }

    public init(fileRepoId: String, signedFileRepoId: String? = nil, name: String? = nil, mimeType: String? = nil, sourceType: Int? = nil, isTemplate: Bool? = nil) {
        self.fileRepoId = fileRepoId
        self.signedFileRepoId = signedFileRepoId
        self.name = name
        self.mimeType = mimeType
        self.sourceType = sourceType
        self.isTemplate = isTemplate
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fileRepoId = try c.decode(String.self, forKey: .fileRepoId)
        signedFileRepoId = try c.decodeIfPresent(String.self, forKey: .signedFileRepoId)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType)
        // The help page shows this as a number in JSON and a name in XML.
        sourceType = try? c.decodeIfPresent(Int.self, forKey: .sourceType)
        isTemplate = try c.decodeIfPresent(Bool.self, forKey: .isTemplate)
    }
}

/// A message attachment in temporary storage. The route answers with .NET tuples.
public struct MessageAttachment: Decodable, Sendable, Hashable {
    public var fileId: String
    public var name: String?

    enum CodingKeys: String, CodingKey {
        case item1 = "m_Item1", item2 = "m_Item2", plain1 = "Item1", plain2 = "Item2"
    }

    public init(fileId: String, name: String?) {
        self.fileId = fileId
        self.name = name
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try c.decodeIfPresent(String.self, forKey: .item1) {
            fileId = id
            name = try c.decodeIfPresent(String.self, forKey: .item2)
        } else {
            fileId = try c.decode(String.self, forKey: .plain1)
            name = try c.decodeIfPresent(String.self, forKey: .plain2)
        }
    }
}

public enum WriteError: Error, Equatable, Sendable {
    /// The task's completion mode doesn't let a student set its status.
    case notStudentCompletable
    /// The service refused the change as invalid. Nothing changed.
    case refused
    /// A message needs a thread or at least one recipient.
    case missingTarget
    /// The file area refused an upload.
    case uploadRejected
    /// This session has no transport that can write.
    case unavailable
}

public enum TaskStatus: String, Codable, Sendable {
    case notStarted = "NotStarted"
    case inProgress = "InProgress"
    case completed = "Completed"
}

/// A file uploaded to the personal file area, before it is saved into a folder.
public struct UploadedFileModel: Codable, Sendable, Hashable {
    public var id: String?
    public var name: String?
    public var mimeType: String?
    public var signedFileRepoId: String?
    public var signature: String?
    public var error: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case mimeType = "MimeType"
        case signedFileRepoId = "SignedFileRepoId"
        case signature = "Signature"
        case error = "Error"
    }
}

public struct PersonalFile: Codable, Sendable, Hashable, Identifiable {
    public var fileId: Int
    public var name: String?
    public var fileSizeKB: Int64?
    public var isFolder: Bool?
    public var folderId: Int?
    public var lastModified: Date?

    public var id: Int { fileId }

    enum CodingKeys: String, CodingKey {
        case fileId = "FileId"
        case name = "Name"
        case fileSizeKB = "FileSize"
        case isFolder = "IsFolder"
        case folderId = "FolderId"
        case lastModified = "LastModified"
    }
}

// MARK: - Writer

/// Typed writes for the documented routes. Separate from `ItslearningClient` so a read-only
/// transport can never reach a write.
public struct ItslearningWriter: Sendable {
    let transport: any WriteTransport

    public init(transport: any WriteTransport) {
        self.transport = transport
    }

    // Messages

    /// Sends to an existing thread, or to people, which opens or reuses their thread.
    public func sendMessage(text: String, threadId: Int? = nil, toPersonIds: [Int] = [], attachmentIds: [String] = [], replyingTo messageId: Int64? = nil) async throws -> MessageThread {
        guard threadId != nil || !toPersonIds.isEmpty else { throw WriteError.missingTarget }
        struct Body: Encodable {
            let Text: String
            let InstantMessageThreadId: Int?
            let ToPersonIds: [Int]?
            let FileIds: [String]?
            let InstantMessageIdToReplyTo: Int64?
        }
        let body = Body(
            Text: text, InstantMessageThreadId: threadId,
            ToPersonIds: toPersonIds.isEmpty ? nil : toPersonIds,
            FileIds: attachmentIds.isEmpty ? nil : attachmentIds,
            InstantMessageIdToReplyTo: messageId)
        return try await send(.post, "/restapi/personal/instantmessages/v2", json: body, route: "instantmessages/v2")
    }

    public func uploadMessageAttachment(_ part: UploadPart) async throws -> [MessageAttachment] {
        try await send(WriteRequest(
            method: .post, path: "/restapi/personal/instantmessages/attachment/v1",
            body: .multipart([part]), routeTemplate: "instantmessages/attachment/v1"))
    }

    public func deleteMessage(messageId: Int64) async throws -> InstantMessage {
        try await send(WriteRequest(
            method: .delete, path: "/restapi/personal/instantmessages/\(messageId)/v1",
            routeTemplate: "instantmessages/{id}/v1"))
    }

    /// Flips the star and returns the message with its new state.
    public func toggleMessageStar(messageId: Int64) async throws -> InstantMessage {
        try await send(WriteRequest(
            method: .put, path: "/restapi/personal/instantmessages/togglemessagestar/\(messageId)/v1",
            routeTemplate: "instantmessages/togglemessagestar/{id}/v1"))
    }

    // Assignments and tasks

    public func uploadTempFile(_ part: UploadPart) async throws -> UploadedTempFile {
        try await send(WriteRequest(
            method: .post, path: "/restapi/personal/fileupload/temp/v1",
            body: .multipart([part]), routeTemplate: "fileupload/temp/v1"))
    }

    /// Submits an answer with text and files already uploaded through `uploadTempFile`.
    public func submitAnswer(elementId: Int, text: String?, files: [UploadedTempFile]) async throws -> Int {
        struct Body: Encodable {
            let Text: String?
            let Files: [UploadedTempFile]
        }
        struct Response: Decodable { let AnswerId: Int }
        let response: Response = try await send(
            .post, "/restapi/personal/assignments/\(elementId)/answers/v1",
            json: Body(Text: text, Files: files), route: "assignments/{id}/answers/v1")
        return response.AnswerId
    }

    /// Sets the signed-in person's task status on an assignment or another element with a task.
    public func setTaskStatus(elementId: Int, personId: Int, status: TaskStatus, isAssignment: Bool) async throws {
        struct Body: Encodable {
            let PersonIds: [Int]
            let TaskStatus: TaskStatus
        }
        let path = isAssignment
            ? "/restapi/personal/assignments/\(elementId)/tasks/status/v1"
            : "/restapi/personal/element/embedded/\(elementId)/tasks/status/v1"
        let route = isAssignment ? "assignments/{id}/tasks/status/v1" : "element/embedded/{id}/tasks/status/v1"
        try await sendIgnoringBody(.post, path, json: Body(PersonIds: [personId], TaskStatus: status), route: route)
    }

    // Bulletin comments

    public func postComment(bulletinId: Int, text: String) async throws -> BulletinComment {
        try await send(.post, "/restapi/personal/lightbulletins/\(bulletinId)/comments/v2", json: ["Comment": text], route: "lightbulletins/{id}/comments/v2")
    }

    public func editComment(commentId: Int, text: String) async throws {
        try await sendIgnoringBody(.put, "/restapi/personal/lightbulletins/comments/\(commentId)/v2", json: ["Comment": text], route: "lightbulletins/comments/{id}/v2")
    }

    public func deleteComment(commentId: Int) async throws {
        _ = try await transport.sendWrite(WriteRequest(
            method: .delete, path: "/restapi/personal/lightbulletins/comments/\(commentId)/v1",
            routeTemplate: "lightbulletins/comments/{id}/v1")).validatedWrite()
    }

    // Notifications and courses

    /// The route only processes read = true.
    public func markNotificationsRead(_ ids: [Int]) async throws {
        struct Item: Encodable {
            let NotificationId: Int
            let IsRead: Bool
        }
        try await sendIgnoringBody(.put, "/restapi/personal/notifications/v2", json: ids.map { Item(NotificationId: $0, IsRead: true) }, route: "notifications/v2")
    }

    public func toggleFavorite(courseId: Int) async throws {
        _ = try await transport.sendWrite(WriteRequest(
            method: .put, path: "/restapi/personal/courses/\(courseId)/toggleFavorite/v1",
            routeTemplate: "courses/{id}/toggleFavorite/v1")).validatedWrite()
    }

    // Personal files

    /// Uploads to the personal file area, then saves the uploads into a private folder.
    public func uploadPersonalFile(_ part: UploadPart, folderId: Int) async throws -> [PersonalFile] {
        let uploadedData = try await transport.sendWrite(WriteRequest(
            method: .post, path: "/restapi/personal/yourfiles/files/temp/v1",
            body: .multipart([part]), routeTemplate: "yourfiles/files/temp/v1")).validatedWrite()
        // Documented as a list; the sample shows one object.
        let uploads: [UploadedFileModel]
        if let list = try? ItslearningClient.decode([UploadedFileModel].self, from: uploadedData, route: "yourfiles/files/temp/v1") {
            uploads = list
        } else {
            uploads = [try ItslearningClient.decode(UploadedFileModel.self, from: uploadedData, route: "yourfiles/files/temp/v1")]
        }
        if uploads.contains(where: { !($0.error ?? "").isEmpty }) {
            throw WriteError.uploadRejected
        }
        return try await send(.post, "/restapi/personal/yourfiles/private/folders/\(folderId)/files/v1", json: uploads, route: "yourfiles/private/folders/{id}/files/v1")
    }

    // MARK: - Helpers

    private func send<T: Decodable, B: Encodable>(_ method: WriteMethod, _ path: String, json body: B, route: String) async throws -> T {
        try await send(try jsonRequest(method, path, body, route))
    }

    private func sendIgnoringBody<B: Encodable>(_ method: WriteMethod, _ path: String, json body: B, route: String) async throws {
        _ = try await transport.sendWrite(try jsonRequest(method, path, body, route)).validatedWrite()
    }

    private func jsonRequest<B: Encodable>(_ method: WriteMethod, _ path: String, _ body: B, _ route: String) throws -> WriteRequest {
        WriteRequest(method: method, path: path, body: .json(try JSONEncoder().encode(body)), routeTemplate: route)
    }

    private func send<T: Decodable>(_ request: WriteRequest) async throws -> T {
        let data = try await transport.sendWrite(request).validatedWrite()
        return try ItslearningClient.decode(T.self, from: data, route: request.routeTemplate)
    }
}
