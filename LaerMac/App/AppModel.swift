import AppKit
import AuthenticationServices
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
    @ObservationIgnored private var directoryLoadTask: Task<[Site], Error>?
    private(set) var sessionNotice: String?
    /// The sign-in page couldn't load, usually because there's no connection.
    private(set) var signInLoadFailed = false
    private(set) var usesWebsiteSignIn = false
    private(set) var isSigningIn = false
    private(set) var isEndingSession = false
    private(set) var signInStatus: String?
    var confirmsRemovingLocalData = false

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
    static let optionalFeaturesAskedKey = "LaerOptionalFeaturesAsked"
    /// Off until turned on in onboarding or Settings: links are found and readings saved before a click.
    var fetchesAhead: Bool { UserDefaults.standard.bool(forKey: Self.fetchesAheadKey) }
    private(set) var hasSeenOptionalFeaturesPrompt: Bool = UserDefaults.standard.bool(forKey: AppModel.optionalFeaturesAskedKey)

    /// Shown once as a non-invasive corner card after sign-in so optional features stay opt-in.
    var shouldPromptOptionalFeatures: Bool {
        guard case .ready = authState, !hasSeenOptionalFeaturesPrompt else { return false }
        if ProcessInfo.processInfo.arguments.contains("-LaerUITestReset") { return false }
        #if DEBUG
        if fixtureRoot != nil || UserDefaults.standard.bool(forKey: "LaerFixtureMode") { return false }
        #endif
        return true
    }

    func setFetchesAhead(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.fetchesAheadKey)
        if !enabled {
            stopFetchingAhead()
        } else if case .ready = authState {
            Task { await saveUpcomingReadings() }
        }
    }

    func dismissOptionalFeaturesPrompt(fetchAhead: Bool, lectureBriefs: Bool) async {
        hasSeenOptionalFeaturesPrompt = true
        UserDefaults.standard.set(true, forKey: Self.optionalFeaturesAskedKey)
        briefs.markAsked()
        setFetchesAhead(fetchAhead)
        if briefs.isAvailable {
            await setOnDeviceBriefs(lectureBriefs)
        }
    }
    /// Links the person keeps on Home and in the menu bar, such as exam or mail sites. See `AppModel+Home`.
    var studyLinks: [StudyLink] = StudyLink.saved()
    var examPlan = ExamPlanState()
    @ObservationIgnored var examPlanTask: Task<Void, Never>?
    @ObservationIgnored var examPlanGeneration = 0
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
    @ObservationIgnored private var downloadTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var downloadsToKeep: Set<String> = []

    private(set) var snapshots: SnapshotStore?
    private(set) var downloads: DownloadStore?
    private let coordinator = RefreshCoordinator()
    private var recovery: SessionRecovery?
    private var generation = 0
    private(set) var authGeneration = 0
    private var isSwitchingAccount = false
    private var isVerifyingStartup = false
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    private var checkingGeneration: Int?
    private var ephemeralRoot: URL?
    private let oauthPresentation = OAuthPresentationContext()
    @ObservationIgnored private var oauthSession: ASWebAuthenticationSession?
    @ObservationIgnored private var fileSessionTask: Task<Void, Never>?
    @ObservationIgnored private var refreshAllTask: Task<Void, Never>?
    private var bearer: BearerTransport?
    private var tokenBox: TokenBox?
    #if DEBUG
    private var fixtureFlag: FixtureFlag?
    private var fixtureTransport: (any ReadTransport)?
    private var fixtureRoot: URL?
    #endif
    private var websiteSessionVerified = false
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
        _ = Self.sweepTemporarySessionFolders()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let root = self?.ephemeralRoot else { return }
                try? Self.removeIfPresent(root)
                self?.ephemeralRoot = nil
            }
        }
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
            startupTask = Task { [weak self] in
                guard let self else { return }
                await self.open(site: saved, startup: startup, keychainRead: keychain)
                self.startupTask = nil
            }
        } else if let preset = defaults.string(forKey: "LaerInstitution") {
            Task { await chooseSite(shortName: preset) }
        }
    }

    // MARK: - Site and session

    /// Reads the public institution list for the picker. A failure leaves typing a short name working.
    func loadSiteList() async {
        guard siteList.isEmpty else { return }
        if let directoryLoadTask {
            _ = try? await directoryLoadTask.value
            return
        }
        let task = Task { try await SiteDirectory().allSites() }
        directoryLoadTask = task
        defer { directoryLoadTask = nil }
        if let sites = try? await task.value { siteList = sites }
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
        let attempt = authGeneration
        self.site = site
        let session = makeWebSession(site: site)
        webSession = session

        // Show cached content during verification, but defer reads until the account is known.
        isVerifyingStartup = true
        let keychain = keychainRead ?? Self.readTokens(for: site)
        if let startup {
            await enter(person: startup.person, site: site, startup: startup)
            guard isCurrentAuth(attempt) else { return }
        }
        Perf.mark("saved content shown")
        let tokens = await keychain.value
        guard isCurrentAuth(attempt) else { return }
        Perf.mark("tokens read")
        if let tokens {
            useOAuth(tokens, site: site)
            await verifyOAuthSession(site: site, attempt: attempt)
        } else {
            isVerifyingStartup = false
            resetAccountState()
            authState = .signingIn
            if keychainRead == nil, (NSApp.keyWindow ?? NSApp.mainWindow) != nil { beginSignIn() }
        }
    }

    private func makeWebSession(site: Site) -> WebSession {
        let session = WebSession(site: site)
        session.onNavigationFinished = { [weak self, weak session] in
            guard let self, let session, self.webSession === session else { return }
            Task { await self.checkSession() }
        }
        session.onLoadFailed = { [weak self, weak session] in
            guard let self, let session, self.webSession === session, self.usesWebsiteSignIn else { return }
            self.signInLoadFailed = true
        }
        return session
    }

    private func isCurrentAuth(_ attempt: Int) -> Bool {
        attempt == authGeneration && !isEndingSession && !Task.isCancelled
    }

    private func startOAuthSignIn(site: Site, attempt: Int) {
        let state = UUID().uuidString
        guard let pkce = try? OAuthPKCE(), let url = OAuthClient.authorizeURL(site: site, state: state, pkce: pkce) else {
            isSigningIn = false
            signInStatus = "Couldn’t start sign-in. Try again."
            return
        }
        let session = ASWebAuthenticationSession(
            url: url, callbackURLScheme: OAuthClient.redirectScheme,
            completionHandler: Self.oauthCompletion { [weak self] redirect, didCancel in
                guard let self, self.isCurrentAuth(attempt) else { return }
                defer {
                    if self.authGeneration == attempt {
                        self.oauthSession = nil
                        self.isSigningIn = false
                    }
                }
                guard let redirect else {
                    if !didCancel { self.signInStatus = "Couldn’t open sign-in. Try again." }
                    return
                }
                await self.finishOAuth(redirect: redirect, site: site, state: state, pkce: pkce, attempt: attempt)
            }
        )
        session.presentationContextProvider = oauthPresentation
        session.prefersEphemeralWebBrowserSession = false
        oauthSession = session
        if !session.start() {
            oauthSession = nil
            isSigningIn = false
            signInStatus = "Couldn’t open sign-in. Try again."
        }
    }

    /// The browser sign-in's completion handler. AuthenticationServices may call it on a background
    /// queue (Safari's launch agent replies over XPC), so it is built outside the main actor: a closure
    /// written inside `AppModel` would be main-actor isolated, and Swift's executor check would end the
    /// app the moment sign-in returned. `deliver` runs on the main actor.
    nonisolated static func oauthCompletion(
        _ deliver: @escaping @MainActor @Sendable (_ redirect: URL?, _ didCancel: Bool) async -> Void
    ) -> @Sendable (URL?, (any Error)?) -> Void {
        { redirect, error in
            let didCancel = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
            Task { @MainActor in await deliver(redirect, didCancel) }
        }
    }

    private func finishOAuth(
        redirect: URL, site: Site, state: String, pkce: OAuthPKCE, attempt: Int,
        exchange: (String, String) async throws -> OAuthTokens,
        save: (OAuthTokens) -> Bool
    ) async {
        guard isCurrentAuth(attempt) else { return }
        do {
            let code = try OAuthClient.parseCallback(redirect, expectedState: state)
            let tokens = try await exchange(code, pkce.verifier)
            guard isCurrentAuth(attempt) else { return }
            if !save(tokens) {
                signInStatus = "Laer couldn’t save your sign-in to the Keychain."
                return
            }
            useOAuth(tokens, site: site)
            await verifyOAuthSession(site: site, attempt: attempt)
        } catch {
            guard isCurrentAuth(attempt) else { return }
            signInStatus = "Sign-in couldn’t be completed. Try again."
        }
    }

    private func finishOAuth(redirect: URL, site: Site, state: String, pkce: OAuthPKCE, attempt: Int) async {
        await finishOAuth(redirect: redirect, site: site, state: state, pkce: pkce, attempt: attempt,
                          exchange: { code, verifier in
            try await OAuthTokenClient(baseURL: site.baseURL).exchange(code: code, pkceVerifier: verifier)
        }, save: { TokenVault(site: site).save($0) })
    }

    private func useOAuth(_ tokens: OAuthTokens, site: Site) {
        let box = TokenBox(tokens: tokens)
        tokenBox = box
        bearer = BearerTransport(baseURL: site.baseURL, box: box)
        let client = OAuthTokenClient(baseURL: site.baseURL)
        let vault = TokenVault(site: site)
        let log = Logger(subsystem: "app.laer.Laer", category: "session")
        recovery = SessionRecovery(refresh: {
            try await client.refresh(box.tokens.refreshToken)
        }, persist: { [weak self] renewed in
            // Keep rotated tokens in memory even if the Keychain write fails, so the active
            // session is not broken by a transient Keychain error; still surface the failure.
            if !vault.save(renewed) {
                log.error("token renewal keychain save failed")
                Task { @MainActor [weak self] in
                    self?.sessionNotice = "Laer couldn’t save your renewed sign-in to the Keychain."
                }
            }
        }, install: { renewed in
            await box.update(renewed)
        })
    }

    private func verifyOAuthSession(site: Site, attempt: Int) async {
        guard isCurrentAuth(attempt), let bearer, let recovery else { return }
        defer { if authGeneration == attempt { isVerifyingStartup = false } }
        let client = ItslearningClient(transport: bearer)
        let log = Logger(subsystem: "app.laer.Laer", category: "session")
        do {
            if let box = tokenBox {
                try await recovery.renewIfNeeded { await box.tokens.expiresAt < Date().addingTimeInterval(15) }
                guard isCurrentAuth(attempt) else { return }
            }
            let person = try await recovery.withRecovery { try await client.person() }
            guard isCurrentAuth(attempt) else { return }
            guard person.personId > 0 else { throw APIError.signedOut }
            sessionNotice = nil
            await installVerifiedIdentity(person, site: site)
            guard isCurrentAuth(attempt) else { return }
            isVerifyingStartup = false
            if let webSession {
                fileSessionTask = Task(priority: .utility) { [weak self] in
                    guard self?.isCurrentAuth(attempt) == true else { return }
                    let revision = webSession.fileSessionRevision
                    await webSession.prepareFileSession(client: client)
                    guard self?.isCurrentAuth(attempt) == true, self?.webSession === webSession,
                          revision == webSession.fileSessionRevision else { return }
                    FileAcquirer.prepareResolver(for: webSession)
                }
            }
            await refreshAll()
            guard isCurrentAuth(attempt) else { return }
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "LaerRunProbe"), let webSession {
                UserDefaults.standard.removeObject(forKey: "LaerVaultRestored")
                await RouteProbe(session: webSession).runShapes(transport: bearer)
            }
            #endif
        } catch APIError.signedOut {
            guard isCurrentAuth(attempt) else { return }
            await recovery.invalidateAll()
            guard isCurrentAuth(attempt) else { return }
            log.notice("verify rejected")
            webSession?.invalidateFileSession()
            let cleared = TokenVault(site: site).clear()
            tokenBox = nil
            self.bearer = nil
            self.recovery = nil
            let notice = cleared ? "Your session has ended." : "Laer couldn’t remove the saved sign-in from the Keychain."
            if case .ready = authState {
                sessionNotice = notice
            } else {
                authState = .signingIn
                signInStatus = notice
            }
        } catch {
            guard isCurrentAuth(attempt) else { return }
            log.notice("verify failed: \(String(describing: type(of: error)), privacy: .public)")
            if case .ready = authState {
                // Keep the ready state when a background verification hits a transient error.
            } else {
                authState = .signingIn
                signInStatus = "Laer couldn’t verify your sign-in. Try again."
            }
        }
    }

    func beginWebsiteSignIn() {
        guard let site, !isEndingSession else { return }
        let attempt = startSignInAttempt(website: true)
        let previousRecovery = recovery
        Task {
            await previousRecovery?.invalidateAll()
            guard isCurrentAuth(attempt) else { return }
            recovery = nil
            await startWebsiteSession(site: site, attempt: attempt)
        }
    }

    /// The fallback uses only the app's own website session.
    private func startWebsiteSession(site: Site, attempt: Int) async {
        tokenBox = nil
        bearer = nil
        let session = makeWebSession(site: site)
        webSession = session
        recovery = SessionRecovery { [weak self] in
            guard let self else { throw APIError.signedOut }
            try await self.renewSession()
        }
        let restored = await SessionVault(site: site).restore(into: session.cookieStore)
        guard isCurrentAuth(attempt) else { return }
        #if DEBUG
        UserDefaults.standard.set(restored > 0, forKey: "LaerVaultRestored")
        #else
        _ = restored
        #endif
        await session.loadSiteAndWait()
        guard isCurrentAuth(attempt) else { return }
        await checkSession()
    }

    /// First try the identity route. The website may accept course reads while rejecting identity.
    private func checkSession() async {
        let attempt = authGeneration
        guard isCurrentAuth(attempt), usesWebsiteSignIn, bearer == nil, !websiteSessionVerified,
              let session = webSession, let site, session.isOnSiteOrigin, checkingGeneration != attempt else { return }
        checkingGeneration = attempt
        defer { if checkingGeneration == attempt { checkingGeneration = nil } }
        let client = ItslearningClient(transport: WebKitTransport(session: session))
        let identity = try? await client.person()
        guard isCurrentAuth(attempt), session.isOnSiteOrigin else { return }
        let person: Person
        if let identity, identity.personId > 0 {
            person = identity
        } else {
            guard await Self.hasValidSession(session), isCurrentAuth(attempt), session.isOnSiteOrigin else { return }
            person = Person(personId: 0)
        }
        let saved = await SessionVault(site: site).save(from: session.cookieStore) {
            self.isCurrentAuth(attempt)
        }
        guard isCurrentAuth(attempt) else { return }
        signInStatus = nil
        sessionNotice = saved ? nil : "Laer couldn’t save your website session to the Keychain."
        await enter(person: person, site: site)
        guard isCurrentAuth(attempt) else { return }
        session.noteFileSession(ifCurrent: session.fileSessionRevision)
        websiteSessionVerified = true
        await refreshAll()
        #if DEBUG
        if isCurrentAuth(attempt), UserDefaults.standard.bool(forKey: "LaerRunProbe") {
            await RouteProbe(session: session).run()
        }
        #endif
    }

    /// Reloads the site once. Any further need to sign in goes to the user.
    private func renewSession() async throws {
        guard usesWebsiteSignIn, let session = webSession else { throw APIError.signedOut }
        let attempt = authGeneration
        await session.loadSiteAndWait()
        guard isCurrentAuth(attempt), session.isOnSiteOrigin, await Self.hasValidSession(session),
              isCurrentAuth(attempt) else { throw APIError.signedOut }
    }

    private static func hasValidSession(_ session: WebSession) async -> Bool {
        (try? await ItslearningClient(transport: WebKitTransport(session: session)).sessionIsValid()) == true
    }

    private func installVerifiedIdentity(_ person: Person, site: Site) async {
        if case .ready(let current) = authState, current.personId == person.personId {
            authState = .ready(person)
        } else {
            await enter(person: person, site: site)
        }
    }

    private func enter(person: Person, site: Site, startup: StartupAccount? = nil) async {
        let attempt = authGeneration
        if let oldStore = snapshots, startup?.storage.snapshots !== oldStore {
            isSwitchingAccount = true
            authState = .launching
            cancelAccountWork()
            let nextGeneration = await coordinator.invalidateAll()
            guard isCurrentAuth(attempt) else { return }
            generation = nextGeneration
            if let ephemeralRoot {
                await wipeAccount(snapshots: oldStore, downloads: downloads, briefs: briefs.store)
                guard isCurrentAuth(attempt) else { return }
                try? Self.removeIfPresent(ephemeralRoot)
                self.ephemeralRoot = nil
            } else {
                try? await oldStore.retire()
                guard isCurrentAuth(attempt) else { return }
            }
            resetAccountState()
            isSwitchingAccount = false
        }
        let root: URL
        if person.personId == 0 {
            root = FileManager.default.temporaryDirectory.appending(path: "LaerEphemeral-\(UUID().uuidString)")
            ephemeralRoot = root
            if localDataRoot == Self.storageRoot() { UserDefaults.standard.removeObject(forKey: Self.personKey) }
        } else {
            root = localDataRoot
            #if DEBUG
            if fixtureRoot == nil { loadRecentFiles(personId: person.personId) }
            #else
            loadRecentFiles(personId: person.personId)
            #endif
            if root == Self.storageRoot(), let data = try? JSONEncoder().encode(person) {
                UserDefaults.standard.set(data, forKey: Self.personKey)
            }
        }
        let accountKey = "\(site.customerId)-\(person.personId)"
        let storage = startup?.storage ?? AccountStorage(root: root, accountKey: accountKey)
        snapshots = storage.snapshots
        let store = storage.downloads
        downloads = store
        async let openBriefs: Void = briefs.open(root: root, accountKey: accountKey)
        let cache = if let startup { await startup.cache.value } else { await storage.loadCache() }
        await openBriefs
        guard isCurrentAuth(attempt), store === downloads else { return }
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
        if usesWebsiteSignIn { beginWebsiteSignIn() } else { beginSignIn() }
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
        guard !isEndingSession else { return }
        #if DEBUG
        if let fixtureFlag {
            authGeneration += 1
            sessionNotice = nil
            fixtureFlag.isSignedOut = false
            Task { await refreshAll() }
            return
        }
        #endif
        guard let site else { return }
        let attempt = startSignInAttempt(website: false)
        let previousRecovery = recovery
        Task {
            await previousRecovery?.invalidateAll()
            guard isCurrentAuth(attempt) else { return }
            recovery = nil
            webSession = makeWebSession(site: site)
            startOAuthSignIn(site: site, attempt: attempt)
        }
    }

    private func startSignInAttempt(website: Bool) -> Int {
        authGeneration += 1
        oauthSession?.cancel()
        oauthSession = nil
        bearer = nil
        tokenBox = nil
        sessionNotice = nil
        signInStatus = nil
        signInLoadFailed = false
        isVerifyingStartup = false
        websiteSessionVerified = false
        isSwitchingAccount = false
        usesWebsiteSignIn = website
        isSigningIn = !website
        AvatarLoader.shared.reset()
        webSession?.invalidateFileSession()
        webSession = nil
        cancelAccountWork()
        authState = .signingIn
        return authGeneration
    }

    /// Ends the session. The destructive option also removes local data for every account.
    func signOut(removeLocalData: Bool = false) async {
        guard !isEndingSession else { return }
        authGeneration += 1
        isEndingSession = true
        defer { isEndingSession = false }
        oauthSession?.cancel()
        oauthSession = nil
        startupTask?.cancel()
        isSigningIn = false
        usesWebsiteSignIn = false
        confirmsRemovingLocalData = false
        isVerifyingStartup = false
        websiteSessionVerified = false
        isSwitchingAccount = false
        authState = .launching
        let oldRecovery = recovery
        let oldSession = webSession
        let oldSnapshots = snapshots
        let oldDownloads = downloads
        let oldBriefs = briefs.store
        let temporary = ephemeralRoot
        ephemeralRoot = nil
        recovery = nil
        webSession = nil
        bearer = nil
        tokenBox = nil
        let testSession: Bool
        #if DEBUG
        testSession = fixtureRoot != nil
        #else
        testSession = false
        #endif
        if !testSession { forgetRecentFiles() }
        resetAccountState()
        await oldRecovery?.invalidateAll()
        generation = await coordinator.invalidateAll()

        var removedCredentials = true
        if !testSession {
            UserDefaults.standard.removeObject(forKey: Self.personKey)
            if let site {
                let clearedSession = SessionVault(site: site).clear()
                let clearedToken = TokenVault(site: site).clear()
                removedCredentials = clearedSession && clearedToken
            }
            ViewerFiles.removeDerivedFiles()
            await oldSession?.clearWebsiteData()
            await WebSession.clearLegacyWebsiteData()
        }

        var removedFiles = true
        if removeLocalData || temporary != nil {
            removedFiles = await wipeAccount(snapshots: oldSnapshots, downloads: oldDownloads, briefs: oldBriefs)
        } else {
            do { try await oldSnapshots?.retire() } catch { removedFiles = false }
        }
        if let temporary {
            do { try Self.removeIfPresent(temporary) } catch { removedFiles = false }
        }
        if removeLocalData {
            do { try Self.removeIfPresent(localDataRoot.appending(path: "Accounts")) } catch { removedFiles = false }
            do { try Self.removeIfPresent(localDataRoot.appending(path: "ExamPlan.pdf")) } catch { removedFiles = false }
            if !Self.sweepTemporarySessionFolders() { removedFiles = false }
            if !testSession {
                URLCache.shared.removeAllCachedResponses()
                for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("recentFiles-") {
                    UserDefaults.standard.removeObject(forKey: key)
                }
                examPlanAddress = nil
            }
        }
        signInLoadFailed = false
        if !removedCredentials || !removedFiles {
            Logger(subsystem: "app.laer.Laer", category: "session").error("sign-out cleanup failed")
        }
        if !removedCredentials && !removedFiles {
            signInStatus = "Laer couldn’t remove all saved credentials and local data."
        } else if !removedCredentials {
            signInStatus = "Laer couldn’t remove the saved sign-in from the Keychain."
        } else if !removedFiles {
            signInStatus = "Laer couldn’t finish cleaning up your local data."
        } else {
            signInStatus = nil
        }
        authState = site == nil ? .choosingSite : .signingIn
    }

    func changeInstitution() async {
        guard !isEndingSession else { return }
        await signOut()
        guard signInStatus == nil else { return }
        UserDefaults.standard.removeObject(forKey: Self.siteKey)
        webSession = nil
        site = nil
        authState = .choosingSite
    }

    @discardableResult
    private func wipeAccount(snapshots: SnapshotStore?, downloads: DownloadStore?, briefs: GeneratedBriefStore?) async -> Bool {
        var removed = true
        do { try await snapshots?.removeAllMetadata(retire: true) } catch { removed = false }
        do { try await downloads?.removeAllDownloadedFiles(retire: true) } catch { removed = false }
        do { try await briefs?.removeAll() } catch { removed = false }
        return removed
    }

    var hasVerifiedIdentity: Bool {
        if case .ready(let person) = authState { return person.personId > 0 }
        return false
    }

    private static func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    @discardableResult
    static func sweepTemporarySessionFolders(in directory: URL = FileManager.default.temporaryDirectory) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants]
        ) else { return true }
        var removedAll = true
        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix("LaerEphemeral-") || name.hasPrefix("LaerOffice-") {
                do { try FileManager.default.removeItem(at: entry) } catch { removedAll = false }
            }
        }
        return removedAll
    }

    var localDataRoot: URL {
        #if DEBUG
        if let fixtureRoot { return fixtureRoot }
        #endif
        return Self.storageRoot()
    }

    var examPlanRoot: URL { ephemeralRoot ?? localDataRoot }

    private func cancelAccountWork() {
        fileSessionTask?.cancel()
        fileSessionTask = nil
        pollTask?.cancel()
        pollTask = nil
        refreshAllTask?.cancel()
        refreshAllTask = nil
        stopFetchingAhead()
        cancelExamPlan()
        pointedResource = nil
        OfficePDFConverter.cancelConversions()
        backgroundRefreshTask?.cancel()
        backgroundRefreshTask = nil
        startupSearchTask?.cancel()
        startupSearchTask = nil
        searchDocumentWorker?.cancel()
        searchOCRBatch?.cancel()
        for task in downloadTasks.values { task.cancel() }
    }

    private func resetAccountState() {
        cancelAccountWork()
        AvatarLoader.shared.reset()
        webSession?.invalidateFileSession()
        examPlan = ExamPlanState()
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
        downloadTasks = [:]
        downloadsToKeep = []
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
        if let fixtureTransport { return ItslearningClient(transport: fixtureTransport) }
        if let fixtureFlag {
            return ItslearningClient(transport: FixtureTransport(isSignedOut: { fixtureFlag.isSignedOut }))
        }
        #endif
        if let bearer { return ItslearningClient(transport: bearer) }
        guard usesWebsiteSignIn, let session = webSession else { return nil }
        return ItslearningClient(transport: WebKitTransport(session: session))
    }

    /// The Authorization header value for a picture request, only for https on the institution's own
    /// host. Any other host, or no OAuth session, gets nil. Never put it in a URL or a log.
    func avatarAuthorization(for url: URL) async -> String? {
        guard let box = tokenBox, let origin = site?.baseURL, AvatarSession.sameOrigin(url, origin) else { return nil }
        let tokens = await box.tokens
        guard tokenBox === box, !Task.isCancelled else { return nil }
        return "Bearer \(tokens.accessToken)"
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
            tasksState.isIncomplete = snapshot.coverage == .incomplete
        }
        if let snapshot = cache.starred {
            starredIds = Set(snapshot.records.map(\.value))
        }
    }

    func refreshAll() async {
        guard case .ready = authState, !isVerifyingStartup, !Task.isCancelled else { return }
        if let refreshAllTask {
            await refreshAllTask.value
            return
        }
        let session = CollectionSession(self)
        let task = Task { await runRefreshAll(session: session) }
        refreshAllTask = task
        await task.value
        if refreshAllTask == task { refreshAllTask = nil }
    }

    private func runRefreshAll(session: CollectionSession) async {
        async let courses: Void = refreshCourses()
        async let tasks: Void = refreshTasks()
        async let starred: Void = refreshStarred()
        async let unread: Void = refreshUnreadThreadCount()
        _ = await (courses, tasks, starred, unread)
        guard session.isCurrent(self) else { return }
        Perf.mark("refresh done")
        if case .course(let id) = selection {
            await refreshUpdates(courseId: id)
        }
        guard session.isCurrent(self), backgroundRefreshTask == nil else { return }
        backgroundRefreshTask = Task(priority: .utility) { [weak self] in
            guard let self, session.isCurrent(self) else { return }
            defer { if session.matches(self) { backgroundRefreshTask = nil } }
            await prefetchActiveCourses()
            guard session.isCurrent(self) else { return }
            // Saving readings can take minutes; briefs and the search index don't wait for it.
            async let readings: Void = saveUpcomingReadings()
            scheduleBriefsForUpcoming()
            await startupSearchTask?.value
            guard session.isCurrent(self) else { return }
            await refreshSearchIndexIfStale()
            await readings
        }
    }

    func refreshIfStale() async {
        guard case .ready = authState, !isVerifyingStartup else { return }
        let session = CollectionSession(self)
        if isStale(coursesState) { await refreshCourses() }
        guard session.isCurrent(self) else { return }
        if isStale(tasksState) { await refreshTasks() }
        guard session.isCurrent(self) else { return }
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
        let session = CollectionSession(self)
        if isVerifyingStartup { await startupTask?.value }
        guard session.isCurrent(self), !isEndingSession, !isSwitchingAccount, !isVerifyingStartup else { throw CancellationError() }
        guard case .ready = authState, let client = makeClient(), let recovery else { throw APIError.signedOut }
        let box = tokenBox
        let result = try await coordinator.run(key: key, generation: generation) {
            if let box {
                do {
                    try await recovery.renewIfNeeded { await box.tokens.expiresAt < Date().addingTimeInterval(15) }
                } catch {
                    try Task.checkCancellation()
                }
            }
            return try await recovery.withRecovery { try await work(client) }
        }
        guard session.isCurrent(self) else { throw CancellationError() }
        return result
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
        let session = CollectionSession(self)
        guard case .ready = authState, coursesState.phase != .loading, !Task.isCancelled else { return }
        coursesState.phase = .loading
        defer { if session.matches(self), coursesState.phase == .loading { coursesState.phase = .idle } }
        do {
            let result = try await fetch(key: "courses") { try await $0.allCourses() }
            guard let state = await savePage(result, key: "courses", session: session) else { return }
            courses = result.items
            coursesState = state
            await indexSearchGroup("courses", hits: result.items.map(Self.courseSearchHit), complete: result.isComplete, store: session.store)
            if result.isComplete, session.isCurrent(self) {
                await retainSearchCourses(Set(result.items.map(\.courseId)), store: session.store)
            }
        } catch {
            if let message = refreshFailure(error, session: session) { coursesState.phase = .failed(message) }
        }
    }

    func refreshTasks() async {
        let session = CollectionSession(self)
        guard case .ready = authState, tasksState.phase != .loading, !Task.isCancelled else { return }
        tasksState.phase = .loading
        defer { if session.matches(self), tasksState.phase == .loading { tasksState.phase = .idle } }
        do {
            let result = try await fetch(key: "tasks") { try await $0.tasks() }
            guard let state = await savePage(result, key: "tasks", session: session) else { return }
            tasks = result.items
            tasksState = state
            await indexSearchGroup("tasks", hits: result.items.map(Self.taskSearchHit), complete: result.isComplete, store: session.store)
        } catch {
            if let message = refreshFailure(error, session: session) { tasksState.phase = .failed(message) }
        }
    }

    private func savePage<Record: Codable & Sendable>(
        _ result: PagedResult<Record>, key: String, session: CollectionSession
    ) async -> CollectionState? {
        guard session.isCurrent(self), let store = session.store else { return nil }
        let now = Date()
        let saved = try? await store.savePage(result, collection: key, at: now)
        guard session.isCurrent(self), saved != false else { return nil }
        return CollectionState(phase: .idle, lastSuccess: now, isIncomplete: !result.isComplete)
    }

    private func refreshFailure(_ error: Error, session: CollectionSession) -> String? {
        guard session.isCurrent(self), !(error is CancellationError),
              (error as? RefreshError) != .staleGeneration else { return nil }
        return message(for: error)
    }

    func refreshUnreadThreadCount() async {
        guard ParityGate.messages, case .ready = authState else { return }
        let session = CollectionSession(self)
        if let count = try? await fetch(key: "unread-thread-count", { try await $0.unreadThreadCount() }),
           session.isCurrent(self) {
            unreadThreadCount = count
        }
    }

    func loadTasks() async {
        if isStale(tasksState) { await refreshTasks() }
    }

    func loadUpdates(courseId: Int) async {
        let session = CollectionSession(self)
        if updates[courseId] == nil,
           let snapshot = await session.store?.load(CourseUpdate.self, collection: "updates-\(courseId)") {
            guard session.isCurrent(self) else { return }
            if updates[courseId] == nil {
                updates[courseId] = snapshot.records
                updatesState[courseId, default: CollectionState()].lastSuccess = snapshot.lastSuccess
            }
        }
        guard session.isCurrent(self), isStale(updatesState[courseId] ?? CollectionState()) else { return }
        await refreshUpdates(courseId: courseId)
    }

    func refreshUpdates(courseId: Int) async {
        let session = CollectionSession(self)
        guard case .ready = authState, updatesState[courseId]?.phase != .loading, !Task.isCancelled else { return }
        updatesState[courseId, default: CollectionState()].phase = .loading
        defer {
            if session.matches(self), updatesState[courseId]?.phase == .loading { updatesState[courseId]?.phase = .idle }
        }
        let key = "updates-\(courseId)"
        do {
            let result = try await fetch(key: key) { try await $0.updates(courseId: courseId) }
            guard session.isCurrent(self) else { return }
            let now = Date()
            // A recent window: merge by source ID and never treat absence as deletion.
            var merged = Dictionary((updates[courseId] ?? []).map { ($0.notificationId, $0) }) { first, _ in first }
            result.forEach { merged[$0.notificationId] = $0 }
            let sorted = merged.values.sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
            try? await session.store?.save(sorted, collection: key, coverage: .recentWindow, checkpoint: nil, at: now)
            guard session.isCurrent(self) else { return }
            updates[courseId] = sorted
            updatesState[courseId] = CollectionState(phase: .idle, lastSuccess: now)
        } catch {
            if let message = refreshFailure(error, session: session) { updatesState[courseId]?.phase = .failed(message) }
        }
    }

    func loadPlans(courseId: Int) async {
        let session = CollectionSession(self)
        let key = "plans-\(courseId)"
        Perf.mark("plans requested")
        defer { Perf.mark("plans ready") }
        if plans[courseId] == nil, let snapshot = await session.store?.load(PlanPreview.self, collection: key) {
            guard session.isCurrent(self) else { return }
            if plans[courseId] == nil, plansState[courseId]?.phase != .loading {
                plans[courseId] = snapshot.records
                plansState[courseId] = CollectionState(lastSuccess: snapshot.lastSuccess, isIncomplete: snapshot.coverage == .incomplete)
            }
        }
        guard session.isCurrent(self), case .ready = authState, plansState[courseId]?.phase != .loading,
              isStale(plansState[courseId] ?? CollectionState()) else { return }
        plansState[courseId, default: CollectionState()].phase = .loading
        defer {
            if session.matches(self), plansState[courseId]?.phase == .loading { plansState[courseId]?.phase = .idle }
        }
        do {
            let result = try await fetch(key: key) { try await $0.plans(courseId: courseId) }
            guard let state = await savePage(result, key: key, session: session) else { return }
            plans[courseId] = result.items
            plansState[courseId] = state
            await indexPlans(result, courseId: courseId, store: session.store)
        } catch {
            if let message = refreshFailure(error, session: session) { plansState[courseId]?.phase = .failed(message) }
        }
    }

    /// A course's topic list. A failure leaves the plans' own topic names and order to group by, so
    /// it is silent; the Plans tab reports its own state.
    func loadTopics(courseId: Int) async {
        guard case .ready = authState else { return }
        let session = CollectionSession(self)
        let store = session.store
        let key = "topics-\(courseId)"
        func isCurrent() -> Bool { session.isCurrent(self) }

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
        let session = CollectionSession(self)
        let key = Self.folderKey(courseId: courseId, folderId: folderId)
        await restoreFolder(key: key, session: session)
        guard session.isCurrent(self), isStale(resourcesState[key] ?? CollectionState()) else { return }
        await refreshFolder(courseId: courseId, folderId: folderId)
    }

    private func restoreFolder(key: String, session: CollectionSession) async {
        if resources[key] == nil, let snapshot = await session.store?.load(Resource.self, collection: key) {
            guard session.isCurrent(self), resources[key] == nil, resourcesState[key]?.phase != .loading else { return }
            resources[key] = snapshot.records
            resourcesState[key] = CollectionState(lastSuccess: snapshot.lastSuccess, isIncomplete: snapshot.coverage == .incomplete)
        }
    }

    func refreshFolder(courseId: Int, folderId: Int?) async {
        let session = CollectionSession(self)
        let key = Self.folderKey(courseId: courseId, folderId: folderId)
        await restoreFolder(key: key, session: session)
        guard session.isCurrent(self), case .ready = authState, resourcesState[key]?.phase != .loading else { return }
        resourcesState[key, default: CollectionState()].phase = .loading
        defer {
            if session.matches(self), resourcesState[key]?.phase == .loading { resourcesState[key]?.phase = .idle }
        }
        do {
            let result = try await fetch(key: key) { client in
                if let folderId {
                    try await client.folderResources(courseId: courseId, folderId: folderId)
                } else {
                    try await client.rootResources(courseId: courseId)
                }
            }
            guard let state = await savePage(result, key: key, session: session) else { return }
            resources[key] = result.items
            resourcesState[key] = state
            await indexFolder(result, courseId: courseId, folderId: folderId, context: nil, store: session.store)
        } catch {
            if let message = refreshFailure(error, session: session) { resourcesState[key]?.phase = .failed(message) }
        }
    }

    func savedFileURL(for resource: Resource, keep: Bool = false) async -> URL? {
        guard let downloads else { return nil }
        if keep { await keepSavedAsset(resource.id, store: downloads) }
        guard let asset = await downloads.asset(for: resource.id), downloads === self.downloads else { return nil }
        return downloads.fileURLIfPresent(for: asset)
    }

    func keepSavedAsset(_ key: String, store: DownloadStore) async {
        guard store === downloads else { return }
        do {
            try await store.markKept(resourceKey: key)
            let asset = await store.asset(for: key)
            guard store === downloads, savedAssets[key] != nil else { return }
            savedAssets[key] = asset
        } catch {
            Logger(subsystem: "app.laer.Laer", category: "downloads").error("could not keep prefetched file")
        }
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

    func download(
        _ resource: Resource, onPDFPage: FileAcquirer.PDFPageReady? = nil,
        isAutoPrefetched: Bool = false, replaceExisting: Bool = false
    ) async {
        guard case .ready = authState, let downloads, !Task.isCancelled else { return }
        let key = resource.id
        if let task = downloadTasks[key] {
            if !isAutoPrefetched { downloadsToKeep.insert(key) }
            await task.value
            if !isAutoPrefetched { await keepSavedAsset(key, store: downloads) }
            return
        }
        if !replaceExisting, let asset = savedAssets[key], downloads.fileURLIfPresent(for: asset) != nil {
            if !isAutoPrefetched { await keepSavedAsset(key, store: downloads) }
            return
        }
        let task = Task {
            await acquireDownload(resource, store: downloads, onPDFPage: onPDFPage, isAutoPrefetched: isAutoPrefetched)
            if downloadsToKeep.contains(key) { await keepSavedAsset(key, store: downloads) }
        }
        downloadTasks[key] = task
        await withTaskCancellationHandler { await task.value } onCancel: {
            if isAutoPrefetched {
                Task { @MainActor [weak self] in
                    if self?.downloadsToKeep.contains(key) != true { task.cancel() }
                }
            } else {
                task.cancel()
            }
        }
        if downloadTasks[key] == task {
            downloadTasks[key] = nil
            downloadsToKeep.remove(key)
        }
    }

    private func acquireDownload(
        _ resource: Resource, store downloads: DownloadStore, onPDFPage: FileAcquirer.PDFPageReady?,
        isAutoPrefetched: Bool
    ) async {
        let key = resource.id
        #if DEBUG
        if fixtureFlag != nil {
            await saveFixtureFile(resource, isAutoPrefetched: isAutoPrefetched && !downloadsToKeep.contains(key))
            return
        }
        #endif
        guard let session = webSession, let client = makeClient() else { return }
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
            guard !Task.isCancelled, downloads === self.downloads, session === webSession else { return }
            let asset = try await downloads.commit(
                stagedFile: staged.file,
                resourceKey: resource.id,
                suggestedName: staged.suggestedName ?? resource.title,
                contentType: staged.contentType,
                at: Date(),
                isAutoPrefetched: isAutoPrefetched && !downloadsToKeep.contains(key)
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

    func enforcePrefetchQuota(store: DownloadStore, maxBytes: UInt64 = 300 * 1024 * 1024) async {
        guard store === downloads else { return }
        do {
            let evicted = try await store.evictAutoPrefetchedIfNeeded(maxBytes: maxBytes)
            guard store === downloads else { return }
            for key in evicted {
                guard let asset = savedAssets[key], asset.isAutoPrefetched, store.fileURLIfPresent(for: asset) == nil else { continue }
                savedAssets[key] = nil
                searchDocumentQueue[key] = nil
                OfficePDFConverter.removeCached(for: key)
                convertedFiles[key] = nil
                failedConversions.remove(key)
                let index = searchIndex
                try? await index?.removeDocument(resourceKey: key)
                guard store === downloads else { return }
                if index === searchIndex { searchRevision += 1 }
            }
        } catch {
            Logger(subsystem: "app.laer.Laer", category: "downloads").error("prefetch quota cleanup failed")
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

    static func forTesting(signedOut: Bool = false, transport: (any ReadTransport)? = nil) async -> AppModel {
        FixtureWrites.shared.reset()
        let model = AppModel(forTesting: ())
        model.fixtureTransport = transport
        await model.startFixtureMode(signedOut: signedOut)
        return model
    }

    func finishOAuthForTesting(
        exchange: (String, String) async throws -> OAuthTokens, save: (OAuthTokens) -> Bool
    ) async {
        guard let site, let pkce = try? OAuthPKCE(),
              let callback = URL(string: "itsl-itslearning://login?state=fixture&code=fixture") else { return }
        await finishOAuth(redirect: callback, site: site, state: "fixture", pkce: pkce, attempt: authGeneration,
                          exchange: exchange, save: save)
    }

    func useOAuthForTesting(_ tokens: OAuthTokens, recovery: SessionRecovery? = nil) {
        guard let site else { return }
        useOAuth(tokens, site: site)
        if let recovery { self.recovery = recovery }
    }

    func hasBearerForTesting() -> Bool { bearer != nil }

    func installWebsiteIdentityForTesting(_ person: Person) async {
        guard let site else { return }
        await enter(person: person, site: site)
    }

    func installVerifiedIdentityForTesting(_ person: Person) async {
        guard let site else { return }
        await installVerifiedIdentity(person, site: site)
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
        let ephemeral = ephemeralRoot
        fixtureRoot = nil
        ephemeralRoot = nil
        resetAccountState()
        if let ephemeral { try? Self.removeIfPresent(ephemeral) }
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

    private func saveFixtureFile(_ resource: Resource, isAutoPrefetched: Bool) async {
        guard [702, 704].contains(resource.elementId), let downloads else {
            downloadStates[resource.id] = .websiteOnly
            return
        }
        let staged = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staged) }
        do {
            let scannedPage = UserDefaults.standard.bool(forKey: "LaerFixtureScannedPDF") ? 2 : nil
            try FixtureFiles.pdf(title: resource.title, scannedPage: scannedPage).write(to: staged)
            guard downloads === self.downloads, !Task.isCancelled else { return }
            let asset = try await downloads.commit(
                stagedFile: staged, resourceKey: resource.id, suggestedName: "\(resource.title).pdf",
                contentType: "application/pdf", at: Date(), isAutoPrefetched: isAutoPrefetched
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
