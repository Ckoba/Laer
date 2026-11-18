import Foundation

/// One topic of a course with the plans filed under it. `topicId` is nil for the closing group of
/// plans that have no topic.
public struct PlanTopicGroup: Identifiable, Sendable, Equatable {
    public var id: String
    public var topicId: Int?
    /// The topic's name, or nil for the group of plans without a topic.
    public var name: String?
    /// In date order, earliest first; plans without dates follow in their source order.
    public var plans: [PlanPreview]
    /// True while any plan in the group has not ended yet or has no dates, or the group holds the
    /// plan left out by `excluding`. A group of only past plans is not current.
    public var isCurrent: Bool
    public var containsExcludedPlan: Bool

    public init(id: String, topicId: Int?, name: String?, plans: [PlanPreview], isCurrent: Bool, containsExcludedPlan: Bool = false) {
        self.id = id
        self.topicId = topicId
        self.name = name
        self.plans = plans
        self.isCurrent = isCurrent
        self.containsExcludedPlan = containsExcludedPlan
    }
}

public enum PlanTopics {
    /// The name of a plan's topic, trimmed, or nil when it has none.
    public static func name(of plan: PlanPreview) -> String? {
        guard let name = plan.topic?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name
    }

    /// A plan's topic name for display: the course's topic list wins over the name on the plan.
    public static func displayName(of plan: PlanPreview, topics: [Topic]) -> String? {
        guard let match = match(plan, topics: topics) else { return name(of: plan) }
        return displayName(of: plan, listedUnder: match)
    }

    /// Groups plans by topic. Topics follow the course's topic list; a topic found only on plans
    /// follows them, in the order of its earliest plan. `excluding` leaves one plan out, such as the
    /// card shown above the groups, and a topic left with no plans is dropped. Plans without a topic
    /// close the list. Returns nil when no plan has a topic, so the caller keeps its flat layout.
    public static func groups(_ plans: [PlanPreview], topics: [Topic], excluding: Int? = nil, now: Date) -> [PlanTopicGroup]? {
        guard plans.contains(where: { name(of: $0) != nil || $0.topic?.id != nil }) else { return nil }

        // Key of a plan's topic: the listed topic's id, else the id on the plan, else its name.
        func key(_ plan: PlanPreview) -> (key: String, topicId: Int?, name: String?)? {
            if let listed = match(plan, topics: topics) {
                return ("t\(listed.topicId)", listed.topicId, displayName(of: plan, listedUnder: listed))
            }
            if let id = plan.topic?.id { return ("t\(id)", id, name(of: plan)) }
            if let name = name(of: plan) { return ("n\(name.lowercased())", nil, name) }
            return nil
        }

        var buckets: [String: (topicId: Int?, name: String?, plans: [(plan: PlanPreview, index: Int)])] = [:]
        var firstSeen: [String] = []
        var other: [(plan: PlanPreview, index: Int)] = []
        // The excluded plan's own topic counts as current, so it opens beside the card.
        var holdsExcluded: Set<String> = []
        for (index, plan) in plans.enumerated() {
            if plan.planId == excluding {
                if let found = key(plan) { holdsExcluded.insert(found.key) }
                continue
            }
            if let found = key(plan) {
                if buckets[found.key] == nil {
                    buckets[found.key] = (found.topicId, found.name, [])
                    firstSeen.append(found.key)
                }
                buckets[found.key]?.plans.append((plan, index))
                if buckets[found.key]?.name == nil { buckets[found.key]?.name = found.name }
            } else {
                other.append((plan, index))
            }
        }

        // Listed topics first, in the list's order; then the rest by their earliest plan.
        var seen: Set<String> = []
        let listed = topics.map { "t\($0.topicId)" }.filter { buckets[$0] != nil && seen.insert($0).inserted }
        let unlisted = firstSeen.filter { !seen.contains($0) }.compactMap { id in
            buckets[id].map { (id: id, start: earliest($0.plans)) }
        }.sorted { $0.start < $1.start }
        let order = listed + unlisted.map(\.id)

        var result = order.compactMap { id -> PlanTopicGroup? in
            guard let bucket = buckets[id], !bucket.plans.isEmpty else { return nil }
            let sorted = chronological(bucket.plans)
            let containsExcludedPlan = holdsExcluded.contains(id)
            return PlanTopicGroup(
                id: id, topicId: bucket.topicId, name: bucket.name ?? "Untitled topic",
                plans: sorted, isCurrent: containsExcludedPlan || sorted.contains { !hasEnded($0, now: now) },
                containsExcludedPlan: containsExcludedPlan
            )
        }
        if !other.isEmpty {
            let sorted = chronological(other)
            result.append(PlanTopicGroup(id: "other", topicId: nil, name: nil, plans: sorted, isCurrent: sorted.contains { !hasEnded($0, now: now) }))
        }
        return result
    }

    private static func displayName(of plan: PlanPreview, listedUnder topic: Topic) -> String? {
        topic.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? name(of: plan)
    }

    private static func match(_ plan: PlanPreview, topics: [Topic]) -> Topic? {
        if let id = plan.topic?.id, let found = topics.first(where: { $0.topicId == id }) { return found }
        guard let name = name(of: plan)?.lowercased() else { return nil }
        return topics.first { $0.name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == name }
    }

    private static func hasEnded(_ plan: PlanPreview, now: Date) -> Bool {
        let start = realDate(plan.start)
        let stop = realDate(plan.stop)
        guard let end = stop ?? start else { return false }
        return end < now
    }

    private static func anchor(_ plan: PlanPreview) -> Date? { realDate(plan.start) ?? realDate(plan.stop) }

    private static func earliest(_ plans: [(plan: PlanPreview, index: Int)]) -> Date {
        plans.compactMap { anchor($0.plan) }.min() ?? .distantFuture
    }

    /// Dated plans earliest first, then undated plans in source order.
    private static func chronological(_ plans: [(plan: PlanPreview, index: Int)]) -> [PlanPreview] {
        let dated = plans.filter { anchor($0.plan) != nil }.sorted {
            let lhs = anchor($0.plan)!, rhs = anchor($1.plan)!
            return lhs == rhs ? $0.index < $1.index : lhs < rhs
        }
        return (dated + plans.filter { anchor($0.plan) == nil }).map(\.plan)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
