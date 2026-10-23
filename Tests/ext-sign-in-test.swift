import AppKit
import AuthenticationServices
import Synchronization

@main
@MainActor
struct ExtensionSignInTests {
    static let url = URL(string: "https://example.test/authorize")!
    static let redirect = URL(string: "raycast://oauth?code=fixture")!
    static var failures = 0

    static func main() async throws {
        _ = NSApplication.shared
        var browser: Browser?
        let session = ExtensionSignInSession { url, scheme, completion in
            let value = Browser(url: url, scheme: scheme, completion: completion)
            browser = value
            return value
        }
        var finished = false
        let task = Task {
            defer { finished = true }
            return try await session.run(url: url, callbackScheme: "raycast")
        }
        await waitUntil { browser != nil }
        task.cancel()
        await waitUntil { finished }
        expect(finished, "cancelling releases the pending sign-in without a browser callback")
        if !finished {
            browser?.complete(nil, ASWebAuthenticationSessionError(.canceledLogin))
            _ = await task.result
            exit(1)
        }
        expect(browser?.counts.withLock { $0.cancels } == 1, "cancellation closes the browser")
        browser?.complete(redirect, nil)
        await Task.yield()
        switch await task.result {
        case .failure(let error): expect(error is CancellationError, "task cancellation stays cancellation")
        case .success: expect(false, "a late callback cannot turn cancellation into success")
        }
        let oldBrowser = browser
        finished = false
        let retry = Task {
            defer { finished = true }
            return try await session.run(url: url, callbackScheme: "raycast")
        }
        await waitUntil { browser !== oldBrowser }
        oldBrowser?.complete(redirect, nil)
        await Task.yield()
        expect(!finished, "an abandoned browser cannot finish a later sign-in")
        browser?.complete(redirect, nil)
        let retryURL = try await retry.value
        expect(retryURL == redirect, "a new sign-in succeeds after cancellation")
        await failedStart()
        await cancelledBeforeStarting()
        await browserCancellation()
        print("\(failures) failures")
        if failures > 0 { exit(1) }
    }

    static func failedStart() async {
        var browser: Browser?
        let session = ExtensionSignInSession { url, scheme, completion in
            let value = Browser(url: url, scheme: scheme, startsSuccessfully: false, completion: completion)
            browser = value
            return value
        }
        var finished = false
        let task = Task {
            defer { finished = true }
            return try await session.run(url: url, callbackScheme: "raycast")
        }
        await waitUntil { finished }
        expect(finished, "a refused browser start does not leave sign-in pending")
        if !finished { browser?.complete(nil, URLError(.unknown)) }
        switch await task.result {
        case .failure(let error):
            expect(error as? ExtensionSignInSession.Failure == .failedToStart, "failed starts report why")
        case .success: expect(false, "a refused start cannot succeed")
        }
        browser?.complete(redirect, nil)
        await Task.yield()
    }

    static func cancelledBeforeStarting() async {
        var starts = 0
        let session = ExtensionSignInSession { url, scheme, completion in
            starts += 1
            return Browser(url: url, scheme: scheme, completion: completion)
        }
        let task = Task { try await session.run(url: url, callbackScheme: "raycast") }
        task.cancel()
        switch await task.result {
        case .failure(let error): expect(error is CancellationError, "pre-cancelled requests finish")
        case .success: expect(false, "pre-cancelled requests cannot succeed")
        }
        expect(starts == 0, "pre-cancelled requests never open a browser")
    }

    static func browserCancellation() async {
        let session = ExtensionSignInSession { url, scheme, completion in
            completion(nil, ASWebAuthenticationSessionError(.canceledLogin))
            return Browser(url: url, scheme: scheme, completion: completion)
        }
        do {
            _ = try await session.run(url: url, callbackScheme: "raycast")
            expect(false, "browser cancellation cannot succeed")
        } catch {
            expect(error as? ExtensionSignInSession.Failure == .cancelled, "browser cancellation is reported")
        }
    }

    static func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    static func expect(_ condition: Bool, _ message: String) {
        if !condition { failures += 1 }
        print("\(condition ? "PASS" : "FAIL")  \(message)")
    }

    final class Browser: ASWebAuthenticationSession {
        let counts = Mutex((starts: 0, cancels: 0))
        let complete: @Sendable (URL?, (any Error)?) -> Void
        let startsSuccessfully: Bool

        init(
            url: URL, scheme: String, startsSuccessfully: Bool = true,
            completion: @escaping @Sendable (URL?, (any Error)?) -> Void
        ) {
            complete = completion
            self.startsSuccessfully = startsSuccessfully
            super.init(url: url, callback: .customScheme(scheme), completionHandler: completion)
        }

        override func start() -> Bool {
            counts.withLock { $0.starts += 1 }
            return startsSuccessfully
        }

        override func cancel() {
            counts.withLock { $0.cancels += 1 }
        }
    }
}
