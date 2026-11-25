import Foundation
import Testing
@testable import LaerCore

@Suite struct PKCETests {
    @Test func matchesRFC7636AppendixB() {
        let pair = OAuthPKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pair.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(OAuthPKCE.method == "S256")
    }

    @Test func generatedPairsAreRandomBase64URL() throws {
        let first = try OAuthPKCE()
        let second = try OAuthPKCE()
        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        #expect(first.verifier.count == 43)
        #expect(first.challenge.count == 43)
        #expect(first.verifier.allSatisfy(alphabet.contains))
        #expect(first.challenge.allSatisfy(alphabet.contains))
        #expect(first.verifier != second.verifier)
        #expect(first.challenge == OAuthPKCE.challenge(for: first.verifier))
    }

    @Test func authorizeURLCarriesChallengeOnlyWhenAsked() throws {
        let site = Site(shortName: "example", title: "Example", baseURL: URL(string: "https://example.itslearning.com")!, customerId: 1)
        let pair = OAuthPKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let with = try #require(OAuthClient.authorizeURL(site: site, state: "s1", pkce: pair))
        let items = URLComponents(url: with, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "code_challenge" }?.value == pair.challenge)
        #expect(items.first { $0.name == "code_challenge_method" }?.value == "S256")
        #expect(!items.contains { $0.name == "code_verifier" })

        let without = try #require(OAuthClient.authorizeURL(site: site, state: "s1"))
        #expect(!(without.query ?? "").contains("code_challenge"))
    }
}

@Suite struct OAuthCallbackTests {
    private func parse(_ text: String, state: String = "abc") -> Result<String, OAuthCallbackError> {
        Result { () throws(OAuthCallbackError) -> String in
            try OAuthClient.parseCallback(URL(string: text)!, expectedState: state)
        }
    }

    @Test func acceptsExactCallback() {
        #expect(parse("itsl-itslearning://login?code=c1&state=abc") == .success("c1"))
        #expect(parse("itsl-itslearning://login/?state=abc&code=c1") == .success("c1"))
        #expect(OAuthClient.code(fromRedirect: URL(string: "itsl-itslearning://login?code=c1&state=abc")!, expectedState: "abc") == "c1")
    }

    @Test func rejectsOtherSchemesHostsAndPaths() {
        #expect(parse("https://login?code=c1&state=abc") == .failure(.notCallback))
        #expect(parse("itsl-itslearning://evil?code=c1&state=abc") == .failure(.notCallback))
        #expect(parse("itsl-itslearning://login.example.itslearning.com?code=c1&state=abc") == .failure(.notCallback))
        #expect(parse("itsl-itslearning://login/other?code=c1&state=abc") == .failure(.notCallback))
        #expect(parse("itsl-itslearning://user@login?code=c1&state=abc") == .failure(.notCallback))
        #expect(parse("itsl-itslearning://login:8080?code=c1&state=abc") == .failure(.notCallback))
    }

    @Test func rejectsDuplicateParameters() {
        #expect(parse("itsl-itslearning://login?code=c1&code=c2&state=abc") == .failure(.duplicateParameter))
        #expect(parse("itsl-itslearning://login?code=c1&state=abc&state=abc") == .failure(.duplicateParameter))
    }

    @Test func rejectsWrongOrMissingState() {
        #expect(parse("itsl-itslearning://login?code=c1&state=abd") == .failure(.stateMismatch))
        #expect(parse("itsl-itslearning://login?code=c1") == .failure(.stateMismatch))
        #expect(parse("itsl-itslearning://login?code=c1&state=abc", state: "") == .failure(.stateMismatch))
        #expect(OAuthClient.code(fromRedirect: URL(string: "itsl-itslearning://login?code=c1&state=x")!, expectedState: "abc") == nil)
    }

    @Test func rejectsMissingCodeAndErrors() {
        #expect(parse("itsl-itslearning://login?state=abc") == .failure(.missingCode))
        #expect(parse("itsl-itslearning://login?code=&state=abc") == .failure(.missingCode))
        #expect(parse("itsl-itslearning://login?error=access_denied&state=abc") == .failure(.denied))
    }
}

/// Serves canned responses for `example.itslearning.com` and records every URL asked for.
final class RedirectingProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var requested: [String: [URL]] = [:]
    private static let lock = NSLock()

    static func requests(tag: String) -> [URL] { lock.withLock { requested[tag] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let tag = request.value(forHTTPHeaderField: "X-Test-Tag") ?? url.host() ?? ""
        Self.lock.withLock { Self.requested[tag, default: []].append(url) }
        if url.path.hasSuffix("oauth2/token") {
            let target = URL(string: "https://attacker.example.com/collect")!
            let response = HTTPURLResponse(url: url, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            var redirected = URLRequest(url: target)
            redirected.httpMethod = request.httpMethod
            redirected.setValue(tag, forHTTPHeaderField: "X-Test-Tag")
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        } else {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"access_token":"a","refresh_token":"r","expires_in":60}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

@Suite struct OAuthTransportTests {
    @Test func tokenClientNeverFollowsRedirects() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingProtocol.self]
        let tag = UUID().uuidString
        configuration.httpAdditionalHeaders = ["X-Test-Tag": tag]
        let client = OAuthTokenClient(
            baseURL: URL(string: "https://example.itslearning.com")!,
            session: OAuthTokenClient.makeSession(configuration: configuration))
        await #expect(throws: (any Error).self) {
            _ = try await client.exchange(code: "synthetic-code", pkceVerifier: "synthetic-verifier")
        }
        let requested = RedirectingProtocol.requests(tag: tag)
        #expect(requested.count == 1)
        #expect(requested.allSatisfy { $0.host() == "example.itslearning.com" })
    }

    @Test func bearerRedirectsCompareSchemeHostAndPort() {
        let base = URL(string: "https://example.itslearning.com/restapi/x")!
        #expect(SameOriginPortRedirects.isSameOrigin(base, URL(string: "https://EXAMPLE.itslearning.com/y")!))
        #expect(SameOriginPortRedirects.isSameOrigin(base, URL(string: "https://example.itslearning.com:443/y")!))
        #expect(!SameOriginPortRedirects.isSameOrigin(base, URL(string: "https://example.itslearning.com:8443/y")!))
        #expect(!SameOriginPortRedirects.isSameOrigin(base, URL(string: "http://example.itslearning.com/y")!))
        #expect(!SameOriginPortRedirects.isSameOrigin(base, URL(string: "https://other.itslearning.com/y")!))
    }
}

@Suite struct DownloadOpeningTests {
    @Test(arguments: ["dmg", "jar", "mobileconfig", "webarchive", "svg", "html", "htm", "app", "pkg", "command", "sh", "zip", "exe", "terminal", "webloc", ""])
    func unsafeFormatsAreNotOpenedDirectly(ext: String) {
        #expect(!DownloadStore.canOpenDirectlyInDefaultApp(pathExtension: ext))
    }

    @Test(arguments: ["pdf", "PDF", "docx", "pptx", "xlsx", "doc", "key", "pages", "odt", "txt", "md", "csv", "json", "png", "jpg", "heic", "mp3", "mp4", "mov"])
    func documentAndMediaFormatsOpenDirectly(ext: String) {
        #expect(DownloadStore.canOpenDirectlyInDefaultApp(pathExtension: ext))
    }
}

@Suite struct DownloadQuotaTests {
    let pdf = Data(repeating: 0x25, count: 100)

    private func commit(_ store: DownloadStore, root: URL, key: String, at seconds: TimeInterval, prefetched: Bool) async throws -> LocalAsset {
        try await store.commit(
            stagedFile: try stageFile(in: root, bytes: pdf), resourceKey: key, suggestedName: "\(key).pdf",
            contentType: "application/pdf", at: Date(timeIntervalSince1970: seconds), isAutoPrefetched: prefetched)
    }

    @Test func legacyManifestDecodesAsPersonSaved() throws {
        let json = #"{"id":"r1","relativePath":"a.pdf","displayName":"a.pdf","byteCount":3,"downloadedAt":0}"#
        let asset = try JSONDecoder().decode(LocalAsset.self, from: Data(json.utf8))
        #expect(asset.isAutoPrefetched == false)
        #expect(asset.contentType == nil)
    }

    @Test func evictsOldestPrefetchedAndKeepsSavedFiles() async throws {
        let root = try makeTemporaryRoot()
        let store = DownloadStore(rootDirectory: root, accountKey: "a")
        let saved = try await commit(store, root: root, key: "saved", at: 1, prefetched: false)
        let oldest = try await commit(store, root: root, key: "old", at: 2, prefetched: true)
        _ = try await commit(store, root: root, key: "mid", at: 3, prefetched: true)
        _ = try await commit(store, root: root, key: "new", at: 4, prefetched: true)

        let evicted = try await store.evictAutoPrefetchedIfNeeded(maxBytes: 200)
        #expect(evicted == ["old"])
        #expect(await store.asset(for: "old") == nil)
        #expect(!FileManager.default.fileExists(atPath: await store.fileURL(for: oldest).path))
        #expect(await store.asset(for: "mid") != nil)
        #expect(await store.asset(for: "new") != nil)

        let rest = try await store.evictAutoPrefetchedIfNeeded(maxBytes: 0)
        #expect(Set(rest) == ["mid", "new"])
        #expect(await store.asset(for: "saved") == saved)
        #expect(FileManager.default.fileExists(atPath: await store.fileURL(for: saved).path))

        let reopened = DownloadStore(rootDirectory: root, accountKey: "a")
        #expect(await reopened.allAssets().map(\.id) == ["saved"])
    }

    @Test func savedFilesStaySavedAcrossPrefetchedRevisions() async throws {
        let root = try makeTemporaryRoot()
        let store = DownloadStore(rootDirectory: root, accountKey: "a")
        _ = try await commit(store, root: root, key: "r1", at: 1, prefetched: false)
        let newer = try await commit(store, root: root, key: "r1", at: 2, prefetched: true)
        #expect(newer.isAutoPrefetched == false)
        #expect(try await store.evictAutoPrefetchedIfNeeded(maxBytes: 0).isEmpty)

        _ = try await commit(store, root: root, key: "r2", at: 3, prefetched: true)
        try await store.markKept(resourceKey: "r2")
        #expect(try await store.evictAutoPrefetchedIfNeeded(maxBytes: 0).isEmpty)
        #expect(await store.asset(for: "r2")?.isAutoPrefetched == false)
    }

    @Test func removeAllDeletesEveryFileAndManifest() async throws {
        let root = try makeTemporaryRoot()
        let store = DownloadStore(rootDirectory: root, accountKey: "a")
        let first = try await commit(store, root: root, key: "r1", at: 1, prefetched: false)
        _ = try await commit(store, root: root, key: "r2", at: 2, prefetched: true)

        try await store.removeAllDownloadedFiles()
        #expect(await store.allAssets().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: await store.fileURL(for: first).path))
        let reopened = DownloadStore(rootDirectory: root, accountKey: "a")
        #expect(await reopened.allAssets().isEmpty)

        // The store keeps working afterwards.
        _ = try await commit(store, root: root, key: "r3", at: 3, prefetched: false)
        #expect(await store.asset(for: "r3") != nil)
    }
}
