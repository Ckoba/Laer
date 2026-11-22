#if DEBUG
import Foundation
import LaerCore
import OSLog
import PDFKit
import WebKit

/// Debug-only feasibility checks. The report holds route templates, statuses, key names and
/// value types. It never holds values from the account, so it is safe to read while developing.
/// It still describes a real account, and git ignores it.
@MainActor
final class RouteProbe {
    struct Entry: Codable {
        var gate: String
        var check: String
        var transport: String?
        var outcome: String
        var detail: String?
    }

    private let session: WebSession
    private let log = Logger(subsystem: "app.laer.Laer", category: "probe")
    private var entries: [Entry] = []
    private var shapes: [String: String] = [:]
    private var counts: [String: Int] = [:]

    init(session: WebSession) {
        self.session = session
    }

    /// Records the shape of every route it passes, without keeping the data.
    private final class Recording: ReadTransport, @unchecked Sendable {
        let base: any ReadTransport
        let label: String
        let record: @MainActor (String, ReadResponse) -> Void

        init(base: any ReadTransport, label: String, record: @escaping @MainActor (String, ReadResponse) -> Void) {
            self.base = base
            self.label = label
            self.record = record
        }

        func send(_ request: ReadRequest) async throws -> ReadResponse {
            let response = try await base.send(request)
            await record("\(label) \(request.routeTemplate)", response)
            return response
        }
    }

    private func add(_ gate: String, _ check: String, transport: String? = nil, outcome: String, detail: String? = nil) {
        entries.append(Entry(gate: gate, check: check, transport: transport, outcome: outcome, detail: detail))
        log.info("\(gate, privacy: .public) \(check, privacy: .public) \(outcome, privacy: .public)")
    }

    private func category(_ error: Error) -> String {
        if let error = error as? APIError { return String(describing: error) }
        return "other: \(type(of: error))"
    }

    private func recordShape(_ key: String, _ response: ReadResponse) {
        let mime = response.contentType.split(separator: ";").first.map(String.init) ?? "none"
        let header = "status \(response.status), \(mime), \(response.body.count) bytes"
        guard shapes[key] == nil else { return }
        shapes[key] = header + "\n" + (ShapeReport.describe(json: response.body) ?? "(not JSON)")
    }

    private func wrap(_ base: any ReadTransport, _ label: String) -> ItslearningClient {
        ItslearningClient(transport: Recording(base: base, label: label) { [weak self] key, response in
            self?.recordShape(key, response)
        })
    }

    private func check<T>(_ gate: String, _ name: String, transport: String, _ body: () async throws -> T) async -> T? {
        do {
            let value = try await body()
            add(gate, name, transport: transport, outcome: "pass")
            return value
        } catch {
            add(gate, name, transport: transport, outcome: "fail", detail: category(error))
            return nil
        }
    }

    /// Viewer and identity checks on an untouched session, with no native reads before them.
    func run() async {
        add("F6", "session restored from vault", outcome: UserDefaults.standard.bool(forKey: "LaerVaultRestored") ? "yes" : "no")
        let web = wrap(WebKitTransport(session: session), "webkit")
        let courses = (try? await web.allCourses().items) ?? []
        add("F6", "courses after relaunch", outcome: "\(courses.count)")
        let cookies = await session.allCookies()
        for name in ["DebugPersonId", "DebugCustomerId", "login", "CUI"] {
            if let cookie = cookies.first(where: { $0.name == name }) {
                let digits = cookie.value.allSatisfy(\.isNumber)
                add("S", "cookie \(name)", outcome: "digits \(digits), length \(cookie.value.count), session \(cookie.isSessionOnly)")
            }
        }
        await checkIdentityInPages()
        await write()
        var candidates: [Resource] = []
        for course in courses.prefix(8) {
            candidates += await surveyOne(client: web, course: course)
        }
        await checkFiles(candidates: candidates)
        await write()
        add("S", "finished", outcome: "yes")
        await write()
    }

    private func surveyOne(client: ItslearningClient, course: Course) async -> [Resource] {
        var found: [Resource] = []
        var queue: [Int?] = [nil]
        var budget = 6
        while let folder = queue.popLast(), budget > 0 {
            budget -= 1
            let listing: PagedResult<Resource>? = if let folder {
                try? await client.folderResources(courseId: course.courseId, folderId: folder)
            } else {
                try? await client.rootResources(courseId: course.courseId)
            }
            for resource in listing?.items ?? [] {
                if resource.isFolder { queue.append(resource.elementId) } else { found.append(resource) }
            }
        }
        return found
    }

    /// Everything the token can reach, plus refresh and the signed-in link route to file viewers.
    func runOAuth(transport: BearerTransport, box: TokenBox, recovery: SessionRecovery) async {
        add("O", "route", outcome: "oauth")
        let client = wrap(transport, "oauth")
        let reads = await readCore(client: client, transport: "oauth")
        add("O", "identity", outcome: reads.person != nil ? "pass" : "fail")
        await write()
        let accepted = await surveyRoutes(courseId: reads.courseIds.first ?? 0, candidates: [], transportUnderTest: transport)
        add("O", "routes accepted", outcome: "\(accepted)")
        await write()
        do {
            let before = await box.tokens.accessToken
            let renewed = try await OAuthTokenClient(baseURL: session.site.baseURL).refresh(await box.tokens.refreshToken)
            await box.update(renewed)
            TokenVault(site: session.site).save(renewed)
            add("O", "refresh", outcome: renewed.accessToken != before ? "new token" : "same token", detail: "lasts \(Int(renewed.expiresAt.timeIntervalSinceNow))s")
            add("O", "after refresh", outcome: (try? await client.allCourses()) != nil ? "pass" : "fail")
        } catch {
            add("O", "refresh", outcome: "fail", detail: category(error))
        }
        await write()
        var candidates: [Resource] = []
        for course in reads.courses.prefix(8) {
            candidates += await surveyOne(client: client, course: course)
        }
        let byTool = Dictionary(grouping: candidates) { $0.learningToolId ?? -1 }
        add("F4", "learning tools", outcome: byTool.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.count)" }.joined(separator: ", "))
        for (tool, resources) in byTool.sorted(by: { $0.value.count > $1.value.count }).prefix(4) {
            guard let resource = resources.randomElement() else { continue }
            var components = URLComponents(url: session.site.baseURL, resolvingAgainstBaseURL: false)!
            components.path = "/LearningToolElement/ViewLearningToolElement.aspx"
            components.queryItems = [URLQueryItem(name: "LearningToolElementId", value: String(resource.elementId))]
            do {
                let link = try await client.ssoURL(for: components.url!)
                var linked = resource
                linked.url = link.absoluteString
                add("F4", "tool \(tool) signed-in link", outcome: "pass")
                await traceViewer(linked, label: "tool \(tool)")
            } catch {
                add("F4", "tool \(tool) signed-in link", outcome: "fail", detail: category(error))
            }
            await write()
        }
        add("S", "finished", outcome: "yes")
        await write()
    }

    /// Acquires real files end to end and records only their type and size. The bytes are discarded.
    func runFiles(transport: BearerTransport) async {
        add("O", "tokens restored after relaunch", outcome: "pass")
        let client = ItslearningClient(transport: transport)
        let courses = (try? await client.allCourses().items) ?? []
        var candidates: [Resource] = []
        for course in courses.shuffled().prefix(10) {
            candidates += await surveyOne(client: client, course: course)
        }
        let files = candidates.filter { $0.learningToolId == 5009 }.shuffled().prefix(14)
        add("F4", "file samples", outcome: "\(files.count)")
        await write()
        for (index, resource) in files.enumerated() {
            let acquirer = FileAcquirer(session: session, client: client)
            do {
                let staged = try await acquirer.acquire(resource)
                let handle = try FileHandle(forReadingFrom: staged.file)
                let head = [UInt8](handle.readData(ofLength: 8))
                try handle.close()
                let size = (try? FileManager.default.attributesOfItem(atPath: staged.file.path)[.size] as? Int) ?? -1
                let ext = (staged.suggestedName as NSString?)?.pathExtension.lowercased() ?? "?"
                let mime = staged.contentType?.split(separator: ";").first.map(String.init) ?? "none"
                add("F4", "sample \(index) acquired", outcome: "pass", detail: "\(magic(head)), \(mime), .\(ext), \(size) bytes")
                try? FileManager.default.removeItem(at: staged.file)
            } catch {
                add("F4", "sample \(index) acquired", outcome: "fail", detail: "\(type(of: error))")
            }
            await write()
        }
        add("S", "finished", outcome: "yes")
        await write()
    }

    /// Shapes for the remaining screens. Key names and types only.
    func runShapes(transport: BearerTransport) async {
        let client = ItslearningClient(transport: transport)
        var routes = [
            "/restapi/personal/courses/cards/starred/v1", "/restapi/personal/instantmessages/recipients/v1",
            "/restapi/personal/instantmessages/messagethreads/suggestions/v1", "/restapi/personal/instantmessages/suggestions/v1",
            "/restapi/personal/instantmessages/recipients/search/v1?searchText=a", "/restapi/personal/yourfiles/courses/v1",
            "/restapi/personal/yourfiles/attachments/v1", "/restapi/personal/planner/plansinfo/v1",
            "/restapi/personal/person/sitelinks/v1", "/restapi/personal/person/features/v1",
        ]
        let tasks = (try? await client.tasks().items) ?? []
        var kinds: [String: Int] = [:]
        tasks.forEach { kinds[$0.elementType ?? "none", default: 0] += 1 }
        add("O", "task element types", outcome: kinds.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "))
        for type in Set(tasks.compactMap(\.elementType)) {
            if let id = tasks.first(where: { $0.elementType == type })?.elementId {
                routes.append("/restapi/personal/assignments/\(id)/v1")
                routes.append("/restapi/personal/elements/folders/\(id)/v1")
            }
        }
        if let id = try? await firstThreadId(transport: transport) {
            routes.append("/restapi/personal/instantmessages/messagethreads/\(id)/messages/v3")
            routes.append("/restapi/personal/instantmessages/messagethreads/\(id)/v3")
        }
        for route in routes {
            let template = route.replacingOccurrences(of: #"/\d+(?=/|$)"#, with: "/{id}", options: .regularExpression)
            let parts = route.split(separator: "?", maxSplits: 1).map(String.init)
            var components = URLComponents()
            components.query = parts.count > 1 ? parts[1] : nil
            do {
                let response = try await transport.send(ReadRequest(path: parts[0], query: components.queryItems ?? [], routeTemplate: template))
                shapes[template + " #\(shapes.count)"] = "status \(response.status)\n" + (ShapeReport.describe(json: response.body) ?? "(not JSON)")
                add("S", template, outcome: "\(response.status)")
            } catch {
                add("S", template, outcome: "fail", detail: category(error))
            }
        }
        add("S", "finished", outcome: "yes")
        await write()
    }

    private func firstThreadId(transport: BearerTransport) async throws -> Int? {
        let response = try await transport.send(ReadRequest(path: "/restapi/personal/instantmessages/messagethreads/v4", query: [URLQueryItem(name: "PageSize", value: "1")], routeTemplate: "threads"))
        guard let json = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let threads = json["Threads"] as? [String: Any],
              let items = threads["EntityArray"] as? [[String: Any]] else { return nil }
        return items.first?["InstantMessageThreadId"] as? Int
    }

    /// Read-only: how each assignment-backed task completes. Modes only, no titles.
    func runCompletionModes(transport: BearerTransport) async {
        let client = ItslearningClient(transport: transport)
        let tasks = (try? await client.tasks().items) ?? []
        var modes: [String: Int] = [:]
        for task in tasks where task.elementType == "CustomActivity" {
            guard let id = task.elementId else { continue }
            let request = ReadRequest(path: "/restapi/personal/assignments/\(id)/v1", routeTemplate: "assignments/{id}/v1")
            let response: ReadResponse
            do {
                response = try await transport.send(request)
            } catch {
                modes["threw \(category(error))", default: 0] += 1
                continue
            }
            guard let json = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] else {
                modes["status \(response.status), \(response.contentType), \(response.body.count) bytes", default: 0] += 1
                continue
            }
            let mode = json["CompletionMode"] as? String ?? "none"
            let canSubmit = json["CanSubmitOrEditAnswer"] as? Bool ?? false
            modes["\(response.status) \(mode) canSubmit=\(canSubmit)", default: 0] += 1
        }
        add("O", "completion modes", outcome: modes.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "; "))
        add("S", "finished", outcome: "yes")
        await write()
    }

    /// Times the index and converts one real slide deck. Records counts and sizes, never names.
    func runViewerCheck(model: AppModel) async {
        let started = Date()
        model.searchIndexedAt = nil
        await model.refreshSearchIndexIfStale()
        let count = try? await model.searchIndex?.count()
        add("V", "index built", outcome: "\(count ?? 0) records", detail: "\(Int(Date().timeIntervalSince(started)))s")
        let queryStart = Date()
        let pptx = await model.search("", scope: .activeCourses, kinds: [.material], fileExtension: "pptx")
        add("V", "pptx in active courses", outcome: "\(pptx.count)", detail: "\(Int(Date().timeIntervalSince(queryStart) * 1000))ms")
        let all = await model.search("", scope: .everywhere, kinds: [.material], fileExtension: "pptx")
        add("V", "pptx everywhere", outcome: "\(all.count)")
        await write()
        for hit in (pptx.isEmpty ? all : pptx).prefix(3) {
            guard let resource = hit.resource else { continue }
            let t0 = Date()
            await model.open(resource)
            guard let item = model.viewerItem, let fileURL = item.fileURL else {
                add("V", "open", outcome: "no file", detail: String(describing: model.downloadStates[resource.id]))
                continue
            }
            add("V", "open", outcome: "ok", detail: "\(fileURL.pathExtension), \(Int(Date().timeIntervalSince(t0)))s")
            await write()
            let t1 = Date()
            do {
                let pdf = try await OfficePDFConverter.convert(fileURL, id: "probe-\(item.id)")
                let document = PDFDocument(url: pdf)
                let page = document?.page(at: 0)?.bounds(for: .mediaBox) ?? .zero
                add("V", "convert", outcome: "\(document?.pageCount ?? 0) pages", detail: "\(Int(page.width))x\(Int(page.height)), \(Int(Date().timeIntervalSince(t1)))s")
            } catch {
                add("V", "convert", outcome: "fail", detail: "\(error)")
            }
            await write()
        }
        add("S", "finished", outcome: "yes")
        await write()
    }

    /// Times real file resolution with the current resolver. The bytes are discarded.
    func runFileTiming(transport: BearerTransport) async {
        let client = ItslearningClient(transport: transport)
        let courses = (try? await client.allCourses().items) ?? []
        var candidates: [Resource] = []
        for course in courses.prefix(6) {
            candidates += await surveyOne(client: client, course: course)
        }
        let files = candidates.filter { $0.learningToolId == 5009 }.shuffled().prefix(10)
        for resource in files {
            let start = Date()
            do {
                let staged = try await FileAcquirer(session: session, client: client).acquire(resource)
                let ext = (staged.suggestedName as NSString?)?.pathExtension.lowercased() ?? "?"
                add("T", "file", outcome: "\(Int(Date().timeIntervalSince(start) * 1000))ms", detail: ext)
                try? FileManager.default.removeItem(at: staged.file)
            } catch {
                add("T", "file", outcome: "fail \(Int(Date().timeIntervalSince(start) * 1000))ms", detail: "\(type(of: error))")
            }
            await write()
        }
        add("S", "finished", outcome: "yes")
        await write()
    }

    func runFull() async {
        await session.loadLightPage()
        let light = try? await session.read(ReadRequest(path: "/restapi/personal/courses/v4", routeTemplate: "courses/v4"))
        add("F6", "reads from light page", outcome: light.map { "status \($0.status)" } ?? "failed")
        add("F0", "personal REST flag", outcome: session.site.isPersonalRestApiEnabled == true ? "true" : "false or missing")

        let web = wrap(WebKitTransport(session: session), "webkit")
        let webReads = await readCore(client: web, transport: "webkit")
        guard !webReads.courseIds.isEmpty else {
            add("F2", "stopped", outcome: "no courses through WebKit")
            await write()
            return
        }

        let hosts = [session.site.baseURL.host() ?? ""]
        let allCookies = await session.allCookies()
        let scoped = CookieScope.filter(allCookies, forHosts: hosts)
        add("F3", "cookies", outcome: "\(scoped.count) of \(allCookies.count) in scope")
        let nativeTransport = URLSessionTransport(baseURL: session.site.baseURL, cookies: scoped)
        let native = wrap(nativeTransport, "native")
        let nativeReads = await readCore(client: native, transport: "native")

        add("F3", "same person", outcome: webReads.person == nativeReads.person ? "match" : "differ")
        add("F3", "same courses", outcome: webReads.courseIds == nativeReads.courseIds ? "match" : "differ")
        add("F3", "same updates", outcome: webReads.updateIds == nativeReads.updateIds ? "match" : "differ")
        add("F3", "same resources", outcome: webReads.resourceIds == nativeReads.resourceIds ? "match" : "differ")
        let changed = changedCookieCount(before: scoped, after: nativeTransport.currentCookies)
        add("F3", "cookies rotated by native reads", outcome: "\(changed)")

        await write()
        await checkPagination(client: web, courses: webReads.courses)
        let candidates = await surveyResources(client: web, courses: webReads.courses)
        await write()
        add("F6", "session restored from vault", outcome: UserDefaults.standard.bool(forKey: "LaerVaultRestored") ? "yes" : "no")
        let accepted = await surveyRoutes(courseId: webReads.courseIds[0], candidates: candidates, native: nativeTransport)
        add("S", "routes accepting the session", outcome: "\(accepted)")
        await checkIdentityInPages()
        await write()
        await checkFiles(candidates: candidates)
        await write()
    }

    /// Asks each documented student-facing read route whether the website session is accepted.
    private func surveyRoutes(courseId: Int, candidates: [Resource], transportUnderTest: any ReadTransport) async -> Int {
        var accepted = 0
        var routes = Self.studentRoutes + Self.tokenRoutes
        routes = routes.map { $0.replacingOccurrences(of: "{courseId}", with: String(courseId)) }
        for route in routes {
            let template = route.replacingOccurrences(of: #"/\d+(?=/|$)"#, with: "/{id}", options: .regularExpression)
            let parts = route.split(separator: "?", maxSplits: 1).map(String.init)
            var components = URLComponents()
            components.query = parts.count > 1 ? parts[1] : nil
            let request = ReadRequest(path: parts[0], query: components.queryItems ?? [], routeTemplate: template)
            do {
                let response = try await transportUnderTest.send(request)
                recordShape("token \(template)", response)
                if response.status == 200 { accepted += 1 }
                add("S", template, transport: "oauth", outcome: "\(response.status)")
            } catch {
                add("S", template, transport: "oauth", outcome: "fail", detail: category(error))
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return accepted
    }

    private static let tokenRoutes = [
        "/restapi/personal/person/v1", "/restapi/personal/courses/{courseId}/features/v1", "/restapi/personal/notifications/stream/v1",
        "/restapi/personal/instantmessages/recipients/v1", "/restapi/personal/yourfiles/attachments/v1",
    ]

    private func surveyRoutes(courseId: Int, candidates: [Resource], native: any ReadTransport) async -> Int {
        var routes = Self.studentRoutes.map { $0.replacingOccurrences(of: "{courseId}", with: String(courseId)) }
        if let element = candidates.first {
            routes.append("/restapi/personal/courses/resources/\(element.elementId)/v1")
            routes.append("/restapi/personal/pages/\(element.elementId)/v1")
            routes.append("/restapi/personal/assignments/\(element.elementId)/v1")
        }
        var accepted = 0
        for route in routes {
            let template = route.replacingOccurrences(of: #"/\d+(?=/|$)"#, with: "/{id}", options: .regularExpression)
            let parts = route.split(separator: "?", maxSplits: 1).map(String.init)
            var components = URLComponents()
            components.query = parts.count > 1 ? parts[1] : nil
            let request = ReadRequest(path: parts[0], query: components.queryItems ?? [], routeTemplate: template)
            do {
                let response = try await session.read(request)
                recordShape("survey \(template)", response)
                var nativeStatus = "-"
                if response.status == 200 {
                    accepted += 1
                    nativeStatus = (try? await native.send(request)).map { String($0.status) } ?? "error"
                }
                add("S", template, transport: "webkit", outcome: "\(response.status)", detail: "native \(nativeStatus)")
            } catch {
                add("S", template, transport: "webkit", outcome: "fail", detail: category(error))
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return accepted
    }

    private static let studentRoutes = [
        "/restapi/personal/person/features/v1", "/restapi/personal/person/roles/v1", "/restapi/personal/person/sitelinks/v1",
        "/restapi/personal/mobilesettings/v1", "/restapi/personal/courses/cards/starred/v1", "/restapi/personal/courses/cards/unstarred/v1",
        "/restapi/personal/courses/v3", "/restapi/personal/courses/{courseId}/v1", "/restapi/personal/courses/{courseId}/features/v2",
        "/restapi/personal/courses/{courseId}/bulletins/v1", "/restapi/personal/courses/{courseId}/calendarevents/v1",
        "/restapi/personal/courses/{courseId}/stream/v1", "/restapi/personal/courses/{courseId}/resources/v1",
        "/restapi/personal/courses/{courseId}/resources/lastupdated/v1", "/restapi/personal/courses/{courseId}/tasks/v1",
        "/restapi/personal/courses/{courseId}/tasks/count/v1", "/restapi/personal/courses/{courseId}/topics/v1",
        "/restapi/personal/courses/{courseId}/participants/v3", "/restapi/personal/courses/{courseId}/followuptasks/v1",
        "/restapi/personal/course/{courseId}/assessmentrecord/settings/v1", "/restapi/personal/course/{courseId}/assessmentrecord/assessmentrecordpersonitems/v1",
        "/restapi/personal/calendar/events/v1", "/restapi/personal/notifications/v2", "/restapi/personal/notifications/stream/v2",
        "/restapi/personal/notifications/newsfeed/v1", "/restapi/personal/notifications/unread/count/v1", "/restapi/personal/notifications/unseen/count/v1",
        "/restapi/personal/instantmessages/messagethreads/v4", "/restapi/personal/instantmessages/messagethreads/unread/count/v1",
        "/restapi/personal/instantmessages/permissions/v1", "/restapi/personal/planner/v1", "/restapi/personal/planner/plansinfo/v1",
        "/restapi/personal/tasks/v1", "/restapi/personal/tasks/followuptasks/v1", "/restapi/personal/tasklistdailyworkflow/v1",
        "/restapi/personal/tasklistdailyworkflow/{courseId}/v1", "/restapi/personal/tasklistdailyworkflow/{courseId}/completed/v1",
        "/restapi/personal/progressreport/v1", "/restapi/personal/progressreport/courses/v1", "/restapi/personal/studentplan/overview/v1",
        "/restapi/personal/yourfiles/courses/v1", "/restapi/personal/yourfiles/files/usedspace/v1",
        "/restapi/personal/course/{courseId}/plans/all/v1", "/restapi/personal/sso/url/v1?url=%2F", "/restapi/personal/calendar/events/v1?fromDate=2026-01-01T00:00:00Z&PageIndex=0&PageSize=20", "/restapi/personal/instantmessages/settings/v2",
        "/restapi/personal/instantmessages/recipients/v2", "/restapi/personal/courses/{courseId}/participantgroups/v1",
        "/restapi/personal/courses/{courseId}/bulletins/v1?PageIndex=0&PageSize=5", "/restapi/personal/courses/iteach/v1",
    ]

    private struct CoreReads {
        var person: Int?
        var courses: [Course] = []
        var courseIds: [Int] = []
        var updateIds: [Int] = []
        var resourceIds: [String] = []
    }

    private func readCore(client: ItslearningClient, transport: String) async -> CoreReads {
        var reads = CoreReads()
        reads.person = await check("F2", "person", transport: transport) { try await client.person() }?.personId
        if let courses = await check("F2", "courses", transport: transport, { try await client.allCourses() }) {
            reads.courses = courses.items
            reads.courseIds = courses.items.map(\.courseId)
            counts["courses.\(transport)"] = courses.items.count
        }
        for course in reads.courses.prefix(3) {
            if let updates = await check("F2", "updates", transport: transport, { try await client.updates(courseId: course.courseId) }) {
                reads.updateIds += updates.map(\.notificationId)
            }
            if let resources = await check("F2", "root resources", transport: transport, { try await client.rootResources(courseId: course.courseId) }) {
                reads.resourceIds += resources.items.map(\.id)
            }
            _ = await check("F2", "plans", transport: transport) { try await client.plans(courseId: course.courseId) }
        }
        _ = await check("F2", "tasks", transport: transport) { try await client.tasks() }
        return reads
    }

    private func changedCookieCount(before: [HTTPCookie], after: [HTTPCookie]) -> Int {
        let old = Dictionary(before.map { ("\($0.domain)|\($0.name)", $0.value) }) { first, _ in first }
        return after.filter { old["\($0.domain)|\($0.name)"] != $0.value }.count
    }

    private func checkPagination(client: ItslearningClient, courses: [Course]) async {
        guard let course = courses.first else {
            add("F5", "pagination", outcome: "not tested", detail: "no courses")
            return
        }
        do {
            let first = try await client.updates(courseId: course.courseId, pageSize: 5).map(\.notificationId)
            let again = try await client.updates(courseId: course.courseId, pageSize: 5).map(\.notificationId)
            add("F5", "repeat read stable", outcome: first == again ? "match" : "differ")
            let larger = try await client.updates(courseId: course.courseId, pageSize: 10).map(\.notificationId)
            add("F5", "small page is a prefix of larger", outcome: Array(larger.prefix(first.count)) == first ? "yes" : "no")
        } catch {
            add("F5", "pagination", outcome: "fail", detail: category(error))
        }
    }

    /// Walks a bounded number of folders and counts resource types.
    private func surveyResources(client: ItslearningClient, courses: [Course]) async -> [Resource] {
        var candidates: [Resource] = []
        var typeCounts: [String: Int] = [:]
        var folderBudget = 40
        for course in courses {
            guard folderBudget > 0 else { break }
            var queue: [Int?] = [nil]
            while let folder = queue.popLast(), folderBudget > 0 {
                folderBudget -= 1
                let listing: PagedResult<Resource>?
                if let folder {
                    listing = try? await client.folderResources(courseId: course.courseId, folderId: folder)
                } else {
                    listing = try? await client.rootResources(courseId: course.courseId)
                }
                for resource in listing?.items ?? [] {
                    typeCounts[resource.elementType, default: 0] += 1
                    if resource.isFolder {
                        queue.append(resource.elementId)
                    } else if resource.learningObjectId != nil, resource.learningObjectInstanceId != nil {
                        candidates.append(resource)
                    }
                }
            }
        }
        add("F4", "folders walked", outcome: "\(40 - folderBudget)")
        add("F4", "element types", outcome: typeCounts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
        add("F4", "file candidates", outcome: "\(candidates.count)")
        return candidates
    }

    private func checkFiles(candidates: [Resource]) async {
        guard !candidates.isEmpty else {
            add("F4", "file bytes", outcome: "not tested", detail: "no candidates")
            return
        }
        let byTool = Dictionary(grouping: candidates) { $0.learningToolId ?? -1 }
        add("F4", "learning tools", outcome: byTool.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.count)" }.joined(separator: ", "))
        for (tool, resources) in byTool.sorted(by: { $0.value.count > $1.value.count }).prefix(4) {
            for resource in resources.shuffled().prefix(1) {
                await traceViewer(resource, label: "tool \(tool)")
            }
        }
    }

    /// Loads an element in its own view and records the structure of every frame, with values removed.
    private func traceViewer(_ resource: Resource, label: String) async {
        guard let source = resource.url ?? resource.contentUrl, let url = URL(string: source, relativeTo: session.site.baseURL)?.absoluteURL else { return }
        add("F4", "\(label) element url", outcome: Self.template(url))
        let tracer = FrameTracer()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController.add(tracer, contentWorld: .defaultClient, name: "trace")
        configuration.userContentController.addUserScript(WKUserScript(source: FrameTracer.script, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: .defaultClient))
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: configuration)
        view.navigationDelegate = tracer
        view.load(URLRequest(url: url))
        try? await Task.sleep(for: .seconds(14))
        for line in tracer.lines {
            add("F4", "\(label) frame", outcome: line)
        }
        for line in tracer.responses {
            add("F4", "\(label) response", outcome: line)
        }
        view.stopLoading()

        if let objectId = resource.learningObjectId, let instanceId = resource.learningObjectInstanceId {
            var components = URLComponents(string: "https://resource.itslearning.com/Proxy/DownloadRedirect.ashx")!
            components.queryItems = [
                URLQueryItem(name: "LearningObjectId", value: String(objectId)),
                URLQueryItem(name: "LearningObjectInstanceId", value: String(instanceId)),
            ]
            await probeDownload(url: components.url!, label: "\(label) download native", hosts: ["resource.itslearning.com"])
            let attempt = FrameTracer()
            let direct = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: {
                let c = WKWebViewConfiguration()
                c.websiteDataStore = .default()
                return c
            }())
            direct.navigationDelegate = attempt
            direct.load(URLRequest(url: components.url!))
            try? await Task.sleep(for: .seconds(5))
            add("F4", "\(label) download webkit", outcome: attempt.responses.joined(separator: " ; "))
            direct.stopLoading()
        }
    }

    /// Host category and path shape. Identifiers, file names and query values are removed.
    nonisolated static func template(_ url: URL) -> String {
        let segments = url.path().split(separator: "/").map { segment -> String in
            let text = String(segment)
            let isRoute = text.range(of: #"^[A-Za-z]{1,32}(\.(aspx|ashx))?$"#, options: .regularExpression) != nil
            return isRoute ? text : "{x}"
        }
        let keys = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map(\.name).sorted()
        return "\(url.host() ?? "?") /\(segments.joined(separator: "/")) ?\(keys.joined(separator: ","))"
    }

    /// Finds names of identity-like values in signed-in pages and cookies. Values are never read out.
    private func checkIdentityInPages() async {
        let names = await session.allCookies().map(\.name)
        add("S", "cookie names", outcome: Set(names).sorted().joined(separator: ","))
        for path in ["/", "/DashboardMenu.aspx", "/ContentArea/ContentArea.aspx", "/Dashboard/Dashboard.aspx"] {
            guard let response = try? await session.read(ReadRequest(path: path, routeTemplate: path)) else { continue }
            let html = String(decoding: response.body, as: UTF8.self)
            let pattern = #/(?i)["']?([a-z_]*(?:person|user|account|profile|login)[a-z_]*)["']?\s*[:=]\s*["']?\d{2,}/#
            let keys = Set(html.matches(of: pattern).map { String($0.output.1) })
            let links = Set(html.matches(of: #/(?i)[a-z_\/\.]*person[a-z_\/\.]*\.aspx\?[a-z_]*=/#).map { String($0.output) })
            add("S", "identity in page \(path)", outcome: "status \(response.status), \(html.count) chars", detail: "keys \(keys.sorted()); links \(links.sorted())")
        }
        let threads = await session.allCookies().count
        add("S", "cookies now", outcome: "\(threads)")
    }

    /// Reads response headers and the first bytes only. Nothing from the file is kept.
    private func probeDownload(url: URL, label: String, hosts: [String]) async {
        let cookies = CookieScope.filter(await session.allCookies(), forHosts: hosts)
        let configuration = URLSessionConfiguration.ephemeral
        cookies.forEach { configuration.httpCookieStorage?.setCookie($0) }
        let downloads = URLSession(configuration: configuration)
        defer { downloads.invalidateAndCancel() }
        do {
            var request = URLRequest(url: url)
            request.setValue(session.site.baseURL.absoluteString, forHTTPHeaderField: "Referer")
            let (bytes, response) = try await downloads.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            var head: [UInt8] = []
            for try await byte in bytes {
                head.append(byte)
                if head.count >= 8 { break }
            }
            let mime = (http.value(forHTTPHeaderField: "Content-Type") ?? "none").split(separator: ";").first.map(String.init) ?? "none"
            let finalHost = http.url?.host() == url.host() ? "same host" : "other host"
            add("F4", label, transport: "native", outcome: "status \(http.statusCode)", detail: "\(mime), \(magic(head)), \(finalHost), length \(http.expectedContentLength), resource cookies \(cookies.count)")
        } catch {
            add("F4", label, transport: "native", outcome: "fail", detail: "\(type(of: error))")
        }
    }

    private func magic(_ head: [UInt8]) -> String {
        if head.starts(with: Array("%PDF".utf8)) { return "pdf bytes" }
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return "zip or office bytes" }
        if head.starts(with: [0xD0, 0xCF, 0x11, 0xE0]) { return "legacy office bytes" }
        if head.contains(UInt8(ascii: "<")) { return "markup" }
        return "other bytes"
    }

    private func write() async {
        struct Report: Codable {
            var entries: [Entry]
            var shapes: [String: String]
            var counts: [String: Int]
        }
        let report = Report(entries: entries, shapes: shapes, counts: counts)
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appending(path: "Laer", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: directory.appending(path: "probe-report.json"), options: .atomic)
            log.info("probe report written")
        } catch {
            log.error("probe report failed")
        }
    }
}

/// Records frame structure and response categories for the viewer trace.
private final class FrameTracer: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var lines: [String] = []
    var responses: [String] = []

    static let script = """
    (function() {
        const clean = (raw) => {
            try {
                const u = new URL(raw, location.href);
                const segments = u.pathname.split('/').filter(Boolean).map(s => /^[A-Za-z]{1,32}(\\.(aspx|ashx))?$/.test(s) ? s : '{x}');
                return u.host + ' /' + segments.join('/') + ' ?' + [...u.searchParams.keys()].sort().join(',');
            } catch (e) { return 'invalid'; }
        };
        const report = () => {
            const items = {
                frame: clean(location.href),
                iframes: [...document.querySelectorAll('iframe')].map(f => clean(f.src)),
                forms: [...document.querySelectorAll('form')].map(f => clean(f.action)),
                downloads: [...document.querySelectorAll('a')].filter(a => /download/i.test(a.href + a.id + a.className)).map(a => clean(a.href)),
                objects: [...document.querySelectorAll('embed,object')].map(o => clean(o.src || o.data || '')),
            };
            window.webkit.messageHandlers.trace.postMessage(JSON.stringify(items));
        };
        report();
        setTimeout(report, 4000);
    })();
    """

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String, !lines.contains(text) else { return }
        lines.append(text)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if let http = navigationResponse.response as? HTTPURLResponse, let url = http.url {
            let mime = http.mimeType ?? "none"
            responses.append("\(http.statusCode) \(mime) main=\(navigationResponse.isForMainFrame) \(RouteProbe.template(url))")
        }
        return navigationResponse.canShowMIMEType ? .allow : .cancel
    }
}
#endif
