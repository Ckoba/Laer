import Foundation
import Testing
@testable import LaerCore

struct FixtureTransport: ReadTransport {
    var handler: @Sendable (ReadRequest) throws -> ReadResponse

    func send(_ request: ReadRequest) async throws -> ReadResponse {
        try handler(request)
    }
}

extension ReadResponse {
    static func json(_ text: String, status: Int = 200) -> ReadResponse {
        ReadResponse(status: status, contentType: "application/json; charset=utf-8", body: Data(text.utf8))
    }
}

@Suite struct ResponseValidationTests {
    @Test func loginPageWithStatus200IsSignedOut() {
        let response = ReadResponse(status: 200, contentType: "text/html", body: Data("<html>".utf8))
        #expect(throws: APIError.signedOut) { try response.validatedJSON() }
    }

    @Test func redirectIsSignedOut() {
        let response = ReadResponse(status: 302, contentType: "text/html", body: Data())
        #expect(throws: APIError.signedOut) { try response.validatedJSON() }
    }

    @Test func throttlingKeepsRetryAfter() {
        let response = ReadResponse(status: 429, contentType: "application/json", retryAfter: 30, body: Data())
        #expect(throws: APIError.throttled(retryAfter: 30)) { try response.validatedJSON() }
    }
}

@Suite struct ClientDecodingTests {
    @Test func emptyCourseListIsValidAndComplete() async throws {
        let client = ItslearningClient(transport: FixtureTransport { _ in
            .json(#"{"EntityArray":[],"Total":0,"CurrentPageIndex":0,"PageSize":100}"#)
        })
        let result = try await client.allCourses()
        #expect(result.items.isEmpty)
        #expect(result.isComplete)
    }

    @Test func invalidEnvelopeIsSchemaErrorNotEmpty() async {
        let client = ItslearningClient(transport: FixtureTransport { _ in .json(#"{"Unexpected":true}"#) })
        await #expect(throws: APIError.self) { try await client.allCourses() }
    }

    @Test func pagingFollowsTotal() async throws {
        let client = ItslearningClient(transport: FixtureTransport { request in
            let index = request.query.first { $0.name == "PageIndex" }?.value ?? "0"
            return .json(#"{"EntityArray":[{"CourseId":\#(index),"Title":"Course \#(index)"}],"Total":2,"CurrentPageIndex":\#(index),"PageSize":1}"#)
        })
        let result = try await client.allCourses()
        #expect(result.items.map(\.courseId) == [0, 1])
        #expect(result.isComplete)
    }

    @Test func laterPageFailureFailsTheWholeRead() async {
        let client = ItslearningClient(transport: FixtureTransport { request in
            let index = request.query.first { $0.name == "PageIndex" }?.value ?? "0"
            if index == "1" { return .json("{}", status: 500) }
            return .json(#"{"EntityArray":[{"CourseId":1,"Title":"A"}],"Total":2,"CurrentPageIndex":0,"PageSize":1}"#)
        })
        await #expect(throws: APIError.server(status: 500)) { try await client.allCourses() }
    }

    @Test func aShortPageWithMoreReportedItemsDoesNotEndTheRead() async throws {
        let client = ItslearningClient(transport: FixtureTransport { request in
            let index = request.query.first { $0.name == "PageIndex" }?.value ?? "0"
            return .json(#"{"EntityArray":[{"CourseId":\#(index),"Title":"Course \#(index)"}],"Total":2,"CurrentPageIndex":\#(index),"PageSize":100}"#)
        })
        let result = try await client.allCourses()
        #expect(result.isComplete)
        #expect(result.items.map(\.courseId) == [0, 1])
    }

    @Test func anEmptyPageBeforeTheReportedTotalIsIncomplete() async throws {
        let client = ItslearningClient(transport: FixtureTransport { _ in
            .json(#"{"EntityArray":[],"Total":2,"CurrentPageIndex":0,"PageSize":100}"#)
        })
        let result = try await client.allCourses()
        #expect(!result.isComplete)
    }

    @Test func safetyCapReportsIncomplete() async throws {
        let client = ItslearningClient(transport: FixtureTransport { _ in
            .json(#"{"EntityArray":[{"CourseId":1,"Title":"A"}],"Total":100000,"CurrentPageIndex":0,"PageSize":1}"#)
        })
        let result = try await client.allCourses()
        #expect(!result.isComplete)
    }

    @Test func resourcesUseNestedEnvelopeAndKeepUnknownTypes() async throws {
        let client = ItslearningClient(transport: FixtureTransport { _ in
            .json(#"{"Resources":{"EntityArray":[{"Title":"Notes","ElementId":5,"ElementType":"SomethingNew"},{"Title":"Week 1","ElementId":5,"ElementType":"Folder"}],"Total":2,"CurrentPageIndex":0,"PageSize":100},"AddElementUrl":""}"#)
        })
        let result = try await client.rootResources(courseId: 1)
        #expect(result.items.count == 2)
        #expect(result.items[0].id != result.items[1].id)
        #expect(result.items[1].isFolder)
        #expect(!result.items[0].isFolder)
    }

    @Test func courseSearchUsesTheDocumentedQueryAndReportsTruncation() async throws {
        let client = ItslearningClient(transport: FixtureTransport { request in
            #expect(request.path == "/restapi/personal/courses/17/resources/search/v1")
            #expect(request.query.map(\.name) == ["locationType", "searchText"])
            #expect(request.query.map(\.value) == ["1", "CO2 & øvelse"])
            return .json(#"{"Resources":{"EntityArray":[{"Title":"Notes","ElementId":5,"ElementType":"Folder"}],"Total":2,"CurrentPageIndex":0,"PageSize":1}}"#)
        })
        let result = try await client.searchResources(courseId: 17, text: "CO2 & øvelse")
        #expect(result.items.map(\.elementId) == [5])
        #expect(!result.isComplete)
    }

    @Test func missingDeadlineStaysMissing() async throws {
        let client = ItslearningClient(transport: FixtureTransport { _ in
            .json(#"{"EntityArray":[{"TaskId":1,"Title":"A","Deadline":null,"LocationId":7},{"TaskId":2,"Title":"B","Deadline":"2030-01-02T03:04:05Z"}],"Total":2,"CurrentPageIndex":0,"PageSize":100}"#)
        })
        let tasks = try await client.tasks().items
        #expect(tasks[0].deadline == nil)
        #expect(tasks[0].courseId == 7)
        #expect(tasks[1].deadline != nil)
    }

    @Test func plansUseCamelCaseEnvelope() async throws {
        let client = ItslearningClient(transport: FixtureTransport { _ in
            .json(#"{"entityArray":[{"id":3,"title":"Week 1","start":"2030-01-02T03:04:05Z","stop":null,"elements":[{"id":9,"title":"Notes","isResource":true}],"topic":{"id":1,"name":"Intro"}}],"total":1,"currentPageIndex":0,"pageSize":100}"#)
        })
        let plans = try await client.plans(courseId: 1)
        #expect(plans.isComplete)
        #expect(plans.items[0].planId == 3)
        #expect(plans.items[0].stop == nil)
        #expect(plans.items[0].elements?.first?.id == 9)
        #expect(plans.items[0].topic?.id == 1)
        #expect(plans.items[0].topic?.name == "Intro")
    }
}

@Suite struct DateParsingTests {
    @Test(arguments: ["2030-01-02T03:04:05Z", "2030-01-02T03:04:05.123Z", "2030-01-02T03:04:05"])
    func acceptsObservedForms(_ text: String) {
        #expect(APIDate.parse(text) != nil)
    }

    @Test func rejectsPlainText() {
        #expect(APIDate.parse("tomorrow") == nil)
    }
}

@Suite struct ShapeReportTests {
    @Test func keepsStructureAndDropsValues() throws {
        let json = #"{"Name":"Private Person","Id":42,"ElementType":"Folder","When":"2030-01-02T03:04:05Z","Link":"https://example.itslearning.com/secret","Items":[{"A":"hidden"},{"B":true}]}"#
        let report = try #require(ShapeReport.describe(json: Data(json.utf8)))
        #expect(!report.contains("Private"))
        #expect(!report.contains("42"))
        #expect(!report.contains("secret"))
        #expect(!report.contains("hidden"))
        #expect(report.contains("enum:Folder"))
        #expect(report.contains("When: date"))
        #expect(report.contains("Link: absolute-url"))
    }
}

@Suite struct CookieScopeTests {
    private func cookie(_ domain: String) -> HTTPCookie {
        HTTPCookie(properties: [.domain: domain, .path: "/", .name: "a", .value: "b", .secure: "TRUE"])!
    }

    @Test func excludesIdentityProviderCookies() {
        let cookies = [cookie("example.itslearning.com"), cookie(".itslearning.com"), cookie("login.example.net"), cookie("other.itslearning.com")]
        let kept = CookieScope.filter(cookies, forHosts: ["example.itslearning.com"])
        #expect(kept.map(\.domain) == ["example.itslearning.com", ".itslearning.com"])
    }
}

@Suite struct PlainTextTests {
    @Test func stripsMarkup() {
        #expect(PlainText.from("<p>One &amp; two</p><p>Three</p>") == "One & two\nThree")
    }
}

@Suite struct SiteSearchTests {
    private static func site(_ short: String, _ title: String, id: Int) -> Site {
        Site(shortName: short, title: title, baseURL: URL(string: "https://\(short).itslearning.com")!, customerId: id)
    }

    private let sites = [
        site("northcollege", "North College of Engineering", id: 1),
        site("eastuni", "Østby University", id: 2),
        site("west", "University of Westvale", id: 3),
        site("uni", "Unified Schools", id: 4),
    ]

    @Test func matchesNameIgnoringCaseAndAccents() {
        #expect(SiteDirectory.search("ostby", in: sites).map(\.customerId) == [2])
    }

    @Test func everyWordMustMatch() {
        #expect(SiteDirectory.search("university westvale", in: sites).map(\.customerId) == [3])
    }

    @Test func exactShortNameRanksFirstThenPrefixes() {
        #expect(SiteDirectory.search("uni", in: sites).map(\.customerId) == [4, 3, 2])
    }

    @Test func emptyQueryHasNoSuggestions() {
        #expect(SiteDirectory.search("  ", in: sites).isEmpty)
    }

    @Test(arguments: ["https://school.itslearning.com", "http://school.itslearning.com", "https://itslearning.com.example.org", "https://example.org"])
    func onlyHttpsItslearningHostsAreKept(_ address: String) {
        let site = Site(shortName: "x", title: "X", baseURL: URL(string: address)!, customerId: 1)
        #expect(SiteDirectory.isItslearningHost(site) == (address == "https://school.itslearning.com"))
    }

    @Test func listDecodesFromEnvelope() throws {
        let json = #"{"EntityArray":[{"CustomerId":7,"Title":"Example School","ShortName":"example","BaseUrl":"https://example.itslearning.com","CountryCode":"XX"}]}"#
        let page = try ItslearningClient.decode(Page<Site>.self, from: Data(json.utf8), route: "sites/all/v1")
        #expect(page.items.map(\.shortName) == ["example"])
    }
}
