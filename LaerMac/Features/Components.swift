import LaerCore
import SwiftUI

/// Freshness for one collection, shown only when something is not normal:
/// refreshing, failed, partial, or older than the freshness threshold.
struct FreshnessLine: View {
    let state: CollectionState
    static let staleAfter: TimeInterval = 5 * 60

    private var isStale: Bool {
        guard let date = state.lastSuccess else { return false }
        return Date().timeIntervalSince(date) > Self.staleAfter
    }

    /// A refresh over cached content shows nothing: what's on screen is already the answer.
    private var isQuietRefresh: Bool { state.phase == .loading && state.lastSuccess != nil }

    /// The normal state takes no space, so nothing sits above a page's first row.
    /// Before a first successful load, `EmptyState` owns the spinner or error line so it never duplicates.
    private var hasContent: Bool {
        guard state.lastSuccess != nil else { return false }
        if isQuietRefresh { return false }
        if case .failed(AppModel.signedOutMessage) = state.phase { return false }
        return state.phase != .idle || state.isIncomplete || isStale
    }

    var body: some View {
        if hasContent {
            HStack(spacing: Space.s6) {
                switch state.phase {
                case .loading:
                    Spinner()
                case .failed(let message):
                    ErrorLine(state.lastSuccess == nil ? message : "\(message) Showing the saved copy.")
                case .idle:
                    if state.isIncomplete {
                        Text("Partial list").font(Type.t11).foregroundStyle(Color.textMuted)
                    }
                    if isStale, let date = state.lastSuccess {
                        Text("Updated \(date.formatted(.relative(presentation: .named)))")
                            .font(Type.t11)
                            .foregroundStyle(Color.textMuted)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: Size.controlSmall, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }
}

/// What a list shows instead of rows. Unknown is not zero: an empty line only after a successful read.
struct EmptyState: View {
    let state: CollectionState
    let empty: String

    var body: some View {
        Group {
            switch state.phase {
            case .loading: Spinner()
            case .failed(AppModel.signedOutMessage):
                // The session banner says it; show what the list would show with its saved copy.
                if state.lastSuccess != nil { EmptyLine(empty) }
            case .failed(let message): ErrorLine(message)
            case .idle:
                if state.lastSuccess != nil {
                    EmptyLine(empty)
                } else {
                    EmptyLine("Unavailable until the next refresh")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Space.s8)
    }
}

/// A page's title, an optional quiet subtitle and an optional trailing accessory. The title
/// row has one fixed height, so every page's title sits on the same baseline whatever the
/// accessory is: `PageHeader(title:subtitle:dot:) { trailing }`. The caller applies the page
/// inset (`Space.page`) to its leading edge; the header ends with a 16pt gap to the content.
/// A course page passes its colour as `dot`: a 10pt dot first, then the title, both starting at
/// the inset, so the title never shifts right of other pages' titles by more than the dot.
struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var dot: Color?
    @ViewBuilder var trailing: () -> Trailing

    init(title: String, subtitle: String? = nil, dot: Color? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.dot = dot
        self.trailing = trailing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            // The trailing link sits on the title's first text baseline, not centred.
            HStack(alignment: .firstTextBaseline, spacing: Space.s8) {
                if let dot {
                    Circle()
                        .fill(dot)
                        .frame(width: 10, height: 10)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6.5 }
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(Type.title)
                    .foregroundStyle(Color.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Space.s8)
                trailing()
            }
            .frame(minHeight: Size.pageHeader)
            if let subtitle {
                Text(subtitle)
                    .font(Type.t13)
                    .foregroundStyle(Color.textMuted)
                    .lineLimit(1)
            }
        }
        .padding(.bottom, Space.s16)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, dot: Color? = nil) {
        self.init(title: title, subtitle: subtitle, dot: dot) { EmptyView() }
    }
}

/// A bar across the top when the session has ended. Content below stays readable.
struct SessionBanner: View {
    @Environment(AppModel.self) private var model
    let message: String

    var body: some View {
        HStack(spacing: Space.s8) {
            Text(message)
                .font(Type.t13)
                .foregroundStyle(Color.text)
                .lineLimit(1)
            Spacer(minLength: Space.s8)
            TextButton("Sign in", role: .primary) { model.beginSignIn() }
        }
        .padding(.horizontal, Size.contentInset)
        .padding(.vertical, Space.s6)
        .background(Color.raised)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.borderStrong).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }
}

/// A plain text field on the design's tokens.
struct FieldBox: View {
    let label: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(label, text: $text)
            .focused($isFocused)
            .textFieldStyle(.plain)
            .font(Type.t13)
            .foregroundStyle(Color.text)
            .padding(.horizontal, Space.s8)
            .frame(height: Size.control)
            .fieldChrome(focused: isFocused)
            .onSubmit(onSubmit)
            .accessibilityLabel(label)
    }
}

/// A scrolling page on `stage`. The content fills the pane, `Size.contentInset` from both
/// edges and leading-aligned; only running prose is capped, with `.readingWidth()`.
struct PageScroll<Content: View>: View {
    /// 0 for a divided list, where rows meet at their hairlines.
    var spacing: CGFloat = Space.s4
    /// For long lists, so only the rows on screen are built. Forms stay eager, so fields keep focus.
    var lazy = false
    @ViewBuilder var content: () -> Content
    @Environment(\.pageTopInset) private var topInset

    var body: some View {
        ScrollView {
            Group {
                if lazy {
                    LazyVStack(alignment: .leading, spacing: spacing) { content() }
                } else {
                    VStack(alignment: .leading, spacing: spacing) { content() }
                }
            }
            .pageColumn()
            .padding(.top, topInset)
            .padding(.bottom, Size.contentInset)
        }
        .background(Color.stage)
    }
}

extension View {
    /// The page's one column: the whole pane, leading-aligned, `Size.contentInset` from both
    /// edges. A page header or tab bar above a `PageScroll` uses this too, so its edges match the rows'.
    func pageColumn() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Size.contentInset)
    }

    /// Caps running prose at `Size.readingMax`, leading-aligned. Rows, titles and tabs never use it.
    func readingWidth() -> some View {
        frame(maxWidth: Size.readingMax, alignment: .leading)
    }
}

enum StudyDates {
    /// The one clock-time format ("8:00 AM", "08:00"): the user's locale, hour and minute only.
    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    /// The one time-range format: both ends through `time(_:)`, so ranges match single times
    /// (the interval formatter ignores the user's custom time separator). An empty or reversed
    /// range gives the start time alone.
    static func timeRange(_ start: Date, _ end: Date) -> String {
        guard end > start else { return time(start) }
        return "\(time(start))–\(time(end))"
    }

    /// Tasks with a deadline come first, soonest first. A missing deadline stays missing.
    static func sorted(_ tasks: [StudyTask]) -> [StudyTask] {
        tasks.sorted { lhs, rhs in
            switch (usable(lhs.deadline), usable(rhs.deadline)) {
            case let (a?, b?): a < b
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }
    }

    static func deadline(_ date: Date?) -> String {
        guard let date = usable(date) else { return "No deadline" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// A compact deadline for a row: the time today, the weekday this week, else the date.
    static func shortDeadline(_ date: Date?, now: Date = Date()) -> String {
        guard let date = usable(date) else { return "No deadline" }
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return time(date)
        }
        if abs(date.timeIntervalSince(now)) < 6 * 24 * 3600 {
            return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    /// Today/Yesterday/Tomorrow in the user's language (date only, no time).
    private static let relativeDayWord: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        f.doesRelativeDateFormatting = true
        return f
    }()

    /// One relative-then-absolute form for any date in a list: "Today 11:00 PM", "Yesterday 10:00 AM",
    /// "Tomorrow 8:00 AM" (no "at"), the weekday and time within six days, else "Sun 15 Nov".
    /// Follows the user's locale.
    static func relative(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        let time = Self.time(date)
        switch days {
        case -1...1:
            return "\(relativeDayWord.string(from: date)) \(time)"
        case -6...6:
            return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)"
        default:
            let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
            return sameYear
                ? date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
                : date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
        }
    }

    /// A compact week range ("9-15 Nov", "30 Nov - 6 Dec"), one format for Plans and Calendar.
    /// The year is added only when the range is not in the current year.
    static func weekRange(_ start: Date, _ end: Date) -> String {
        let calendar = Calendar.current
        let lower = min(start, end)
        let upper = max(start, end)
        let current = calendar.isDate(lower, equalTo: .now, toGranularity: .year)
            && calendar.isDate(upper, equalTo: .now, toGranularity: .year)
        return current
            ? (lower..<upper).formatted(.interval.day().month(.abbreviated))
            : (lower..<upper).formatted(.interval.day().month(.abbreviated).year())
    }

    /// A task's subtitle line: its course, then its submission state ("Biology B · In progress").
    static func taskSubtitle(course: String?, status: String?) -> String? {
        [course?.nonEmpty, statusText(status)].compactMap { $0 }.joined(separator: " · ").nonEmpty
    }

    /// A task's status in words. The normal state, not started, shows nothing.
    static func statusText(_ status: String?) -> String? {
        switch status?.lowercased() {
        case "completed", "done": "Done"
        case "inprogress", "started": "In progress"
        case "submitted", "handedin": "Submitted"
        default: nil
        }
    }

    static func planRange(start: Date?, stop: Date?) -> String {
        switch (usable(start), usable(stop)) {
        case let (a?, b?): (a..<max(a, b)).formatted(.interval.day().month(.abbreviated).year())
        case let (a?, nil): "From \(a.formatted(date: .abbreviated, time: .omitted))"
        case let (nil, b?): "Until \(b.formatted(date: .abbreviated, time: .omitted))"
        case (nil, nil): "No dates"
        }
    }

    /// A far-future placeholder year is not a real date.
    static func usable(_ date: Date?) -> Date? {
        guard let date else { return nil }
        return Calendar(identifier: .gregorian).component(.year, from: date) >= 9000 ? nil : date
    }
}

extension String {
    /// True when the text is empty or only whitespace and newlines.
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// Nil for an empty string, for optional labels built by joining parts.
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Avatar

/// A person's picture in a circle. Without a picture, or until it loads, it shows their initials
/// on a quiet tint chosen from the name. Decorative for VoiceOver: the name is always read beside it.
/// Sizes: 28 in lists, 32 beside an author line.
struct Avatar: View {
    @Environment(AppModel.self) private var model
    let name: String?
    var imageURL: String?
    var size: CGFloat = 28
    @State private var loaded: (key: String, picture: NSImage)?

    var body: some View {
        let key = AvatarLoader.key(imageURL, model: model)
        let picture = loaded?.key == key ? loaded?.picture : AvatarLoader.shared.cachedImage(for: key)
        ZStack {
            Circle().fill(Color.course(Self.tintSeed(name)).opacity(0.2))
            if let picture {
                Image(nsImage: picture)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(Self.initials(name))
                    .font(.system(size: size * 0.38, weight: .medium))
                    .foregroundStyle(Color.text.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.border, lineWidth: 1))
        .accessibilityHidden(true)
        .task(id: key) {
            guard let key, let picture = await AvatarLoader.shared.image(imageURL, for: key, model: model),
                  !Task.isCancelled else { return }
            loaded = (key, picture)
        }
    }

    /// The first letters of the first and last name; one letter for a single name; nothing for none.
    static func initials(_ name: String?) -> String {
        let words = (name ?? "").split(whereSeparator: \.isWhitespace)
        guard let first = words.first else { return "" }
        let letters = words.count > 1 ? [first, words[words.count - 1]] : [first]
        return letters.compactMap { $0.first.map { String($0).uppercased() } }.joined()
    }

    /// The same name always picks the same hue, between launches too.
    static func tintSeed(_ name: String?) -> Int {
        (name ?? "").unicodeScalars.reduce(5381) { ($0 &* 33 &+ Int($1.value)) & 0x7fff_ffff }
    }
}

/// Loads profile pictures once each and keeps them in memory only, so nothing about a person is
/// written to disk. The institution's own host and itslearning's hosts get the website session's
/// cookies for that host, as file downloads do; any other host gets a plain request with no
/// credentials. A failure shows initials and is not retried for a few minutes. Nothing is logged.
@MainActor
final class AvatarLoader {
    static let shared = AvatarLoader()

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        return cache
    }()
    private let failures: NSCache<NSString, NSDate> = {
        let cache = NSCache<NSString, NSDate>()
        cache.countLimit = 400
        return cache
    }()
    private var inflight: [String: Task<Data?, Never>] = [:]
    private var generation = 0
    private static let retryAfter: TimeInterval = 5 * 60
    private nonisolated static let maxBytes = 4 * 1024 * 1024
    private nonisolated static let pixels = 128

    /// The picture if it is already in memory, so a row that re-renders does not flash initials.
    func cachedImage(for key: String?) -> NSImage? {
        guard let key else { return nil }
        return cache.object(forKey: key as NSString)
    }

    func image(_ address: String?, for key: String, model: AppModel) async -> NSImage? {
        guard let address, Self.key(address, model: model) == key, let url = model.absoluteURL(address),
              url.scheme == "https", url.host() != nil, url.user() == nil, url.password() == nil else { return nil }
        if let hit = cachedImage(for: key) { return hit }
        if let failed = failures.object(forKey: key as NSString),
           Date().timeIntervalSince(failed as Date) < Self.retryAfter { return nil }
        let requestGeneration = generation
        let task: Task<Data?, Never>
        if let running = inflight[key] {
            task = running
        } else {
            let session = Self.isTrusted(url, site: model.site) ? model.webSession : nil
            task = Task {
                let cookieHeader = await Self.cookieHeader(for: url, session: session)
                guard !Task.isCancelled else { return nil }
                if let data = await Self.download(url, cookieHeader: cookieHeader, authorization: nil) { return data }
                guard !Task.isCancelled, let value = await model.avatarAuthorization(for: url),
                      !Task.isCancelled else { return nil }
                return await Self.download(url, cookieHeader: nil, authorization: value)
            }
            inflight[key] = task
        }
        let data = await task.value
        guard requestGeneration == generation, Self.key(address, model: model) == key else { return nil }
        inflight[key] = nil
        if let data, let picture = NSImage(data: data) {
            failures.removeObject(forKey: key as NSString)
            cache.setObject(picture, forKey: key as NSString)
            return picture
        }
        failures.setObject(Date() as NSDate, forKey: key as NSString)
        return nil
    }

    /// Scoped to the signed-in person, so another account never sees a cached picture.
    static func key(_ address: String?, model: AppModel) -> String? {
        guard let address, !address.isBlank, let site = model.site,
              case .ready(let person) = model.authState else { return nil }
        return "\(site.customerId)|\(person.personId)|\(address)"
    }

    /// Forgets every picture, failure and running load, so the next person never sees the last one's.
    func reset() {
        generation += 1
        cache.removeAllObjects()
        failures.removeAllObjects()
        inflight.values.forEach { $0.cancel() }
        inflight = [:]
    }

    private static func isTrusted(_ url: URL, site: Site?) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        if let origin = site?.baseURL, AvatarSession.sameOrigin(url, origin) { return true }
        guard url.port == nil || url.port == 443 else { return false }
        return host == "itslearning.com" || host.hasSuffix(".itslearning.com")
    }

    private static func cookieHeader(for url: URL, session: WebSession?) async -> String? {
        guard let session, let host = url.host()?.lowercased() else { return nil }
        let path = url.path.isEmpty ? "/" : url.path
        let now = Date()
        let cookies = await session.allCookies().filter { cookie in
            let domain = cookie.domain.lowercased()
            let matchesHost = domain.hasPrefix(".")
                ? host == domain.dropFirst() || host.hasSuffix(domain)
                : host == domain
            guard matchesHost, cookie.expiresDate.map({ $0 > now }) ?? true else { return false }
            let prefix = cookie.path.hasSuffix("/") ? cookie.path : cookie.path + "/"
            return path == cookie.path || path.hasPrefix(prefix)
        }
        return cookies.isEmpty ? nil : HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
    }

    /// Returns a small PNG, or nil when the answer is not an image.
    private nonisolated static func download(_ url: URL, cookieHeader: String?, authorization: String?) async -> Data? {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "LaerFixtureMode"), url.host() == FixtureTransport.site.baseURL.host() {
            return FixtureAvatars.png(for: url)
        }
        #endif
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        if let cookieHeader { request.setValue(cookieHeader, forHTTPHeaderField: "Cookie") }
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        do {
            let (bytes, response) = try await AvatarSession.shared.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("image/") == true,
                  http.expectedContentLength <= maxBytes else { return nil }
            var data = Data()
            if http.expectedContentLength > 0 { data.reserveCapacity(Int(http.expectedContentLength)) }
            for try await byte in bytes {
                guard data.count < maxBytes else { return nil }
                data.append(byte)
            }
            return thumbnail(data)
        } catch {
            return nil
        }
    }

    private nonisolated static func thumbnail(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

/// Picture requests use a separate session. Cookies are selected for the original path only, and
/// redirects can carry authorization only within the same HTTPS origin.
enum AvatarSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration, delegate: Redirects(), delegateQueue: nil)
    }()

    nonisolated static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme == "https" && rhs.scheme == "https"
            && lhs.host()?.lowercased() == rhs.host()?.lowercased()
            && (lhs.port ?? 443) == (rhs.port ?? 443)
    }

    private final class Redirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            guard let destination = request.url, destination.scheme == "https",
                  destination.user() == nil, destination.password() == nil else { return nil }
            var next = request
            next.setValue(nil, forHTTPHeaderField: "Cookie")
            if let source = task.originalRequest?.url, sameOrigin(source, destination) {
                return next
            }
            next.setValue(nil, forHTTPHeaderField: "Authorization")
            return next
        }
    }
}
