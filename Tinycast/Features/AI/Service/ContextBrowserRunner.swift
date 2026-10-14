import Foundation

/// AppleScript against Helium, off-main, returning Sendable values like SystemActionRunner.
enum ContextBrowserRunner {
    /// Every tab of every normal window, front to back; private windows never listed.
    static func listTabs() async -> Result<[ContextBrowser.BrowserTab], ContextBrowser.ReadFailure> {
        let rows = await runList(script: listScript())
        switch rows {
        case .failure(let failure): return .failure(failure)
        case .success(let rows):
            let tabs = rows.compactMap { fields -> ContextBrowser.BrowserTab? in
                guard fields.count >= 5 else { return nil }
                return ContextBrowser.tab(
                    id: fields[0], windowID: fields[1], title: fields[3], url: fields[4],
                    isActive: fields[2] == "1")
            }
            return .success(tabs)
        }
    }

    /// Reads one tab by its stable ids; a moved tab is stale, never substituted.
    static func readTab(
        id: String, windowID: String, expectedURL: String
    ) async -> Result<ContextBrowser.PageRead, ContextBrowser.ReadFailure> {
        let result = await runScalar(script: readScript(tabID: id, windowID: windowID))
        switch result {
        case .failure(let failure): return .failure(failure)
        case .success(let text):
            if text == "NOTFOUND" || text.isEmpty { return .failure(.staleTab) }
            if text == "INCOGNITO" { return .failure(.restrictedPage) }
            if text == "LOADING" { return .failure(.loading) }
            guard text.hasPrefix("{"), let read = ContextBrowser.parsePageRead(text) else {
                return .failure(.restrictedPage)
            }
            guard ContextBrowser.verified(read, expectedURL: expectedURL) else {
                return .failure(.staleTab)
            }
            let hasText =
                !read.selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !read.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard hasText else { return .failure(.empty) }
            return .success(read)
        }
    }

    private static func listScript() -> String {
        """
        with timeout of \(ContextBrowser.captureTimeoutSeconds) seconds
        tell application id \(ContextBrowser.appleScriptLiteral(ContextBrowser.heliumBundleID))
        set out to {}
        repeat with w in windows
        if mode of w is not "incognito" then
        try
        set activeID to id of active tab of w
        on error
        set activeID to ""
        end try
        set wid to id of w
        repeat with t in tabs of w
        set tid to id of t
        if tid is activeID then
        set flag to "1"
        else
        set flag to "0"
        end if
        set end of out to {tid, wid, flag, title of t, URL of t}
        end repeat
        end if
        end repeat
        return out
        end tell
        end timeout
        """
    }

    private static func readScript(tabID: String, windowID: String) -> String {
        let tid = ContextBrowser.appleScriptLiteral(tabID)
        let wid = ContextBrowser.appleScriptLiteral(windowID)
        let js = ContextBrowser.appleScriptLiteral(ContextBrowser.readerJavaScript)
        return """
            with timeout of \(ContextBrowser.captureTimeoutSeconds) seconds
            tell application id \(ContextBrowser.appleScriptLiteral(ContextBrowser.heliumBundleID))
            repeat with w in windows
            if id of w is \(wid) then
            if mode of w is "incognito" then return "INCOGNITO"
            repeat with t in tabs of w
            if id of t is \(tid) then
            if loading of t is true then return "LOADING"
            return execute t javascript \(js)
            end if
            end repeat
            end if
            end repeat
            return "NOTFOUND"
            end tell
            end timeout
            """
    }

    private static func runScalar(script: String) async -> Result<String, ContextBrowser.ReadFailure>
    {
        await Task.detached(priority: .userInitiated) {
            guard let compiled = NSAppleScript(source: script) else {
                return Result<String, ContextBrowser.ReadFailure>.failure(.noSource)
            }
            var errorInfo: NSDictionary?
            let result = compiled.executeAndReturnError(&errorInfo)
            if let errorInfo {
                return .failure(mapError(errorInfo))
            }
            return .success(result.stringValue ?? "")
        }.value
    }

    private static func runList(script: String) async -> Result<
        [[String]], ContextBrowser.ReadFailure
    > {
        await Task.detached(priority: .userInitiated) {
            guard let compiled = NSAppleScript(source: script) else {
                return Result<[[String]], ContextBrowser.ReadFailure>.failure(.noSource)
            }
            var errorInfo: NSDictionary?
            let result = compiled.executeAndReturnError(&errorInfo)
            if let errorInfo {
                return .failure(mapError(errorInfo))
            }
            var rows: [[String]] = []
            for index in 1...max(result.numberOfItems, 0) {
                guard let row = result.atIndex(index) else { continue }
                var fields: [String] = []
                for field in 1...max(row.numberOfItems, 0) {
                    fields.append(row.atIndex(field)?.stringValue ?? "")
                }
                rows.append(fields)
            }
            return .success(rows)
        }.value
    }

    /// Descriptors never cross the await; only strings and the mapped failure do.
    static func mapError(_ errorInfo: NSDictionary) -> ContextBrowser.ReadFailure {
        let number = errorInfo[NSAppleScript.errorNumber] as? Int
        if number == -1743 { return .automationDenied }
        if number == -1712 { return .timeout }
        let message = errorInfo[NSAppleScript.errorMessage] as? String ?? ""
        if number == -600 || message.contains("isn't running") || message.contains("not running") {
            return .noSource
        }
        return .restrictedPage
    }
}
