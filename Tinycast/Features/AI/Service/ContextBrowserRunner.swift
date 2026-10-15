import AppKit
import Foundation

/// AppleScript against the supported browsers, off-main, returning Sendable values.
enum ContextBrowserRunner {
    /// Every tab of every normal window, front to back, plus whether the front window is private.
    struct TabList: Sendable {
        let browser: ContextBrowser.Browser
        let tabs: [ContextBrowser.BrowserTab]
        let frontIsPrivate: Bool
    }

    /// Never launches a browser to ask it: only running ones are candidates.
    static func targetBrowser(preferred: String?) -> ContextBrowser.Browser? {
        let running = NSWorkspace.shared.runningApplications.compactMap {
            $0.isTerminated ? nil : $0.bundleIdentifier
        }
        return ContextBrowser.target(preferred: preferred, running: running)
    }

    private static func isRunning(_ bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleID && !$0.isTerminated
        }
    }

    /// Every tab of every normal window, front to back; private windows never listed.
    static func listTabs(
        preferredBundleID: String?
    ) async -> Result<TabList, ContextBrowser.ReadFailure> {
        guard !Task.isCancelled, let browser = targetBrowser(preferred: preferredBundleID) else {
            return .failure(.noSource)
        }
        let rows = await runList(script: listScript(for: browser), browser: browser)
        switch rows {
        case .failure(let failure): return .failure(failure)
        case .success(let rows):
            return .success(
                TabList(
                    browser: browser,
                    tabs: ContextBrowser.tabs(from: rows, bundleID: browser.bundleID),
                    frontIsPrivate: ContextBrowser.frontIsPrivate(rows: rows)))
        }
    }

    /// Reads one listed tab; a moved tab is stale, never substituted.
    static func readTab(
        _ tab: ContextBrowser.BrowserTab
    ) async -> Result<ContextBrowser.PageRead, ContextBrowser.ReadFailure> {
        guard !Task.isCancelled, let browser = ContextBrowser.browser(bundleID: tab.bundleID),
            isRunning(browser.bundleID)
        else { return .failure(.noSource) }
        guard let script = readScript(for: browser, tab: tab) else { return .failure(.staleTab) }
        let result = await runScalar(script: script, browser: browser)
        switch result {
        case .failure(let failure): return .failure(failure)
        case .success(let text):
            if text == "NOTFOUND" || text.isEmpty { return .failure(.staleTab) }
            if text == "INCOGNITO" { return .failure(.restrictedPage) }
            if text == "LOADING" { return .failure(.loading) }
            guard let read = ContextBrowser.parsePageRead(text) else {
                return .failure(.restrictedPage)
            }
            guard ContextBrowser.verified(read, expectedURL: tab.url) else {
                return .failure(.staleTab)
            }
            let hasText =
                !read.selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !read.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard hasText else { return .failure(.empty) }
            return .success(read)
        }
    }

    private static func listScript(for browser: ContextBrowser.Browser) -> String {
        let app = ContextBrowser.appleScriptLiteral(browser.bundleID)
        switch browser.family {
        case .chromium:
            return """
                with timeout of \(ContextBrowser.captureTimeoutSeconds) seconds
                tell application id \(app)
                set out to {}
                repeat with w in windows
                set wmode to mode of w
                set wid to (id of w) as text
                if wmode is "incognito" then
                set end of out to {"", wid, "0", "", "", wmode}
                else
                try
                set activeID to (id of active tab of w) as text
                on error
                set activeID to ""
                end try
                repeat with t in tabs of w
                set tid to (id of t) as text
                if tid is activeID then
                set flag to "1"
                else
                set flag to "0"
                end if
                set end of out to {tid, wid, flag, title of t, URL of t, wmode}
                end repeat
                end if
                end repeat
                return out
                end tell
                end timeout
                """
        case .safari:
            return """
                with timeout of \(ContextBrowser.captureTimeoutSeconds) seconds
                tell application id \(app)
                set out to {}
                repeat with w in windows
                try
                set wid to (id of w) as text
                set cur to index of current tab of w
                repeat with t in tabs of w
                try
                set ti to index of t
                if ti is cur then
                set flag to "1"
                else
                set flag to "0"
                end if
                set end of out to {ti as text, wid, flag, name of t, URL of t, "normal"}
                end try
                end repeat
                end try
                end repeat
                return out
                end tell
                end timeout
                """
        }
    }

    /// Safari has no tab id, so its read re-checks the URL at that index before running anything.
    private static func readScript(
        for browser: ContextBrowser.Browser, tab: ContextBrowser.BrowserTab
    ) -> String? {
        let app = ContextBrowser.appleScriptLiteral(browser.bundleID)
        let tid = ContextBrowser.appleScriptLiteral(tab.id)
        let wid = ContextBrowser.appleScriptLiteral(tab.windowID)
        let url = ContextBrowser.appleScriptLiteral(tab.url)
        let js = ContextBrowser.appleScriptLiteral(ContextBrowser.readerJavaScript)
        switch browser.family {
        case .chromium:
            return """
                with timeout of \(ContextBrowser.captureTimeoutSeconds) seconds
                tell application id \(app)
                repeat with w in windows
                if ((id of w) as text) is \(wid) then
                if mode of w is "incognito" then return "INCOGNITO"
                repeat with t in tabs of w
                if ((id of t) as text) is \(tid) then
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
        case .safari:
            guard let index = Int(tab.id), index > 0 else { return nil }
            return """
                with timeout of \(ContextBrowser.captureTimeoutSeconds) seconds
                tell application id \(app)
                repeat with w in windows
                if ((id of w) as text) is \(wid) then
                if (count of tabs of w) < \(index) then return "NOTFOUND"
                set t to tab \(index) of w
                if (URL of t) is not \(url) then return "NOTFOUND"
                return do JavaScript \(js) in t
                end if
                end repeat
                return "NOTFOUND"
                end tell
                end timeout
                """
        }
    }

    @concurrent private static func runScalar(
        script: String, browser: ContextBrowser.Browser
    ) async -> Result<String, ContextBrowser.ReadFailure> {
        guard !Task.isCancelled, let compiled = NSAppleScript(source: script) else {
            return .failure(.noSource)
        }
        guard !Task.isCancelled else { return .failure(.noSource) }
        var errorInfo: NSDictionary?
        let result = compiled.executeAndReturnError(&errorInfo)
        guard !Task.isCancelled else { return .failure(.noSource) }
        if let errorInfo { return .failure(mapError(errorInfo, browser: browser)) }
        return .success(result.stringValue ?? "")
    }

    @concurrent private static func runList(
        script: String, browser: ContextBrowser.Browser
    ) async -> Result<[[String]], ContextBrowser.ReadFailure> {
        guard !Task.isCancelled, let compiled = NSAppleScript(source: script) else {
            return .failure(.noSource)
        }
        guard !Task.isCancelled else { return .failure(.noSource) }
        var errorInfo: NSDictionary?
        let result = compiled.executeAndReturnError(&errorInfo)
        guard !Task.isCancelled else { return .failure(.noSource) }
        if let errorInfo { return .failure(mapError(errorInfo, browser: browser)) }
        var rows: [[String]] = []
        let rowCount = result.numberOfItems
        if rowCount > 0 {
            for index in 1...rowCount {
                guard !Task.isCancelled else { return .failure(.noSource) }
                guard let row = result.atIndex(index) else { continue }
                var fields: [String] = []
                let fieldCount = row.numberOfItems
                if fieldCount > 0 {
                    for field in 1...fieldCount {
                        fields.append(row.atIndex(field)?.stringValue ?? "")
                    }
                }
                rows.append(fields)
            }
        }
        return .success(rows)
    }

    /// Descriptors never cross the await; only strings and the mapped failure do.
    static func mapError(
        _ errorInfo: NSDictionary, browser: ContextBrowser.Browser
    ) -> ContextBrowser.ReadFailure {
        ContextBrowser.failure(
            errorNumber: errorInfo[NSAppleScript.errorNumber] as? Int,
            message: errorInfo[NSAppleScript.errorMessage] as? String ?? "", browser: browser)
    }
}
