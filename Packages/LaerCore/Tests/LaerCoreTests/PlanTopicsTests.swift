import Foundation
import Testing
@testable import LaerCore

private func date(_ text: String) -> Date { APIDate.parse(text)! }

private func plan(_ id: Int, start: String?, stop: String?, topic: (id: Int?, name: String?)? = nil) -> PlanPreview {
    var parts = ["\"id\":\(id)", "\"title\":\"Plan \(id)\""]
    parts.append(start.map { "\"start\":\"\($0)\"" } ?? "\"start\":null")
    parts.append(stop.map { "\"stop\":\"\($0)\"" } ?? "\"stop\":null")
    if let topic {
        var fields: [String] = []
        if let id = topic.id { fields.append("\"id\":\(id)") }
        if let name = topic.name { fields.append("\"name\":\"\(name)\"") }
        parts.append("\"topic\":{\(fields.joined(separator: ","))}")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = APIDate.decoding
    return try! decoder.decode(PlanPreview.self, from: Data("{\(parts.joined(separator: ","))}".utf8))
}

private func topic(_ id: Int, _ name: String) -> Topic {
    try! JSONDecoder().decode(Topic.self, from: Data(#"{"TopicId": \#(id), "TopicName": "\#(name)", "FolderId": 700}"#.utf8))
}

@Suite struct PlanTopicsTests {
    let now = date("2030-03-10T12:00:00Z")

    @Test func planAndTopicListDecode() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = APIDate.decoding
        let plan = try decoder.decode(PlanPreview.self, from: Data(#"{"id": 3, "title": "Week 1", "topic": {"id": 7, "name": "Unit one"}}"#.utf8))
        #expect(plan.topic?.id == 7)
        #expect(plan.topic?.name == "Unit one")
        let none = try decoder.decode(PlanPreview.self, from: Data(#"{"id": 4, "title": "Week 2"}"#.utf8))
        #expect(none.topic == nil)
        let listed = topic(7, "Unit one")
        #expect(listed.topicId == 7 && listed.name == "Unit one" && listed.folderId == 700)
    }

    @Test func noTopicsMeansNoGroups() {
        let plans = [plan(1, start: "2030-03-01T00:00:00Z", stop: "2030-03-07T00:00:00Z"), plan(2, start: "2030-03-11T00:00:00Z", stop: nil)]
        #expect(PlanTopics.groups(plans, topics: [], now: now) == nil)
        #expect(PlanTopics.groups(plans, topics: [topic(1, "Unit one")], now: now) == nil)
    }

    @Test func groupsFollowTheTopicListAndExcludeTheCardPlan() throws {
        let plans = [
            plan(1, start: "2030-02-01T00:00:00Z", stop: "2030-02-07T00:00:00Z", topic: (10, "Old name")),
            plan(2, start: "2030-03-09T00:00:00Z", stop: "2030-03-15T00:00:00Z", topic: (20, nil)),
            plan(3, start: "2030-03-16T00:00:00Z", stop: "2030-03-22T00:00:00Z", topic: (20, nil)),
            plan(4, start: "2030-02-08T00:00:00Z", stop: "2030-02-14T00:00:00Z", topic: (10, nil)),
            plan(5, start: nil, stop: nil),
        ]
        // The list puts topic 20 before topic 10 and names both.
        let topics = [topic(20, "Ecology"), topic(10, "Cell biology")]
        let groups = try #require(PlanTopics.groups(plans, topics: topics, excluding: 2, now: now))
        #expect(groups.map(\.name) == ["Ecology", "Cell biology", nil])
        #expect(groups[0].plans.map(\.planId) == [3])
        #expect(groups[1].plans.map(\.planId) == [1, 4])
        #expect(groups[2].plans.map(\.planId) == [5])
        #expect(groups.map(\.isCurrent) == [true, false, true])
        #expect(groups.map(\.containsExcludedPlan) == [true, false, false])

        let sameName = try #require(PlanTopics.groups(
            plans, topics: [topic(20, "Unit"), topic(10, "Unit")], excluding: 2, now: now
        ))
        #expect(sameName.map(\.containsExcludedPlan) == [true, false, false])
        #expect(groups[2].id == "other" && groups[2].topicId == nil)
    }

    @Test func theCardPlansTopicOpensEvenWhenTheRestOfItIsPast() throws {
        let plans = [
            plan(1, start: "2030-02-01T00:00:00Z", stop: "2030-02-07T00:00:00Z", topic: (10, "Unit one")),
            plan(2, start: "2030-03-09T00:00:00Z", stop: "2030-03-15T00:00:00Z", topic: (10, "Unit one")),
            plan(3, start: "2030-01-01T00:00:00Z", stop: "2030-01-07T00:00:00Z", topic: (11, "Unit zero")),
        ]
        let groups = try #require(PlanTopics.groups(plans, topics: [], excluding: 2, now: now))
        #expect(groups.map(\.name) == ["Unit zero", "Unit one"])
        #expect(groups.map(\.isCurrent) == [false, true])
        // Left out entirely, a topic with only the card plan has no group.
        let alone = try #require(PlanTopics.groups(plans, topics: [], excluding: 3, now: now))
        #expect(alone.map(\.name) == ["Unit one"])
    }

    @Test func topicsOnlyOnPlansFollowInDateOrderAndEmptyTopicsAreDropped() throws {
        let plans = [
            plan(1, start: "2030-04-01T00:00:00Z", stop: nil, topic: (2, "Later unit")),
            plan(2, start: "2030-01-01T00:00:00Z", stop: nil, topic: (3, "Earlier unit")),
            plan(3, start: "2030-03-12T00:00:00Z", stop: nil, topic: (1, "Listed")),
        ]
        let groups = try #require(PlanTopics.groups(plans, topics: [topic(1, "Listed"), topic(9, "Empty")], now: now))
        #expect(groups.map(\.name) == ["Listed", "Earlier unit", "Later unit"])
    }

    @Test func aPlanFindsItsTopicByNameWhenTheIdDiffers() throws {
        let plans = [plan(1, start: nil, stop: nil, topic: (nil, "unit one")), plan(2, start: nil, stop: nil, topic: (99, "Unit one"))]
        let groups = try #require(PlanTopics.groups(plans, topics: [topic(5, "Unit one")], now: now))
        #expect(groups.count == 1)
        #expect(groups[0].name == "Unit one")
        #expect(groups[0].plans.count == 2)
        #expect(PlanTopics.displayName(of: plans[0], topics: [topic(5, "Unit one")]) == "Unit one")
        #expect(PlanTopics.displayName(of: plans[0], topics: []) == "unit one")
    }
}
