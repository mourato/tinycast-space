import Foundation

actor FileSearchProbe {
    private var active = 0
    private var calls: [String] = []
    private var maximumActive = 0
    private var cancelled: [String] = []
    private let pausedQuery: String?
    private var pauseEnabled: Bool
    private var pausedContinuation: CheckedContinuation<Void, Never>?

    init(pausing query: String? = nil) {
        pausedQuery = query
        pauseEnabled = query != nil
    }

    func search(query: String, filter: FileSearchFilter, folder: String?) async -> [FileSearchResult] {
        active += 1
        calls.append(filter == .all ? query : "\(query) [\(filter.title)]")
        maximumActive = max(maximumActive, active)
        if pauseEnabled, query == pausedQuery {
            await withCheckedContinuation { continuation in
                pausedContinuation = continuation
            }
        } else {
            try? await Task.sleep(for: .milliseconds(80))
        }
        if Task.isCancelled { cancelled.append(query) }
        active -= 1
        let home = URL(fileURLWithPath: folder ?? "/Users/test")
        return [FileSearchResult(url: home.appending(path: query), isDirectory: false, homeDirectory: home)]
    }

    func snapshot() -> (calls: [String], maximumActive: Int, cancelled: [String]) {
        (calls, maximumActive, cancelled)
    }

    func waitUntilPaused() async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while pausedContinuation == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard pausedContinuation != nil else {
            pauseEnabled = false
            return false
        }
        return true
    }

    func resumePausedSearch() {
        pauseEnabled = false
        pausedContinuation?.resume()
        pausedContinuation = nil
    }
}

@main
@MainActor
struct FileSearchSessionTests {
    nonisolated(unsafe) static var failures = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() async {
        await cancelsSupersededScans()
        await folderChangeRejectsStaleResults()
        await coalescesQueuedQueries()
        await serializesRunningQueries()
        await cancellationPreventsPendingWork()
        await idleCancellationKeepsTheSessionUsable()
        await refreshRerunsThePublishedQuery()
        await blankScreenOpensOnKeptRecents()
        await recentRefreshLeavesTheOpenListAlone()
        await blankQueryLoadsRecents()
        await filterChangeRerunsTheQuery()

        print(failures == 0 ? "File search session tests passed" : "\(failures) tests failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func cancelsSupersededScans() async {
        let probe = FileSearchProbe(pausing: "a")
        let session = makeSession(probe: probe)
        session.search("a")
        guard await probe.waitUntilPaused() else { return expect(false, "the first query starts") }
        session.search("annual")
        await probe.resumePausedSearch()
        await waitUntil { session.state == .ready }
        let snapshot = await probe.snapshot()
        expect(snapshot.calls == ["a", "annual"], "the newer query runs once the scan it supersedes stops")
        expect(snapshot.cancelled == ["a"], "a newer query cancels the scan it supersedes")
        expect(session.results.first?.name == "annual", "only the newest query publishes")

        session.search("queued")
        session.cancel()
        try? await Task.sleep(for: .milliseconds(120))
        let cancelled = await probe.snapshot()
        expect(cancelled.calls == snapshot.calls || cancelled.calls == snapshot.calls + ["queued"],
               "cancelling never leaves the session publishing")
        expect(session.results.isEmpty, "a cancelled search publishes nothing")
    }

    static func folderChangeRejectsStaleResults() async {
        let probe = FileSearchProbe(pausing: "report")
        let session = makeSession(probe: probe)
        session.folderScope = { "/old" }
        session.search("report")
        guard await probe.waitUntilPaused() else { return expect(false, "scoped query starts") }
        session.folderScope = { "/new" }
        session.search("report")
        expect(session.results(folder: "/old").isEmpty, "a new folder clears the previous folder's rows")
        await probe.resumePausedSearch()
        await waitUntil { session.state == .ready }
        expect(session.results.first?.id == "/new/report", "a late result from the old folder cannot publish")
        expect(session.results().isEmpty, "scoped rows never show as root search results")
        expect(!session.results(folder: "/new").isEmpty, "the current folder's rows show")
        session.folderScope = { nil }
        session.search("report")
        await waitUntil { session.state == .ready && session.results.first?.id == "/Users/test/report" }
    }

    static func coalescesQueuedQueries() async {
        let probe = FileSearchProbe(pausing: "a")
        let session = makeSession(probe: probe)
        session.search("a")
        guard await probe.waitUntilPaused() else { return expect(false, "the first query starts") }
        session.search("an")
        session.search("annual")
        await probe.resumePausedSearch()
        await waitUntil { session.state == .ready && session.results.first?.name == "annual" }

        let snapshot = await probe.snapshot()
        expect(snapshot.calls == ["a", "annual"], "keystrokes queued behind a search collapse")
    }

    static func serializesRunningQueries() async {
        let probe = FileSearchProbe(pausing: "first")
        let session = makeSession(probe: probe)
        session.search("first")
        let firstStarted = await probe.waitUntilPaused()
        expect(firstStarted, "the first query starts")
        guard firstStarted else { return }
        session.search("second")
        await probe.resumePausedSearch()
        await waitUntil { session.state == .ready && session.results.first?.name == "second" }

        let snapshot = await probe.snapshot()
        expect(snapshot.calls == ["first", "second"], "the superseding query still runs")
        expect(snapshot.maximumActive == 1, "searches never overlap")
    }

    static func cancellationPreventsPendingWork() async {
        let probe = FileSearchProbe(pausing: "running")
        let session = makeSession(probe: probe)
        session.search("running")
        guard await probe.waitUntilPaused() else { return expect(false, "the query starts") }
        session.search("queued")
        session.cancel()
        await probe.resumePausedSearch()
        try? await Task.sleep(for: .milliseconds(60))

        let snapshot = await probe.snapshot()
        expect(snapshot.calls == ["running"], "cancelling drops the queued search")
        expect(snapshot.cancelled == ["running"], "cancellation reaches the running search operation")
        expect(session.state == .idle && session.results.isEmpty, "cancellation clears the session")
    }

    static func idleCancellationKeepsTheSessionUsable() async {
        let probe = FileSearchProbe()
        let session = makeSession(probe: probe)
        session.cancel()
        expect(session.state == .idle && session.results.isEmpty, "an idle cancel changes nothing")
        session.search("report")
        await waitUntil { session.state == .ready && session.results.first?.name == "report" }
        session.cancel()
        session.cancel()
        expect(session.state == .idle && session.results.isEmpty, "a repeated cancel stays idle")
        session.search("report")
        await waitUntil { session.state == .ready && session.results.first?.name == "report" }

        let snapshot = await probe.snapshot()
        expect(snapshot.calls == ["report", "report"], "a cancelled query runs again when retyped")
    }

    static func refreshRerunsThePublishedQuery() async {
        let probe = FileSearchProbe()
        let session = makeSession(probe: probe)
        session.refresh()
        session.search("report")
        await waitUntil { session.state == .ready }
        session.refresh()
        await waitUntil { session.state == .ready }
        try? await Task.sleep(for: .milliseconds(20))

        let snapshot = await probe.snapshot()
        expect(
            snapshot.calls.sorted() == ["", "", "report", "report"],
            "an idle session prepares recents, and an open one re-asks its query and refreshes them")
    }

    static func blankScreenOpensOnKeptRecents() async {
        let probe = FileSearchProbe()
        let session = makeSession(probe: probe)
        session.refresh()
        try? await Task.sleep(for: .milliseconds(150))
        session.search("")
        expect(
            session.state == .ready && !session.results.isEmpty,
            "prepared recents show before any search returns")
        await waitUntil { session.state == .ready }
        session.cancel()
        session.search("")
        expect(!session.results.isEmpty, "recents survive the palette closing")
        session.search("report")
        expect(
            session.results.first?.name != "report",
            "a typed query still waits for its own results")
    }

    static func recentRefreshLeavesTheOpenListAlone() async {
        let probe = FileSearchProbe()
        let session = makeSession(probe: probe)
        session.search("report")
        await waitUntil { session.state == .ready }
        session.refreshRecent()
        try? await Task.sleep(for: .milliseconds(150))
        expect(session.results.first?.name == "report", "a Recent refresh leaves the open list alone")
        session.cancel()
        session.search("")
        expect(!session.results.isEmpty, "the next blank screen opens on the refreshed rows")
    }

    static func blankQueryLoadsRecents() async {
        let probe = FileSearchProbe()
        let session = makeSession(probe: probe)
        session.search("")
        await waitUntil { session.state == .ready }
        session.search("report")
        await waitUntil { session.state == .ready && session.results.first?.name == "report" }

        let snapshot = await probe.snapshot()
        expect(
            snapshot.calls == ["", "report"],
            "the blank screen is a request of its own, not the absence of one")
    }

    static func filterChangeRerunsTheQuery() async {
        let probe = FileSearchProbe()
        let session = makeSession(probe: probe)
        session.search("report")
        await waitUntil { session.state == .ready }
        session.search("report", filter: .images)
        await waitUntil { session.state == .ready }
        session.search("report", filter: .images)
        try? await Task.sleep(for: .milliseconds(40))

        let snapshot = await probe.snapshot()
        expect(
            snapshot.calls == ["report", "report [Images]"],
            "narrowing the filter re-runs the same words, and re-stating it runs nothing")
    }

    static func makeSession(probe: FileSearchProbe) -> FileSearchSession {
        FileSearchSession { query, filter, folder in
            await probe.search(query: query, filter: filter, folder: folder)
        }
    }

    static func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        expect(condition(), "the async operation completed before the timeout")
    }
}
