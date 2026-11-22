import AppKit
import Foundation
import LaerCore
import Observation
import OSLog

/// Freshness and progress for one collection. Each collection tracks its own.
struct CollectionState: Equatable {
    enum Phase: Equatable {
        case idle
        case loading
        case failed(String)
    }

    var phase: Phase = .idle
    var lastSuccess: Date?
    var isIncomplete = false
}

private struct AccountStorage: Sendable {
    struct Cache: Sendable {
        let courses: Snapshot<Course>?
        let tasks: Snapshot<StudyTask>?
        let starred: Snapshot<StoredId>?
        let assets: [LocalAsset]
    }

    let snapshots: SnapshotStore
    let downloads: DownloadStore

    init(root: URL, accountKey: String) {
        snapshots = SnapshotStore(rootDirectory: root, accountKey: accountKey)
        downloads = DownloadStore(rootDirectory: root, accountKey: accountKey)
    }

    func loadCache() async -> Cache {
        async let assets = downloads.allAssets()
        let courses = await snapshots.load(Course.self, collection: "courses")
        let tasks = await snapshots.load(StudyTask.self, collection: "tasks")
        let starred = await snapshots.load(StoredId.self, collection: "starred")
        return await Cache(courses: courses, tasks: tasks, starred: starred, assets: assets)
    }
}

private struct StartupAccount {
    let person: Person
    let storage: AccountStorage
    let cache: Task<AccountStorage.Cache, Never>
}

/// UI state and user actions. Networking, storage and refresh rules live in LaerCore.
@MainActor
@Observable
final class AppModel {
    enum AuthState: Equatable {
        /// A saved institution is opening. Nothing to choose, nothing to show yet.
        case launching
        case choosingSite
        case signingIn
        case ready(Person)
    }

    enum Selection: Hashable {
        case home
        case upcoming
        case messages
        case calendar
        case course(Int)
    }

    enum DownloadState: Equatable {
        case idle
        case downloading
        case failed(String)
        /// Not a file Laer can save; the row opens it on the website instead.
        case websiteOnly
    }

    private(set) var authState: AuthState = .choosingSite
    private(set) var site: Site?
    private(set) var webSession: WebSession?
    var siteError: String?
    var isResolvingSite = false
    /// The public institution list, read once when the picker shows, for suggestions as the person types.
    private(set) var siteList: [Site] = []
    private var isLoadingSiteList = false
    private(set) var sessionNotice: String?
    /// The sign-in page couldn't load, usually because there's no connection.
    private(set) var signInLoadFailed = false

    var selection: Selection? = .home
    /// The file showing in the right panel. Setting one adds its tab.
    var viewerItem: ViewerItem? {
        didSet {
            guard let viewerItem else { return }
            if let index = viewerTabs.firstIndex(where: { $0.id == viewerItem.id }) {
                // The same tab, now holding the file that was on its way.
                if viewerTabs[index] != viewerItem { viewerTabs[index] = viewerItem }
            } else if let old = oldValue, old.isNewTab, !viewerItem.isNewTab,
                      let index = viewerTabs.firstIndex(where: { $0.id == old.id }) {
                // A file picked from a New tab takes that tab's place.
                viewerTabs[index] = viewerItem
            } else {
                viewerTabs.append(viewerItem)
            }
        }
    }
    private(set) var viewerTabs: [ViewerItem] = []

    func showFirstPDFPage(_ page: Data, openingID: UUID) {
        guard let index = viewerTabs.firstIndex(where: { $0.openingID == openingID && $0.fileURL == nil }) else { return }
        var item = viewerTabs[index]
        item.firstPDFPage = page
        if viewerItem?.openingID == openingID {
            viewerItem = item
        } else {
            viewerTabs[index] = item
        }
    }

    var viewerWidth: CGFloat?
    /// A course whose Plans tab should come forward, set when a file opens from the menu bar.
    var plansTabRequest: Int?
    var siteLinkRequest: SiteLinkRequest?
    @ObservationIgnored var readingPrefetch: Task<Void, Never>?
    /// Saved files whose conversion ahead of opening failed, so later refreshes don't retry them.
    /// Cleared when the file is saved again or removed.
    @ObservationIgnored var failedConversions: Set<String> = []
    /// The file row under the pointer and the one link lookup in flight. See `pointer(_:isOver:)`.
    @ObservationIgnored private var pointedResource: Resource?
    @ObservationIgnored private var pointerDwell: Task<Void, Never>?
    @ObservationIgnored private var linkLookup: (resource: Resource, byPointer: Bool, task: Task<Bool, Never>)?
    /// Unsaved files on screen in an open folder or lesson, looked up after the pointer's row.
    @ObservationIgnored private var visibleLookups: (place: String, queue: [Resource]) = ("", [])

    static let fetchesAheadKey = "LaerFetchFilesAhead"
    /// On unless turned off in Settings: links are found and readings saved before a click. Decision 0020.
    var fetchesAhead: Bool { UserDefaults.standard.object(forKey: Self.fetchesAheadKey) as? Bool ?? true }
    /// Links the person keeps on Home and in the menu bar, such as exam or mail sites. See `AppModel+Home`.
    var studyLinks: [StudyLink] = StudyLink.saved()
    var examPlan = ExamPlanState()
    var viewerIsFull = false
    var convertedFiles: [String: URL] = [:]
    /// Office files the person switched to their original view.
    var officeFilesShownAsOriginal: Set<String> = []
    /// Files opened in the viewer, newest first, for the New tab page. See `AppModel+NewTab`.
    var recentFiles: [RecentFile] = []
    var recentFilesPersonId: Int?
    var starredIds: Set<Int> = []
    var searchIndex: SearchDatabase?
    var searchIndexFailed = false
    var searchCoverageIncomplete = true
    var searchRevision = 0
    @ObservationIgnored var searchDocumentWorker: Task<Void, Never>?
    @ObservationIgnored var searchDocumentQueue: [String: SearchDocumentWork] = [:]
    @ObservationIgnored var searchOCRBatch: Task<DocumentOCRBatch, Error>?
    var searchOCRIsRunning = false
    var searchOCRIsClearing = false
    var searchOCRPowerPaused = ProcessInfo.processInfo.isLowPowerModeEnabled
    var searchIndexedAt: Date?
    var isIndexing = false
    private(set) var courses: [Course] = []
    private(set) var coursesState = CollectionState()
    private(set) var updates: [Int: [CourseUpdate]] = [:]
    private(set) var updatesState: [Int: CollectionState] = [:]
    private(set) var plans: [Int: [PlanPreview]] = [:]
    private(set) var plansState: [Int: CollectionState] = [:]
    /// A course's topics in the order itslearning lists them. Plans group under these on the Plans tab.
    private(set) var topics: [Int: [Topic]] = [:]
    private var topicsRefreshedAt: [Int: Date] = [:]
    /// Briefs made on this Mac from saved readings. See `AppModel+Briefs`.
    let briefs = LectureBriefs()
    private(set) var unreadThreadCount: Int?
    private(set) var tasks: [StudyTask] = []
    private(set) var tasksState = CollectionState()
    private(set) var resources: [String: [Resource]] = [:]
    private(set) var resourcesState: [String: CollectionState] = [:]
    private(set) var downloadStates: [String: DownloadState] = [:]
    private(set) var savedAssets: [String: LocalAsset] = [:]

    private(set) var snapshots: SnapshotStore?
    private(set) var downloads: DownloadStore?
    private let coordinator = RefreshCoordinator()
    private var recovery: SessionRecovery?
    private var generation = 0
    private var isChecking = false
    private var sessionGate: Task<Void, Never>?
    private var oauthState: String?
    private var bearer: BearerTransport?
    private var tokenBox: TokenBox?
    #if DEBUG
    private var fixtureFlag: FixtureFlag?
    private var fixtureRoot: URL?
    #endif
    private var didRefreshAfterVerify = false
    private var pollTask: Task<Void, Never>?
    private var startupSearchTask: Task<Void, Never>?
    private var backgroundRefreshTask: Task<Void, Never>?

    /// Tunable defaults, not documented service limits.
    private let freshnessThreshold: TimeInterval = 5 * 60
    private let pollInterval: Duration = .seconds(5 * 60)

    private static let siteKey = "selectedSite"
    private static let personKey = "lastPerson"

    #if DEBUG
    private init(forTesting: ()) {}
    #endif

    init() {
        Perf.begin()
        let defaults = UserDefaults.standard
        #if DEBUG
        if defaults.bool(forKey: "LaerFixtureMode") {
            Task { await startFixtureMode(signedOut: defaults.bool(forKey: "LaerFixtureSignedOut")) }
            return
        }
        #endif
        // Tests start as a first run without touching the real saved institution.
        if defaults.bool(forKey: "LaerUITestReset") { return }
        if let data = defaults.data(forKey: Self.siteKey),
           let saved = try? JSONDecoder().decode(Site.self, from: data) {
            authState = .launching
            // The main actor may be busy opening the window. Warm the local reads now.
            let startup = Self.cachedPerson(defaults).map { person in
                let storage = AccountStorage(root: Self.storageRoot(), accountKey: "\(saved.customerId)-\(person.personId)")
                let cache = Task.detached(priority: .userInitiated) { await storage.loadCache() }
                return StartupAccount(person: person, storage: storage, cache: cache)
            }
            let keychain = Self.readTokens(for: saved)
            Task { await open(site: saved, startup: startup, keychainRead: keychain) }
        } else if let preset = defaults.string(forKey: "LaerInstitution") {
            Task { await chooseSite(shortName: preset) }
        }
    }

    // MARK: - Site and session

    /// Reads the public institution list for the picker. A failure leaves typing a short name working.
    func loadSiteList() async {
        guard siteList.isEmpty, !isLoadingSiteList else { return }
        isLoadingSiteList = true
        defer { isLoadingSiteList = false }
        if let sites = try? await SiteDirectory().allSites() { siteList = sites }
    }

    private func saveChosen(_ site: Site) {
        if let data = try? JSONEncoder().encode(site) {
            UserDefaults.standard.set(data, forKey: Self.siteKey)
        }
    }

    func chooseSite(_ site: Site) async {
        guard !isResolvingSite else { return }
        isResolvingSite = true
        siteError = nil
        defer { isResolvingSite = false }
        saveChosen(site)
        await open(site: site)
    }

    /// Looks the text up as a short name. When no site has it, `fallback` (the top suggestion) opens instead.
    func chooseSite(shortName: String, fallback: Site? = nil) async {
        guard !isResolvingSite else { return }
        isResolvingSite = true
        siteError = nil
        defer { isResolvingSite = false }
        do {
            let site = try await SiteDirectory().site(shortName: shortName)
            saveChosen(site)
            await open(site: site)
        } catch APIError.notFound {
            if let fallback {
                saveChosen(fallback)
                await open(site: fallback)
            } else {
                siteError = "No itslearning site has that name."
            }
        } catch {
            siteError = "The site lookup failed. Check your connection and try again."
        }
    }

    private static func cachedPerson(_ defaults: UserDefaults) -> Person? {
        guard let data = defaults.data(forKey: personKey),
              let person = try? JSONDecoder().decode(Person.self, from: data), person.personId != 0 else { return nil }
        return person
    }

    private static func readTokens(for site: Site) -> Task<OAuthTokens?, Never> {
        let vault = TokenVault(site: site)
        return Task.detached(priority: .userInitiated) { vault.load() }
    }

    private func open(
        site: Site, startup: StartupAccount? = nil, keychainRead: Task<OAuthTokens?, Never>? = nil
    ) async {
        self.site = site
        let session = WebSession(site: site)
        webSession = session
        session.onNavigationFinished = { [weak self] in
            Task { await self?.checkSession() }
        }
        recovery = SessionRecovery { [weak self] in
            guard let self else { throw APIError.signedOut }
            try await self.renewSession()
        }

        session.onLoadFailed = { [weak self] in self?.signInLoadFailed = true }
        session.onOAuthRedirect = { [weak self] url in
            Task { await self?.finishOAuth(redirect: url) }
        }

        // Saved content opens first, online or not. Requests wait for the token below.
        let keychain = keychainRead ?? Self.readTokens(for: site)
        let gate = Task { [weak self] in
            let tokens = await keychain.value
            Perf.mark("tokens read")
            guard let tokens, let self, self.webSession === session else { return }
            self.useOAuth(tokens, site: site)
        }
        sessionGate = gate
        if let person = startup?.person ?? Self.cachedPerson(.standard) {
            await enter(person: person, site: site, startup: startup)
        }
        Perf.mark("saved content shown")
        // The Keychain read blocks for a noticeable moment, so it stays off the main thread.
        let tokens = await keychain.value
        // The gate installs the token before any waiting request continues.
        await gate.value
        guard webSession === session else { return }
        sessionGate = nil
        if tokens != nil {
            await verifyOAuthSession(site: site)
            return
        }
        resetAccountState()
        authState = .signingIn
        await startOAuthSignIn(site: site)
    }

    /// OAuth is the primary route. Anything that stops it falls back to the website session.
    private func startOAuthSignIn(site: Site) async {
        let state = UUID().uuidString
        oauthState = state
        authState = authState == .choosingSite ? .signingIn : authState
        signInLoadFailed = false
        guard let url = OAuthClient.authorizeURL(site: site, state: state) else {
            await startWebsiteSession(site: site)
            return
        }
        webSession?.webView.load(URLRequest(url: url))
    }

    private func finishOAuth(redirect: URL) async {
        guard let site, let oauthState, let code = OAuthClient.code(fromRedirect: redirect, expectedState: oauthState) else {
            if let site { await startWebsiteSession(site: site) }
            return
        }
        self.oauthState = nil
        do {
            let tokens = try await OAuthTokenClient(baseURL: site.baseURL).exchange(code: code)
            TokenVault(site: site).save(tokens)
            useOAuth(tokens, site: site)
            await verifyOAuthSession(site: site)
        } catch {
            await startWebsiteSession(site: site)
        }
    }

    private func useOAuth(_ tokens: OAuthTokens, site: Site) {
        let box = TokenBox(tokens: tokens)
        tokenBox = box
        bearer = BearerTransport(baseURL: site.baseURL, box: box)
        let client = OAuthTokenClient(baseURL: site.baseURL)
        let vault = TokenVault(site: site)
        recovery = SessionRecovery {
            let log = Logger(subsystem: "app.laer.Laer", category: "session")
            let current = await box.tokens
            log.notice("refresh start, access token left \(Int(current.expiresAt.timeIntervalSinceNow))s")
            do {
                let renewed = try await client.refresh(current.refreshToken)
                await box.update(renewed)
                vault.save(renewed)
                log.notice("refresh ok")
            } catch {
                log.notice("refresh failed: \(String(describing: error), privacy: .public)")
                throw error
            }
        }
    }

    private func verifyOAuthSession(site: Site) async {
        guard let bearer, let recovery else { return }
        let client = ItslearningClient(transport: bearer)
        if let box = tokenBox {
            try? await recovery.renewIfNeeded { await box.tokens.expiresAt < Date().addingTimeInterval(15) }
        }
        let log = Logger(subsystem: "app.laer.Laer", category: "session")
        // With saved content on screen, the refresh runs alongside the identity check.
        var refresh: Task<Void, Never>?
        if case .ready = authState {
            didRefreshAfterVerify = true
            refresh = Task { await refreshAll() }
        }
        do {
            let person = try await recovery.withRecovery { try await client.person() }
            log.notice("verify ok")
            sessionNotice = nil
            // Saved content already belongs to this person, so nothing needs loading twice.
            if case .ready(let current) = authState, current.personId == person.personId {} else {
                refresh?.cancel()
                refresh = nil
                await enter(person: person, site: site)
            }
            if let webSession {
                Task(priority: .utility) {
                    let revision = webSession.fileSessionRevision
                    await webSession.prepareFileSession(client: client)
                    if revision == webSession.fileSessionRevision { FileAcquirer.prepareResolver(for: webSession) }
                }
            }
            if refresh == nil {
                didRefreshAfterVerify = true
                await refreshAll()
            } else {
                await refresh?.value
            }
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "LaerRunProbe") {
                await RouteProbe(session: webSession!).runShapes(transport: bearer)
            }
            #endif
        } catch APIError.signedOut {
            log.notice("verify rejected")
            webSession?.invalidateFileSession()
            TokenVault(site: site).clear()
            tokenBox = nil
            self.bearer = nil
            if case .ready = authState {
                sessionNotice = "Your session has ended."
            } else {
                await startOAuthSignIn(site: site)
            }
        } catch {
            log.notice("verify failed: \(String(describing: error), privacy: .public)")
            // Offline or a service problem. Saved content stays and nothing is signed out.
            if case .ready = authState {} else { await startOAuthSignIn(site: site) }
        }
    }

    /// The fallback: the website's own session in the app's web view.
    private func startWebsiteSession(site: Site) async {
        guard let session = webSession else { return }
        oauthState = nil
        recovery = SessionRecovery { [weak self] in
            guard let self else { throw APIError.signedOut }
            try await self.renewSession()
        }
        let restored = await SessionVault(site: site).restore(into: session.cookieStore)
        UserDefaults.standard.set(restored > 0, forKey: "LaerVaultRestored")
        await session.loadSiteAndWait()
        await checkSession()
        if case .ready = authState, !didRefreshAfterVerify {
            sessionNotice = "Your session has ended."
        }
    }

    /// A valid identity response is the only signal of being signed in. A course count is not.
    private func checkSession() async {
        guard oauthState == nil, bearer == nil else { return }
        guard let session = webSession, let site, session.isOnSiteOrigin, !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        guard await Self.hasValidSession(session) else { return }
        sessionNotice = nil
        await SessionVault(site: site).save(from: session.cookieStore)
        if case .ready = authState {} else {
            await enter(person: Person(personId: 0), site: site)
        }
        guard !didRefreshAfterVerify else { return }
        didRefreshAfterVerify = true
        await refreshAll()
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "LaerRunProbe") {
            await RouteProbe(session: session).run()
        }
        #endif
    }

    /// Reloads the site once. Any further need to sign in goes to the user, never to an automatic loop.
    private func renewSession() async throws {
        guard let session = webSession else { throw APIError.signedOut }
        await session.loadSiteAndWait()
        guard session.isOnSiteOrigin, await Self.hasValidSession(session) else {
            throw APIError.signedOut
        }
    }

    private static func hasValidSession(_ session: WebSession) async -> Bool {
        (try? await ItslearningClient(transport: WebKitTransport(session: session)).sessionIsValid()) == true
    }

    private func enter(person: Person, site: Site, startup: StartupAccount? = nil) async {
        // Never show one account's data to another.
        if case .ready(let current) = authState, current.personId != person.personId {
            resetAccountState()
        }
        loadRecentFiles(personId: person.personId)
        let persistentRoot = Self.storageRoot()
        var root = persistentRoot
        #if DEBUG
        if let fixtureRoot { root = fixtureRoot }
        #endif
        if root == persistentRoot, let data = try? JSONEncoder().encode(person) {
            UserDefaults.standard.set(data, forKey: Self.personKey)
        }
        let accountKey = "\(site.customerId)-\(person.personId)"
        let storage = startup?.storage ?? AccountStorage(root: root, accountKey: accountKey)
        snapshots = storage.snapshots
        let store = storage.downloads
        downloads = store
        async let openBriefs: Void = briefs.open(root: root, accountKey: accountKey)
        let cache = if let startup { await startup.cache.value } else { await storage.loadCache() }
        await openBriefs
        guard store === downloads else { return }
        applyCachedAccountData(cache)
        for asset in cache.assets where !asset.id.hasPrefix(Self.messageAttachmentPrefix) {
            savedAssets[asset.id] = asset
        }
        Perf.mark("cache loaded")
        authState = .ready(person)
        Perf.mark("ready shown")
        startPolling()
        startupSearchTask?.cancel()
        startupSearchTask = Task(priority: .utility) { [weak self] in
            guard let self, self.downloads === store, !Task.isCancelled else { return }
            await self.loadSearchIndex()
            Perf.mark("startup search loaded")
        }
    }

    func retrySignInPage() {
        guard let site else { return }
        Task { await startOAuthSignIn(site: site) }
    }

    func closeViewer() {
        viewerItem = nil
        viewerTabs = []
        viewerIsFull = false
    }

    func closeTab(_ item: ViewerItem) {
        guard let index = viewerTabs.firstIndex(where: { $0.id == item.id }) else { return }
        viewerTabs.remove(at: index)
        if viewerItem?.id == item.id {
            if viewerTabs.isEmpty {
                closeViewer()
            } else {
                viewerItem = viewerTabs[min(index, viewerTabs.count - 1)]
            }
        }
    }

    func beginSignIn() {
        sessionNotice = nil
        #if DEBUG
        if let fixtureFlag {
            fixtureFlag.isSignedOut = false
            Task { await refreshAll() }
            return
        }
        #endif
        AvatarLoader.shared.reset()
        webSession?.invalidateFileSession()
        didRefreshAfterVerify = false
        authState = .signingIn
        if let site { Task { await startOAuthSignIn(site: site) } }
    }

    /// Ends the session and hides account data. Saved files stay on disk until removed explicitly.
    func signOut() async {
        generation += 1
        await coordinator.invalidate(generation: generation)
        pollTask?.cancel()
        forgetRecentFiles()
        resetAccountState()
        UserDefaults.standard.removeObject(forKey: Self.personKey)
        if let site {
            SessionVault(site: site).clear()
            TokenVault(site: site).clear()
        }
        bearer = nil
        tokenBox = nil
        ViewerFiles.removeDerivedFiles()
        await webSession?.clearWebsiteData()
        authState = .signingIn
        if let site { await startOAuthSignIn(site: site) }
    }

    func changeInstitution() async {
        await signOut()
        UserDefaults.standard.removeObject(forKey: Self.siteKey)
        webSession = nil
        site = nil
        authState = .choosingSite
    }

    private func resetAccountState() {
        AvatarLoader.shared.reset()
        webSession?.invalidateFileSession()
        cancelLinkLookups()
        pointedResource = nil
        OfficePDFConverter.cancelConversions()
        backgroundRefreshTask?.cancel()
        backgroundRefreshTask = nil
        startupSearchTask?.cancel()
        startupSearchTask = nil
        courses = []
        coursesState = CollectionState()
        updates = [:]
        updatesState = [:]
        plans = [:]
        plansState = [:]
        topics = [:]
        topicsRefreshedAt = [:]
        unreadThreadCount = nil
        tasks = []
        tasksState = CollectionState()
        resources = [:]
        resourcesState = [:]
        downloadStates = [:]
        savedAssets = [:]
        selection = .home
        closeViewer()
        convertedFiles = [:]
        failedConversions = []
        officeFilesShownAsOriginal = []
        recentFiles = []
        recentFilesPersonId = nil
        starredIds = []
        searchIndex = nil
        searchIndexedAt = nil
        searchIndexFailed = false
        searchCoverageIncomplete = true
        searchRevision = 0
        isIndexing = false
        searchDocumentWorker?.cancel()
        searchOCRBatch?.cancel()
        searchDocumentWorker = nil
        searchDocumentQueue = [:]
        searchOCRBatch = nil
        searchOCRIsRunning = false
        searchOCRIsClearing = false
        snapshots = nil
        downloads = nil
        briefs.close()
    }

    private static func storageRoot() -> URL {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "Laer", directoryHint: .isDirectory)
    }

    private func makeClient() -> ItslearningClient? {
        #if DEBUG
        if let fixtureFlag {
            return ItslearningClient(transport: FixtureTransport(isSignedOut: { fixtureFlag.isSignedOut }))
        }
        #endif
        if let bearer { return ItslearningClient(transport: bearer) }
        guard let session = webSession else { return nil }
        return ItslearningClient(transport: WebKitTransport(session: session))
    }

    /// The Authorization header value for a picture request, only for https on the institution's own
    /// host. Any other host, or no OAuth session, gets nil. Never put it in a URL or a log.
    func avatarAuthorization(for url: URL) async -> String? {
        guard let box = tokenBox, let origin = site?.baseURL, AvatarSession.sameOrigin(url, origin) else { return nil }
        return "Bearer \(await box.tokens.accessToken)"
    }

    func absoluteURL(_ string: String?) -> URL? {
        guard let string, !string.isEmpty, let site else { return nil }
        guard let url = URL(string: string, relativeTo: site.baseURL)?.absoluteURL,
              url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }

    // MARK: - Refresh

    private func applyCachedAccountData(_ cache: AccountStorage.Cache) {
        if let snapshot = cache.courses {
            courses = snapshot.records
            coursesState.lastSuccess = snapshot.lastSuccess
            coursesState.isIncomplete = snapshot.coverage == .incomplete
        }
        if let snapshot = cache.tasks {
            tasks = snapshot.records
            tasksState.lastSuccess = snapshot.lastSuccess
        }
        if let snapshot = cache.starred {
            starredIds = Set(snapshot.records.map(\.value))
        }
    }

    func refreshAll() async {
        async let courses: Void = refreshCourses()
        async let tasks: Void = refreshTasks()
        async let starred: Void = refreshStarred()
        async let unread: Void = refreshUnreadThreadCount()
        _ = await (courses, tasks, starred, unread)
        Perf.mark("refresh done")
        if case .course(let id) = selection {
            await refreshUpdates(courseId: id)
        }
        backgroundRefreshTask?.cancel()
        backgroundRefreshTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await prefetchActiveCourses()
            // Saving readings can take minutes; briefs and the search index don't wait for it.
            async let readings: Void = saveUpcomingReadings()
            scheduleBriefsForUpcoming()
            await startupSearchTask?.value
            await refreshSearchIndexIfStale()
            await readings
        }
    }

    func refreshIfStale() async {
        guard case .ready = authState else { return }
        if isStale(coursesState) { await refreshCourses() }
        if isStale(tasksState) { await refreshTasks() }
        if case .course(let id) = selection, isStale(updatesState[id] ?? CollectionState()) {
            await refreshUpdates(courseId: id)
        }
    }

    private func isStale(_ state: CollectionState) -> Bool {
        guard let last = state.lastSuccess else { return true }
        return Date().timeIntervalSince(last) > freshnessThreshold
    }

    private func startPolling() {
        pollTask?.cancel()
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                // Becoming active refreshes anyway, so a background app stays quiet.
                if NSApp.isActive { await self?.refreshIfStale() }
            }
        }
    }

    /// Runs one read through coalescing, retry and session recovery, committing only on full success.
    func fetch<T: Sendable>(key: String, _ work: @escaping @Sendable (ItslearningClient) async throws -> T) async throws -> T {
        await sessionGate?.value
        guard let client = makeClient(), let recovery else { throw APIError.signedOut }
        let box = tokenBox
        return try await coordinator.run(key: key, generation: generation) {
            if let box {
                try? await recovery.renewIfNeeded { await box.tokens.expiresAt < Date().addingTimeInterval(15) }
            }
            return try await recovery.withRecovery { try await work(client) }
        }
    }

    /// One user action, one attempt. Writes skip coalescing, retry and replay, and need the OAuth route.
    func write<T: Sendable>(_ work: @escaping @Sendable (ItslearningWriter) async throws -> T) async throws -> T {
        #if DEBUG
        if let fixtureFlag {
            return try await work(ItslearningWriter(transport: FixtureTransport(isSignedOut: { fixtureFlag.isSignedOut })))
        }
        #endif
        guard let bearer else { throw WriteError.unavailable }
        return try await work(ItslearningWriter(transport: bearer))
    }

    /// A list's error once the session has ended. The banner over the window already says it,
    /// so lists show this nowhere else.
    static let signedOutMessage = "Sign in to refresh."

    func message(for error: Error) -> String {
        switch error {
        case APIError.signedOut:
            sessionNotice = "Your session has ended."
            return Self.signedOutMessage
        case APIError.offline: return "You appear to be offline."
        case APIError.forbidden: return "You don't have access to this."
        case APIError.notFound: return "This is no longer available."
        case APIError.throttled, RefreshError.paused: return "The service asked Laer to slow down. Try again later."
        case APIError.server: return "The service had a problem."
        case APIError.schema, APIError.notJSON, APIError.unexpectedStatus: return "The service sent an unexpected response."
        case is URLError: return "You appear to be offline."
        default: return "The refresh failed."
        }
    }

    func refreshCourses() async {
        let store = snapshots
        coursesState.phase = .loading
        do {
            let result = try await fetch(key: "courses") { try await $0.allCourses() }
            let now = Date()
            courses = result.items
            try? await snapshots?.save(result.items, collection: "courses", coverage: result.isComplete ? .complete : .incomplete, checkpoint: nil, at: now)
            coursesState = CollectionState(phase: .idle, lastSuccess: now, isIncomplete: !result.isComplete)
            await indexSearchGroup("courses", hits: result.items.map(Self.courseSearchHit), complete: result.isComplete, store: store)
            if result.isComplete { await retainSearchCourses(Set(result.items.map(\.courseId)), store: store) }
        } catch is CancellationError {
            coursesState.phase = .idle
        } catch RefreshError.staleGeneration {
            coursesState.phase = .idle
        } catch {
            coursesState.phase = .failed(message(for: error))
        }
    }

    func refreshTasks() async {
        let store = snapshots
        tasksState.phase = .loading
        do {
            let result = try await fetch(key: "tasks") { try await $0.tasks() }
            let now = Date()
            tasks = result.items
            try? await snapshots?.save(result.items, collection: "tasks", coverage: result.isComplete ? .complete : .incomplete, checkpoint: nil, at: now)
            tasksState = CollectionState(phase: .idle, lastSuccess: now, isIncomplete: !result.isComplete)
            await indexSearchGroup("tasks", hits: result.items.map(Self.taskSearchHit), complete: result.isComplete, store: store)
        } catch RefreshError.staleGeneration {
            tasksState.phase = .idle
        } catch {
            tasksState.phase = .failed(message(for: error))
        }
    }

    func refreshUnreadThreadCount() async {
        guard ParityGate.messages, case .ready = authState else { return }
        let session = authState
        let store = snapshots
        let account = generation
        if let count = try? await fetch(key: "unread-thread-count", { try await $0.unreadThreadCount() }),
           !Task.isCancelled, account == generation, session == authState, store === snapshots {
            unreadThreadCount = count
        }
    }

    func loadTasks() async {
        if isStale(tasksState) { await refreshTasks() }
    }

    func loadUpdates(courseId: Int) async {
        if updates[courseId] == nil,
           let snapshot = await snapshots?.load(CourseUpdate.self, collection: "updates-\(courseId)") {
            updates[courseId] = snapshot.records
            updatesState[courseId, default: CollectionState()].lastSuccess = snapshot.lastSuccess
        }
        if isStale(updatesState[courseId] ?? CollectionState()) {
            await refreshUpdates(courseId: courseId)
        }
    }

    func refreshUpdates(courseId: Int) async {
        updatesState[courseId, default: CollectionState()].phase = .loading
        do {
            let result = try await fetch(key: "updates-\(courseId)") { try await $0.updates(courseId: courseId) }
            let now = Date()
            // A recent window: merge by source ID and never treat absence as deletion.
            var merged = Dictionary((updates[courseId] ?? []).map { ($0.notificationId, $0) }) { first, _ in first }
            result.forEach { merged[$0.notificationId] = $0 }
            let sorted = merged.values.sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
            updates[courseId] = sorted
            try? await snapshots?.save(sorted, collection: "updates-\(courseId)", coverage: .recentWindow, checkpoint: nil, at: now)
            updatesState[courseId] = CollectionState(phase: .idle, lastSuccess: now)
        } catch RefreshError.staleGeneration {
            updatesState[courseId, default: CollectionState()].phase = .idle
        } catch {
            updatesState[courseId, default: CollectionState()].phase = .failed(message(for: error))
        }
    }

    func loadPlans(courseId: Int) async {
        let store = snapshots
        Perf.mark("plans requested")
        defer { Perf.mark("plans ready") }
        if plans[courseId] == nil,
           let snapshot = await snapshots?.load(PlanPreview.self, collection: "plans-\(courseId)") {
            plans[courseId] = snapshot.records
            plansState[courseId, default: CollectionState()].lastSuccess = snapshot.lastSuccess
        }
        guard isStale(plansState[courseId] ?? CollectionState()) else { return }
        plansState[courseId, default: CollectionState()].phase = .loading
        do {
            let result = try await fetch(key: "plans-\(courseId)") { try await $0.plans(courseId: courseId) }
            let now = Date()
            plans[courseId] = result.items
            try? await snapshots?.save(result.items, collection: "plans-\(courseId)", coverage: result.isComplete ? .complete : .incomplete, checkpoint: nil, at: now)
            plansState[courseId] = CollectionState(phase: .idle, lastSuccess: now, isIncomplete: !result.isComplete)
            await indexPlans(result, courseId: courseId, store: store)
        } catch RefreshError.staleGeneration {
            plansState[courseId, default: CollectionState()].phase = .idle
        } catch {
            plansState[courseId, default: CollectionState()].phase = .failed(message(for: error))
        }
    }

    /// A course's topic list. A failure leaves the plans' own topic names and order to group by, so
    /// it is silent; the Plans tab reports its own state.
    func loadTopics(courseId: Int) async {
        guard case .ready = authState else { return }
        let session = authState
        let store = snapshots
        let account = generation
        let key = "topics-\(courseId)"
        func isCurrent() -> Bool {
            !Task.isCancelled && account == generation && session == authState && store === snapshots
        }

        if topics[courseId] == nil, let saved = await store?.load(Topic.self, collection: key) {
            guard isCurrent() else { return }
            if topics[courseId] == nil {
                topics[courseId] = saved.records
                topicsRefreshedAt[courseId] = saved.lastSuccess
            }
        }
        guard isCurrent(),
              topicsRefreshedAt[courseId].map({ Date().timeIntervalSince($0) > freshnessThreshold }) ?? true,
              let result = try? await fetch(key: key, { try await $0.topics(courseId: courseId) }),
              isCurrent() else { return }

        let now = Date()
        topics[courseId] = result.items
        topicsRefreshedAt[courseId] = now
        try? await store?.save(
            result.items, collection: key, coverage: result.isComplete ? .complete : .incomplete, checkpoint: nil, at: now
        )
    }

    // MARK: - Materials

    static func folderKeyPrefix(courseId: Int) -> String { "resources-\(courseId)-" }

    static func folderKey(courseId: Int, folderId: Int?) -> String {
        folderKeyPrefix(courseId: courseId) + (folderId.map(String.init) ?? "root")
    }

    func loadFolder(courseId: Int, folderId: Int?) async {
        let key = Self.folderKey(courseId: courseId, folderId: folderId)
        if resources[key] == nil, let snapshot = await snapshots?.load(Resource.self, collection: key) {
            resources[key] = snapshot.records
            resourcesState[key, default: CollectionState()].lastSuccess = snapshot.lastSuccess
        }
        guard isStale(resourcesState[key] ?? CollectionState()) else { return }
        await refreshFolder(courseId: courseId, folderId: folderId)
    }

    func refreshFolder(courseId: Int, folderId: Int?) async {
        let store = snapshots
        let key = Self.folderKey(courseId: courseId, folderId: folderId)
        resourcesState[key, default: CollectionState()].phase = .loading
        do {
            let result = try await fetch(key: key) { client in
                if let folderId {
                    try await client.folderResources(courseId: courseId, folderId: folderId)
                } else {
                    try await client.rootResources(courseId: courseId)
                }
            }
            let now = Date()
            resources[key] = result.items
            try? await snapshots?.save(result.items, collection: key, coverage: result.isComplete ? .complete : .incomplete, checkpoint: nil, at: now)
            resourcesState[key] = CollectionState(phase: .idle, lastSuccess: now, isIncomplete: !result.isComplete)
            await indexFolder(result, courseId: courseId, folderId: folderId, context: nil, store: store)
        } catch RefreshError.staleGeneration {
            resourcesState[key, default: CollectionState()].phase = .idle
        } catch {
            resourcesState[key, default: CollectionState()].phase = .failed(message(for: error))
        }
    }

    func savedFileURL(for resource: Resource) async -> URL? {
        guard let downloads else { return nil }
        if let asset = savedAssets[resource.id], let file = downloads.fileURLIfPresent(for: asset) { return file }
        guard let asset = await downloads.asset(for: resource.id) else { return nil }
        return downloads.fileURLIfPresent(for: asset)
    }

    private static let messageAttachmentPrefix = "message-attachment:"


    static func messageAttachmentKey(_ messageId: Int64) -> String {
        messageAttachmentPrefix + String(messageId)
    }

    func openMessageAttachment(_ message: InstantMessage, threadId: Int) async {
        let messageId = message.messageId
        let key = Self.messageAttachmentKey(messageId)
        guard downloadStates[key] != .downloading, case .ready = authState,
              let downloads, let origin = site?.baseURL, let url = absoluteURL(message.attachmentUrl),
              FileAcquirer.canAcquireAttachment(at: url, origin: origin) else { return }

        let name = message.attachmentName.flatMap { $0.isBlank ? nil : $0 }
        Perf.mark("message attachment requested")
        downloadStates[key] = .downloading
        defer {
            if downloads === self.downloads, downloadStates[key] == .downloading {
                downloadStates[key] = .idle
            }
        }

        do {
            let asset: LocalAsset
            if let saved = await downloads.asset(for: key) {
                asset = saved
                Perf.mark("message attachment cache hit")
            } else {
                try Task.checkCancellation()
                guard downloads === self.downloads else { return }
                let staged = try await stageMessageAttachment(
                    at: url, origin: origin, threadId: threadId, messageId: messageId, store: downloads
                )
                Perf.mark("message attachment acquired")
                defer { try? FileManager.default.removeItem(at: staged.file) }
                try Task.checkCancellation()
                guard downloads === self.downloads else { return }
                asset = try await downloads.commit(
                    stagedFile: staged.file, resourceKey: key,
                    suggestedName: name ?? staged.suggestedName ?? String(localized: "Attachment"),
                    contentType: staged.contentType, at: Date()
                )
            }
            try Task.checkCancellation()
            guard downloads === self.downloads, let file = downloads.fileURLIfPresent(for: asset) else { return }
            viewerItem = ViewerItem(id: key, title: asset.displayName, fileURL: file)
            Perf.mark("message attachment shown")
        } catch {
            guard downloads === self.downloads else { return }
            switch error {
            case is CancellationError: break
            case FileAcquirerError.websiteOnly, DownloadError.notADocument:
                downloadStates[key] = .websiteOnly
            default:
                downloadStates[key] = .failed("The attachment couldn’t be opened.")
            }
        }
    }

    private func stageMessageAttachment(
        at url: URL, origin: URL, threadId: Int, messageId: Int64, store: DownloadStore
    ) async throws -> FileAcquirer.Staged {
        #if DEBUG
        if fixtureFlag != nil {
            guard url.path == "/file/11" else { throw FileAcquirerError.websiteOnly }
            let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FixtureFiles.pdf(title: "Outline").write(to: file)
            return FileAcquirer.Staged(file: file, suggestedName: "outline.pdf", contentType: "application/pdf")
        }
        #endif
        let session = webSession
        func ensureCurrent() throws {
            try Task.checkCancellation()
            guard store === downloads, session === webSession else { throw CancellationError() }
        }
        if let staged = try await FileAcquirer.acquireAttachment(at: url, origin: origin, session: session) {
            return staged
        }
        try ensureCurrent()
        // Only exchange a URL on the institution's own origin for a signed-in link.
        if AvatarSession.sameOrigin(url, origin) {
            let signed = try await fetch(key: Self.messageAttachmentKey(messageId)) { try await $0.ssoURL(for: url) }
            try ensureCurrent()
            if let staged = try await FileAcquirer.acquireAttachment(at: signed, origin: origin, session: session) {
                return staged
            }
        } else if messageId < Int64.max {
            // A download URL in a cached message may have expired. Refresh just this message and retry once.
            let page = try await fetch(key: "message-attachment-refresh:\(messageId)") {
                try await $0.messages(threadId: threadId, before: messageId + 1, pageSize: 2)
            }
            try ensureCurrent()
            if let message = page.messages.first(where: { $0.messageId == messageId && $0.isDeleted != true }),
               let fresh = absoluteURL(message.attachmentUrl), fresh != url,
               let staged = try await FileAcquirer.acquireAttachment(at: fresh, origin: origin, session: session) {
                return staged
            }
        }
        throw FileAcquirerError.websiteOnly
    }

    /// The pointer rests on a file row that isn't saved. After a short pause its download link is
    /// found, so a click only has to fetch the bytes. One lookup runs at a time; when it ends, the
    /// row under the pointer by then gets the next one.
    func pointer(_ resource: Resource, isOver: Bool) {
        guard isOver, fetchesAhead else {
            if pointedResource?.id == resource.id {
                pointedResource = nil
                pointerDwell?.cancel()
            }
            return
        }
        pointedResource = resource
        pointerDwell?.cancel()
        guard needsLinkLookup(resource) else { return }
        pointerDwell = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self, !Task.isCancelled, needsLinkLookup(resource) else { return }
            // The row under the pointer goes before the rest of the screen.
            if let current = linkLookup, !current.byPointer, current.resource.id != resource.id {
                current.task.cancel()
                linkLookup = nil
                visibleLookups.queue.insert(current.resource, at: 0)
            }
            lookUpLinkAhead(resource, byPointer: true)
        }
    }

    /// A folder or lesson opened: its first unsaved files are looked up one at a time, so a click
    /// without a pause on the row is quick too. Leaving the place drops the rest.
    func lookUpLinksAhead(for resources: [Resource], place: String) {
        guard fetchesAhead else { return }
        visibleLookups = (place, Array(resources.filter(needsLinkLookup).prefix(8)))
        continueLookups()
    }

    func stopLinksAhead(place: String) {
        guard visibleLookups.place == place else { return }
        visibleLookups = ("", [])
    }

    /// Settings turned this off: nothing more is looked up or saved ahead.
    func stopFetchingAhead() {
        cancelLinkLookups()
        readingPrefetch?.cancel()
        readingPrefetch = nil
    }

    private func cancelLinkLookups() {
        visibleLookups = ("", [])
        pointerDwell?.cancel()
        linkLookup?.task.cancel()
        linkLookup = nil
    }

    private func needsLinkLookup(_ resource: Resource) -> Bool {
        guard fetchesAhead, case .ready = authState, savedAssets[resource.id] == nil,
              downloadStates[resource.id] == nil, FileAcquirer.canAttempt(resource),
              let session = webSession, session.hasFileSession else { return false }
        return session.resolvedLink(for: resource.id) == nil
    }

    private func lookUpLinkAhead(_ resource: Resource, byPointer: Bool) {
        guard linkLookup == nil, needsLinkLookup(resource), let session = webSession,
              let client = makeClient() else { return }
        let task = Task { [weak self] in
            let finished = await FileAcquirer(session: session, client: client).resolveAhead(resource)
            guard let self, linkLookup?.resource.id == resource.id else { return finished }
            linkLookup = nil
            continueLookups()
            return finished
        }
        linkLookup = (resource, byPointer, task)
    }

    private func continueLookups() {
        guard linkLookup == nil else { return }
        if let pointed = pointedResource, needsLinkLookup(pointed) {
            lookUpLinkAhead(pointed, byPointer: true)
            return
        }
        while linkLookup == nil, !visibleLookups.queue.isEmpty {
            lookUpLinkAhead(visibleLookups.queue.removeFirst(), byPointer: false)
        }
    }

    func download(_ resource: Resource, onPDFPage: FileAcquirer.PDFPageReady? = nil) async {
        #if DEBUG
        if fixtureFlag != nil {
            await saveFixtureFile(resource)
            return
        }
        #endif
        guard let session = webSession, let downloads, let client = makeClient() else { return }
        downloadStates[resource.id] = .downloading
        defer {
            if downloads === self.downloads, downloadStates[resource.id] == .downloading {
                downloadStates[resource.id] = .idle
            }
        }
        do {
            Perf.mark("file requested")
            // A lookup for this row may already be under way; its link is quicker than starting over.
            // If it ran to the end without a link, repeating the same chain would only delay signing in.
            var tryExistingSession = true
            if let lookup = linkLookup, lookup.resource.id == resource.id {
                let revision = session.fileSessionRevision
                let finished = await lookup.task.value
                tryExistingSession = !finished || session.resolvedLink(for: resource.id) != nil
                    || session.fileSessionRevision != revision
            }
            let staged = try await FileAcquirer(session: session, client: client, onPDFPage: onPDFPage)
                .acquire(resource, tryExistingSession: tryExistingSession)
            Perf.mark("file acquired")
            defer { try? FileManager.default.removeItem(at: staged.file) }
            let asset = try await downloads.commit(
                stagedFile: staged.file,
                resourceKey: resource.id,
                suggestedName: staged.suggestedName ?? resource.title,
                contentType: staged.contentType,
                at: Date()
            )
            guard !Task.isCancelled, downloads === self.downloads else { return }
            savedAssets[resource.id] = asset
            downloadStates[resource.id] = .idle
            // Replacing an original invalidates its converted PDF.
            OfficePDFConverter.removeCached(for: resource.id)
            convertedFiles[resource.id] = nil
            failedConversions.remove(resource.id)
            queueDocumentSearch(asset, resource: resource)
            scheduleBrief(forReading: resource)
        } catch is CancellationError {
            return
        } catch DownloadError.notADocument {
            guard downloads === self.downloads else { return }
            downloadStates[resource.id] = .websiteOnly
        } catch FileAcquirerError.websiteOnly {
            guard downloads === self.downloads else { return }
            downloadStates[resource.id] = .websiteOnly
        } catch {
            guard downloads === self.downloads else { return }
            downloadStates[resource.id] = .failed("The download failed.")
        }
    }

    func clearDownloadState(_ resource: Resource) {
        downloadStates[resource.id] = nil
    }

    /// Deletes a saved file. Only ever called from an explicit user action.
    func removeSavedFile(_ resource: Resource) async {
        guard let downloads else { return }
        let index = searchIndex
        do { try await downloads.remove(resourceKey: resource.id) } catch { return }
        guard downloads === self.downloads else { return }
        savedAssets[resource.id] = nil
        searchDocumentQueue[resource.id] = nil
        do {
            try await index?.removeDocument(resourceKey: resource.id)
            if index === searchIndex { searchRevision += 1 }
        } catch {
            if index === searchIndex { searchIndexFailed = true }
        }
        guard downloads === self.downloads else { return }
        OfficePDFConverter.removeCached(for: resource.id)
        convertedFiles[resource.id] = nil
        failedConversions.remove(resource.id)
        // Its tab would otherwise show a file that no longer exists.
        if let tab = viewerTabs.first(where: { $0.id == resource.id }) { closeTab(tab) }
    }

    // MARK: - Fixture mode for UI tests

    #if DEBUG
    private final class FixtureFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool
        init(_ value: Bool) { self.value = value }
        var isSignedOut: Bool {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    static func forTesting(signedOut: Bool = false) async -> AppModel {
        FixtureWrites.shared.reset()
        let model = AppModel(forTesting: ())
        await model.startFixtureMode(signedOut: signedOut)
        return model
    }

    func waitForSearchReadyForTesting() async {
        await startupSearchTask?.value
        await backgroundRefreshTask?.value
        await searchDocumentWorker?.value
    }

    func waitForDocumentSearchForTesting() async {
        await searchDocumentWorker?.value
    }

    func cleanupForTesting() async {
        pollTask?.cancel()
        pollTask = nil
        backgroundRefreshTask?.cancel()
        backgroundRefreshTask = nil
        startupSearchTask?.cancel()
        startupSearchTask = nil
        searchDocumentWorker?.cancel()
        await searchDocumentWorker?.value
        searchDocumentWorker = nil
        searchOCRBatch?.cancel()
        searchOCRBatch = nil
        let dir = fixtureRoot
        fixtureRoot = nil
        resetAccountState()
        FixtureWrites.shared.reset()
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func startFixtureMode(signedOut: Bool) async {
        fixtureFlag = FixtureFlag(signedOut)
        fixtureRoot = FileManager.default.temporaryDirectory.appending(path: "LaerFixture-\(UUID().uuidString)")
        site = FixtureTransport.site
        recovery = SessionRecovery { throw APIError.signedOut }
        await enter(person: Person(personId: 1001), site: FixtureTransport.site)
        await refreshAll()
    }

    private func saveFixtureFile(_ resource: Resource) async {
        guard [702, 704].contains(resource.elementId), let downloads else {
            downloadStates[resource.id] = .websiteOnly
            return
        }
        let staged = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        do {
            let scannedPage = UserDefaults.standard.bool(forKey: "LaerFixtureScannedPDF") ? 2 : nil
            try FixtureFiles.pdf(title: resource.title, scannedPage: scannedPage).write(to: staged)
            let asset = try await downloads.commit(
                stagedFile: staged, resourceKey: resource.id, suggestedName: "\(resource.title).pdf",
                contentType: "application/pdf", at: Date()
            )
            guard downloads === self.downloads else { return }
            savedAssets[resource.id] = asset
            downloadStates[resource.id] = .idle
            queueDocumentSearch(asset, resource: resource)
            scheduleBrief(forReading: resource)
        } catch {
            guard downloads === self.downloads else { return }
            downloadStates[resource.id] = .failed("The download failed.")
        }
    }
    #endif
}
