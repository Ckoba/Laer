import AuthenticationServices
import Foundation
import Testing
@testable import Laer

/// AuthenticationServices can finish browser sign-in on a background XPC queue. In 0.1.6 the
/// completion handler was main-actor isolated, so Swift's executor check ended the app right after
/// sign-in. These call the handler the way Safari's launch agent does; a regression traps the test run.
@Suite
struct OAuthCallbackTests {
    private static let callback = URL(string: "itsl-itslearning://login?state=s&code=c")!

    private func deliverFromBackground(error: (any Error)?) async -> (redirect: URL?, didCancel: Bool) {
        await withCheckedContinuation { continuation in
            let handler = AppModel.oauthCompletion { redirect, didCancel in
                MainActor.preconditionIsolated()
                continuation.resume(returning: (redirect, didCancel))
            }
            DispatchQueue.global(qos: .userInitiated).async {
                handler(error == nil ? Self.callback : nil, error)
            }
        }
    }

    @Test func successFromABackgroundQueueReachesTheMainActor() async {
        let result = await deliverFromBackground(error: nil)
        #expect(result.redirect == Self.callback)
        #expect(!result.didCancel)
    }

    @Test func cancelFromABackgroundQueueIsReportedAsCancel() async {
        let result = await deliverFromBackground(error: ASWebAuthenticationSessionError(.canceledLogin))
        #expect(result.redirect == nil)
        #expect(result.didCancel)
    }

    @Test func failureFromABackgroundQueueIsNotACancel() async {
        let result = await deliverFromBackground(error: URLError(.cannotConnectToHost))
        #expect(result.redirect == nil)
        #expect(!result.didCancel)
    }
}
