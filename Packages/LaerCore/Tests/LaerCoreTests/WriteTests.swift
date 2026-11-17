import Foundation
import Testing
@testable import LaerCore

/// Records writes and answers each route with a canned response. Never touches a network.
final class RecordingWriteTransport: WriteTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [WriteRequest] = []
    let answers: [String: ReadResponse]

    init(_ answers: [String: ReadResponse]) {
        self.answers = answers
    }

    var writes: [WriteRequest] { lock.withLock { recorded } }

    func send(_ request: ReadRequest) async throws -> ReadResponse {
        Issue.record("A write test made a read")
        return ReadResponse(status: 404, contentType: "application/json", body: Data())
    }

    func sendWrite(_ request: WriteRequest) async throws -> ReadResponse {
        lock.withLock { recorded.append(request) }
        return answers[request.routeTemplate] ?? ReadResponse(status: 404, contentType: "application/json", body: Data())
    }
}

private func jsonObject(_ request: WriteRequest?) throws -> Any {
    guard case .json(let data)? = request?.body else { throw APIError.notJSON }
    return try JSONSerialization.jsonObject(with: data)
}

private let emptyOK = ReadResponse(status: 200, contentType: "application/json", body: Data())

@Suite struct WriteTests {
    let thread = #"{"InstantMessageThreadId": 300, "LastMessage": {"MessageId": 13, "Text": "Hi"}}"#

    @Test func replyPostsToThreadWithAttachments() async throws {
        let transport = RecordingWriteTransport(["instantmessages/v2": .json(thread)])
        let result = try await ItslearningWriter(transport: transport)
            .sendMessage(text: "Hi", threadId: 300, attachmentIds: ["guid-1"])
        #expect(result.threadId == 300)
        let write = try #require(transport.writes.first)
        #expect(write.method == .post)
        #expect(write.path == "/restapi/personal/instantmessages/v2")
        let body = try #require(try jsonObject(write) as? [String: Any])
        #expect(body["Text"] as? String == "Hi")
        #expect(body["InstantMessageThreadId"] as? Int == 300)
        #expect(body["FileIds"] as? [String] == ["guid-1"])
        #expect(body["ToPersonIds"] == nil)
    }

    @Test func messageWithoutTargetIsRefusedBeforeSending() async throws {
        let transport = RecordingWriteTransport([:])
        await #expect(throws: WriteError.missingTarget) {
            try await ItslearningWriter(transport: transport).sendMessage(text: "Hi")
        }
        #expect(transport.writes.isEmpty)
    }

    @Test func failedWriteIsNotRetried() async throws {
        let transport = RecordingWriteTransport(["instantmessages/v2": ReadResponse(status: 503, contentType: "text/plain", body: Data())])
        await #expect(throws: APIError.server(status: 503)) {
            try await ItslearningWriter(transport: transport).sendMessage(text: "Hi", threadId: 1)
        }
        #expect(transport.writes.count == 1)
    }

    @Test func loginPageAnswerIsSignedOut() async throws {
        let transport = RecordingWriteTransport(["notifications/v2": ReadResponse(status: 200, contentType: "text/html", body: Data("<html>".utf8))])
        await #expect(throws: APIError.signedOut) {
            try await ItslearningWriter(transport: transport).markNotificationsRead([1])
        }
    }

    @Test func markReadSendsOnlyReadTrue() async throws {
        let transport = RecordingWriteTransport(["notifications/v2": emptyOK])
        try await ItslearningWriter(transport: transport).markNotificationsRead([4, 5])
        let write = try #require(transport.writes.first)
        #expect(write.method == .put)
        let body = try #require(try jsonObject(write) as? [[String: Any]])
        #expect(body.map { $0["NotificationId"] as? Int } == [4, 5])
        #expect(body.allSatisfy { $0["IsRead"] as? Bool == true })
    }

    @Test func attachmentUploadIsMultipartAndDecodesTuples() async throws {
        let transport = RecordingWriteTransport(["instantmessages/attachment/v1": .json(#"[{"m_Item1": "guid-1", "m_Item2": "notes.pdf"}]"#)])
        let part = UploadPart(fileName: "notes \"final\".pdf", contentType: "application/pdf", data: Data("%PDF".utf8))
        let attachments = try await ItslearningWriter(transport: transport).uploadMessageAttachment(part)
        #expect(attachments == [MessageAttachment(fileId: "guid-1", name: "notes.pdf")])

        let encoded = try #require(transport.writes.first?.encodedBody(boundary: "B"))
        #expect(encoded.contentType == "multipart/form-data; boundary=B")
        let text = String(decoding: encoded.data, as: UTF8.self)
        #expect(text.hasPrefix("--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"notes 'final'.pdf\"\r\n"))
        #expect(text.contains("Content-Type: application/pdf\r\n\r\n%PDF\r\n"))
        #expect(text.hasSuffix("--B--\r\n"))
    }

    @Test func deleteAndStarUseDocumentedRoutes() async throws {
        let message = #"{"MessageId": 12, "IsDeleted": true, "IsStarred": true}"#
        let transport = RecordingWriteTransport([
            "instantmessages/{id}/v1": .json(message),
            "instantmessages/togglemessagestar/{id}/v1": .json(message),
        ])
        let writer = ItslearningWriter(transport: transport)
        #expect(try await writer.deleteMessage(messageId: 12).isDeleted == true)
        #expect(try await writer.toggleMessageStar(messageId: 12).isStarred == true)
        #expect(transport.writes.map(\.method) == [.delete, .put])
        #expect(transport.writes.map(\.path) == [
            "/restapi/personal/instantmessages/12/v1",
            "/restapi/personal/instantmessages/togglemessagestar/12/v1",
        ])
    }

    @Test func submitAnswerSendsUploadedFiles() async throws {
        let transport = RecordingWriteTransport([
            "fileupload/temp/v1": .json(#"{"FileRepoId": "repo-1", "SignedFileRepoId": "signed-1", "Name": "essay.pdf", "MimeType": "application/pdf", "SourceType": "Dropbox"}"#),
            "assignments/{id}/answers/v1": .json(#"{"AnswerId": 55}"#),
        ])
        let writer = ItslearningWriter(transport: transport)
        let file = try await writer.uploadTempFile(UploadPart(fileName: "essay.pdf", contentType: "application/pdf", data: Data("%PDF".utf8)))
        #expect(file.fileRepoId == "repo-1")
        #expect(file.sourceType == nil)
        let answerId = try await writer.submitAnswer(elementId: 70, text: "<p>Done</p>", files: [file])
        #expect(answerId == 55)
        let body = try #require(try jsonObject(transport.writes.last) as? [String: Any])
        let files = try #require(body["Files"] as? [[String: Any]])
        #expect(files.first?["FileRepoId"] as? String == "repo-1")
        #expect(body["Text"] as? String == "<p>Done</p>")
    }

    @Test func taskStatusPathDependsOnElementKind() async throws {
        let transport = RecordingWriteTransport([
            "assignments/{id}/tasks/status/v1": emptyOK,
            "element/embedded/{id}/tasks/status/v1": emptyOK,
        ])
        let writer = ItslearningWriter(transport: transport)
        try await writer.setTaskStatus(elementId: 70, personId: 1001, status: .completed, isAssignment: true)
        try await writer.setTaskStatus(elementId: 71, personId: 1001, status: .completed, isAssignment: false)
        #expect(transport.writes.map(\.path) == [
            "/restapi/personal/assignments/70/tasks/status/v1",
            "/restapi/personal/element/embedded/71/tasks/status/v1",
        ])
        let body = try #require(try jsonObject(transport.writes.first) as? [String: Any])
        #expect(body["TaskStatus"] as? String == "Completed")
        #expect(body["PersonIds"] as? [Int] == [1001])
    }

    @Test func commentsPostEditDelete() async throws {
        let transport = RecordingWriteTransport([
            "lightbulletins/{id}/comments/v2": .json(#"{"Id": 9, "CommentText": "Thanks", "AllowEditComment": true, "Author": {"FullName": "Alex Example"}}"#),
            "lightbulletins/comments/{id}/v2": emptyOK,
            "lightbulletins/comments/{id}/v1": emptyOK,
        ])
        let writer = ItslearningWriter(transport: transport)
        let comment = try await writer.postComment(bulletinId: 5, text: "Thanks")
        #expect(comment.commentId == 9)
        try await writer.editComment(commentId: 9, text: "Thanks again")
        try await writer.deleteComment(commentId: 9)
        #expect(transport.writes.map(\.method) == [.post, .put, .delete])
        let edit = try #require(try jsonObject(transport.writes[1]) as? [String: String])
        #expect(edit == ["Comment": "Thanks again"])
    }

    @Test func favoriteToggleHasNoBody() async throws {
        let transport = RecordingWriteTransport(["courses/{id}/toggleFavorite/v1": emptyOK])
        try await ItslearningWriter(transport: transport).toggleFavorite(courseId: 11)
        #expect(transport.writes.first?.body == WriteBody.none)
        #expect(transport.writes.first?.encodedBody() == nil)
    }

    @Test func personalUploadSavesIntoFolder() async throws {
        let transport = RecordingWriteTransport([
            "yourfiles/files/temp/v1": .json(#"{"Id": "u1", "Name": "cv.pdf", "MimeType": "application/pdf", "SignedFileRepoId": "s1", "Signature": "sig"}"#),
            "yourfiles/private/folders/{id}/files/v1": .json(#"[{"FileId": 6, "Name": "cv.pdf", "FileSize": 12, "FolderId": 3}]"#),
        ])
        let saved = try await ItslearningWriter(transport: transport)
            .uploadPersonalFile(UploadPart(fileName: "cv.pdf", contentType: "application/pdf", data: Data("%PDF".utf8)), folderId: 3)
        #expect(saved.first?.fileId == 6)
        let body = try #require(try jsonObject(transport.writes.last) as? [[String: Any]])
        #expect(body.first?["Id"] as? String == "u1")
    }

    @Test func rejectedPersonalUploadStopsBeforeSaving() async throws {
        let transport = RecordingWriteTransport([
            "yourfiles/files/temp/v1": .json(#"[{"Id": "u1", "Error": "Too large"}]"#),
        ])
        await #expect(throws: WriteError.uploadRejected) {
            try await ItslearningWriter(transport: transport)
                .uploadPersonalFile(UploadPart(fileName: "big.bin", contentType: "application/octet-stream", data: Data([1])), folderId: 3)
        }
        #expect(transport.writes.count == 1)
    }
}

@Suite struct WriteRefusalTests {
    @Test func completionModeRefusalIsDistinct() {
        let response = ReadResponse(status: 400, contentType: "text/plain", body: Data("Can't set task status, student can only set task status when completion mode is ManualByStudent.".utf8))
        #expect(throws: WriteError.notStudentCompletable) { try response.validatedWrite() }
    }

    @Test func otherBadRequestIsRefused() {
        let response = ReadResponse(status: 400, contentType: "text/plain", body: Data("Invalid".utf8))
        #expect(throws: WriteError.refused) { try response.validatedWrite() }
    }
}
