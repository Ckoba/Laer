import Foundation

/// Browser-style back and forward lists. The current place is held by the caller, so a move
/// hands it in and gets the place to show back.
public struct NavigationHistory<Entry> {
    public private(set) var back: [Entry] = []
    public private(set) var forward: [Entry] = []
    public let limit: Int

    public init(limit: Int = 50) {
        self.limit = max(limit, 1)
    }

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    /// Leaving `entry` for somewhere new. The oldest entries fall off past the limit, and a new
    /// place ends the forward list, as in a browser.
    public mutating func push(_ entry: Entry) {
        back.append(entry)
        if back.count > limit { back.removeFirst(back.count - limit) }
        forward.removeAll()
    }

    /// The place before `current`, which moves onto the forward list. Nil when there is none.
    public mutating func goBack(from current: Entry) -> Entry? {
        guard let target = back.popLast() else { return nil }
        forward.append(current)
        return target
    }

    /// The place after `current`, which moves onto the back list. Nil when there is none.
    public mutating func goForward(from current: Entry) -> Entry? {
        guard let target = forward.popLast() else { return nil }
        back.append(current)
        if back.count > limit { back.removeFirst(back.count - limit) }
        return target
    }

    /// Changes every saved entry in place, such as forgetting search results that no longer exist.
    public mutating func update(_ transform: (inout Entry) -> Void) {
        for index in back.indices { transform(&back[index]) }
        for index in forward.indices { transform(&forward[index]) }
    }

    public mutating func reset() {
        back.removeAll()
        forward.removeAll()
    }
}
