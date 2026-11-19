import Testing
@testable import LaerCore

@Test func historyMovesBackAndForwardAndANewPlaceEndsForward() {
    var history = NavigationHistory<String>(limit: 50)
    #expect(!history.canGoBack && !history.canGoForward)
    history.push("home")
    history.push("course")
    #expect(history.goBack(from: "folder") == "course")
    #expect(history.goBack(from: "course") == "home")
    #expect(history.goBack(from: "home") == nil)
    #expect(history.goForward(from: "home") == "course")
    #expect(history.canGoForward)
    history.push("course")
    #expect(!history.canGoForward)
    #expect(history.back == ["home", "course"])
}

@Test func historyKeepsOnlyTheNewestEntriesAndResets() {
    var history = NavigationHistory<Int>(limit: 3)
    for place in 1...5 { history.push(place) }
    #expect(history.back == [3, 4, 5])
    _ = history.goBack(from: 6)
    _ = history.goForward(from: 5)
    #expect(history.back == [3, 4, 5])
    history.reset()
    #expect(!history.canGoBack && !history.canGoForward)
}
