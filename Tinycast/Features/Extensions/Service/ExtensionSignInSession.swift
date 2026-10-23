import AppKit
import AuthenticationServices

/// One browser sign-in. It catches its own redirect, so an installed Raycast cannot take it.
@MainActor
final class ExtensionSignInSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum Failure: LocalizedError {
        case cancelled
        case failedToStart

        var errorDescription: String? {
            switch self {
            case .cancelled: "Sign-in was cancelled."
            case .failedToStart: "The browser could not start sign-in. Please try again."
            }
        }
    }

    typealias SessionFactory = (
        URL, String, @escaping @Sendable (URL?, (any Error)?) -> Void
    ) -> ASWebAuthenticationSession

    private let makeSession: SessionFactory
    private nonisolated let anchor: ASPresentationAnchor

    init(makeSession: @escaping SessionFactory = { url, scheme, completion in
        ASWebAuthenticationSession(url: url, callback: .customScheme(scheme), completionHandler: completion)
    }) {
        self.makeSession = makeSession
        anchor = NSApp.keyWindow ?? ASPresentationAnchor()
    }

    /// Resolves with the redirect URL; cancelling the task closes the browser window.
    func run(url: URL, callbackScheme: String) async throws -> URL {
        let pending = Pending()
        let redirect = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending.continuation = continuation
                let session = makeSession(url, callbackScheme) { @Sendable redirect, error in
                    Task { @MainActor in
                        if let redirect {
                            pending.finish(.success(redirect))
                        } else if let error, (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                            pending.finish(.failure(error))
                        } else {
                            pending.finish(.failure(Failure.cancelled))
                        }
                    }
                }
                session.presentationContextProvider = self
                pending.session = session
                if !session.start() {
                    pending.finish(.failure(Failure.failedToStart))
                }
            }
        } onCancel: {
            Task { @MainActor in pending.cancel() }
        }
        try Task.checkCancellation()
        return redirect
    }

    @MainActor
    private final class Pending {
        var continuation: CheckedContinuation<URL, any Error>?
        var session: ASWebAuthenticationSession?

        func finish(_ result: Result<URL, any Error>) {
            let continuation = continuation
            self.continuation = nil
            session = nil
            continuation?.resume(with: result)
        }

        func cancel() {
            let session = session
            finish(.failure(CancellationError()))
            session?.cancel()
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }
}
