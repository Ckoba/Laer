import Foundation
import Testing
@testable import LaerCore

/// Synthetic JSON only. A missing or empty picture field is not an error.
@Suite struct ProfileImageTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test func personCarriesItsPictureWhenPresent() throws {
        let person = try decode(ParityPerson.self, #"""
            {"PersonId": 7, "FullName": "Sam Teacher", "ProfileUrl": "/p/7",
             "ProfileImageUrl": "https://example.itslearning.com/img/7.png", "ProfileImageUrlSmall": "https://example.itslearning.com/img/7s.png"}
            """#)
        #expect(person.profileImageUrl == "https://example.itslearning.com/img/7.png")
        #expect(person.imageURLString == "https://example.itslearning.com/img/7.png")
    }

    @Test func personWithoutPictureDecodesWithNil() throws {
        let absent = try decode(ParityPerson.self, #"{"PersonId": 7, "FullName": "Sam Teacher"}"#)
        #expect(absent.profileImageUrl == nil)
        #expect(absent.imageURLString == nil)
        let null = try decode(ParityPerson.self, #"{"PersonId": 7, "ProfileImageUrl": null}"#)
        #expect(null.imageURLString == nil)
        let blank = try decode(ParityPerson.self, #"{"PersonId": 7, "ProfileImageUrl": "  ", "ProfileImageUrlSmall": "/img/small.png"}"#)
        #expect(blank.imageURLString == "/img/small.png")
    }

    @Test func existingInitsStaySourceCompatible() {
        #expect(ParityPerson(personId: 1, fullName: "A B").profileImageUrl == nil)
        #expect(Person(personId: 1).profileImageUrl == nil)
        #expect(Person(personId: 1, fullName: "A B", timeZoneId: "UTC").profileImageUrl == nil)
    }

    @Test func currentPersonAndCourseUpdateAuthorDecode() throws {
        let me = try decode(Person.self, #"{"PersonId": 1, "FullName": "Alex Example", "ProfileImageUrl": "/img/1.png"}"#)
        #expect(me.profileImageUrl == "/img/1.png")
        let update = try decode(CourseUpdate.self, #"""
            {"NotificationId": 5, "PublishedBy": {"FullName": "Sam Teacher", "ProfileImageUrlSmall": "/img/2s.png"}}
            """#)
        #expect(update.publishedBy?.imageURLString == "/img/2s.png")
        let bare = try decode(CourseUpdate.self, #"{"NotificationId": 6, "PublishedBy": {"FullName": "Sam Teacher"}}"#)
        #expect(bare.publishedBy?.imageURLString == nil)
    }

    @Test func notificationAndBulletinAuthorsDecode() throws {
        let note = try decode(ParityNotification.self, #"""
            {"NotificationId": 1, "PublishedBy": {"PersonId": 3, "FullName": "Robin Example", "ProfileImageUrl": "/img/3.png"}}
            """#)
        #expect(note.publishedBy?.imageURLString == "/img/3.png")
        let comment = try decode(BulletinComment.self, #"{"Id": 9, "Author": {"PersonId": 3, "FullName": "Robin Example"}}"#)
        #expect(comment.author?.imageURLString == nil)
    }

    @Test func messageSenderPictureComesFromItsOwnFieldOrTheThreadsParticipants() throws {
        let thread = try decode(MessageThread.self, #"""
            {"InstantMessageThreadId": 300,
             "Participants": [
               {"PersonId": 2, "FullName": "Sam Teacher", "ProfileImageUrl": "/img/2.png"},
               {"PersonId": 1001, "FullName": "Alex Example"}]}
            """#)
        let byId = try decode(InstantMessage.self, #"{"MessageId": 1, "CreatedBy": 2, "CreatedByName": "Sam Teacher"}"#)
        #expect(thread.senderImageURLString(for: byId) == "/img/2.png")
        let byName = try decode(InstantMessage.self, #"{"MessageId": 2, "CreatedByName": "Sam Teacher"}"#)
        #expect(thread.senderImageURLString(for: byName) == "/img/2.png")
        let noPicture = try decode(InstantMessage.self, #"{"MessageId": 3, "CreatedBy": 1001, "CreatedByName": "Alex Example"}"#)
        #expect(thread.senderImageURLString(for: noPicture) == nil)
        let own = try decode(InstantMessage.self, #"{"MessageId": 4, "CreatedBy": 1001, "CreatedByAvatar": "/img/own.png"}"#)
        #expect(thread.senderImageURLString(for: own) == "/img/own.png")
        let stranger = try decode(InstantMessage.self, #"{"MessageId": 5, "CreatedBy": 99}"#)
        #expect(thread.senderImageURLString(for: stranger) == nil)
    }
}
