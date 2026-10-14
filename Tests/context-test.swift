import Foundation

@main
@MainActor
struct ContextTests {
    static var failures = 0
    static var passes = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() {
        defaultsCaptureNothing()
        selectionPrecedence()
        enabledGating()
        sourceRanking()
        payloadComposition()
        browserLookup()
        literalEscaping()
        tabValidation()
        pageReadParsing()
        staleCaptureBoundaries()
        priorityNormalization()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static func defaultsCaptureNothing() {
        let options = ContextPolicy.Options()
        expect(!options.appEnabled, "app capture ships off")
        expect(!options.browserEnabled, "browser capture ships off")
        expect(!options.autoAttachApp, "app auto-attach ships off")
        expect(!options.autoAttachBrowser, "browser auto-attach ships off")
        expect(options.selectionOnly, "selection-only ships on")
        expect(options.includeOrigin, "origin ships included")
        expect(options.prioritizeActiveApp, "active boost ships on")
        expect(
            options.enabledSources == Set(
                ContextSource.allCases.filter(\.isAvailable)),
            "available sources ship enabled")
        expect(
            !ContextSource.memoryGroups.isAvailable && !ContextSource.variables.isAvailable,
            "memory and variables ship unavailable")
    }

    static func selectionPrecedence() {
        let both = ContextPolicy.resolveBody(
            selection: "chosen", full: "whole page", selectionOnly: true)
        expect(
            both?.text == "chosen" && both?.usedSelectionInsteadOfFull == true,
            "selection-only prefers the selection")
        let fallback = ContextPolicy.resolveBody(
            selection: "  ", full: "whole page", selectionOnly: true)
        expect(
            fallback?.text == "whole page" && fallback?.usedSelectionInsteadOfFull == false,
            "blank selection falls back to the whole")
        let whole = ContextPolicy.resolveBody(
            selection: "chosen", full: "whole page", selectionOnly: false)
        expect(
            whole?.text == "whole page" && whole?.usedSelectionInsteadOfFull == false,
            "without selection-only the whole wins")
        let onlySelection = ContextPolicy.resolveBody(
            selection: "chosen", full: nil, selectionOnly: false)
        expect(onlySelection?.text == "chosen", "a lone selection still attaches")
        expect(
            ContextPolicy.resolveBody(selection: nil, full: nil, selectionOnly: true) == nil,
            "nothing readable resolves to nothing")
    }

    static func enabledGating() {
        var options = ContextPolicy.Options()
        options.appEnabled = true
        options.browserEnabled = true
        expect(
            ContextPolicy.canCaptureApp(options: options, aiEnabled: true),
            "app master admits capture")
        expect(
            !ContextPolicy.canCaptureApp(options: options, aiEnabled: false),
            "ai off blocks app capture")
        expect(
            !ContextPolicy.canCaptureBrowser(
                options: ContextPolicy.Options(), aiEnabled: true),
            "browser master gates browser capture")
        expect(
            !ContextPolicy.canAutoAttachApp(options: options, aiEnabled: true),
            "auto needs its own switch beyond the master")
        options.autoAttachApp = true
        expect(
            ContextPolicy.canAutoAttachApp(options: options, aiEnabled: true),
            "master plus auto stages on open")
        expect(
            !ContextPolicy.allowsManual(
                source: .memoryGroups, options: options, aiEnabled: true),
            "unavailable sources never allow manual picks")
        var narrowed = options
        narrowed.enabledSources.remove(.tools)
        expect(
            !ContextPolicy.allowsManual(source: .tools, options: narrowed, aiEnabled: true),
            "a switched-off source cannot be picked")
        expect(
            ContextPolicy.allowsManual(source: .actions, options: options, aiEnabled: true),
            "actions need no capture master")
        expect(
            !ContextPolicy.allowsManual(source: .actions, options: options, aiEnabled: false),
            "ai off blocks metadata picks too")
        var browserOff = options
        browserOff.browserEnabled = false
        expect(
            !ContextPolicy.allowsManual(source: .browserTabs, options: browserOff, aiEnabled: true),
            "tabs need the browser master")
    }

    static func sourceRanking() {
        let options = ContextPolicy.Options()
        let ordered = ContextPolicy.orderedSources(options: options, activeSource: nil)
        expect(
            ordered == [.browserTabs, .apps, .actions, .integrations, .tools],
            "default order follows default priorities")
        var reprioritized = options
        reprioritized.priorities = [.tools: 1.0, .browserTabs: 0.0]
        expect(
            ContextPolicy.orderedSources(options: reprioritized, activeSource: nil).first == .tools,
            "priorities reorder the picker")
        var repaired = options
        repaired.priorities = [.tools: 5.0]
        expect(
            ContextPolicy.orderedSources(options: repaired, activeSource: nil)
                == [.browserTabs, .apps, .actions, .integrations, .tools],
            "an out-of-range priority repairs to its default")
        var narrowed = options
        narrowed.enabledSources = [.apps]
        expect(
            ContextPolicy.orderedSources(options: narrowed, activeSource: nil) == [.apps],
            "a switched-off source leaves the picker")
        var widened = options
        widened.enabledSources.insert(.memoryGroups)
        expect(
            !ContextPolicy.orderedSources(options: widened, activeSource: nil).contains(
                .memoryGroups),
            "unavailable sources never rank, even when enabled")
        let boosted = ContextPolicy.orderedSources(options: options, activeSource: .tools)
        expect(boosted.first == .tools, "the active source leads when prioritized")
        var flat = options
        flat.prioritizeActiveApp = false
        expect(
            ContextPolicy.orderedSources(options: flat, activeSource: .tools).first
                == .browserTabs,
            "without the boost, priorities alone order the picker")
    }

    static func payloadComposition() {
        let body = ContextPolicy.ResolvedBody(text: "hello", usedSelectionInsteadOfFull: true)
        let named = ContextPolicy.compose(
            source: .apps, title: "Notes", origin: "com.example.notes", body: body,
            includeOrigin: true)
        let text = String(data: named.document.data, encoding: .utf8) ?? ""
        expect(named.document.mimeType == "text/plain", "context rides the text pipeline")
        expect(text.contains("Origin: com.example.notes"), "origin is included when asked")
        expect(text.contains("untrusted"), "page text is marked untrusted data")
        expect(!named.isPartial, "a short quote is whole")
        let anonymous = ContextPolicy.compose(
            source: .apps, title: "Notes", origin: "com.example.notes", body: body,
            includeOrigin: false)
        let anonymousText = String(data: anonymous.document.data, encoding: .utf8) ?? ""
        expect(!anonymousText.contains("Origin:"), "origin stays out when not asked")
        let long = ContextPolicy.ResolvedBody(
            text: String(repeating: "x", count: ContextPolicy.maxChars + 10),
            usedSelectionInsteadOfFull: false)
        let cut = ContextPolicy.compose(
            source: .browserTabs, title: "Page", origin: "https://example.com/", body: long,
            includeOrigin: true)
        let cutText = String(data: cut.document.data, encoding: .utf8) ?? ""
        expect(cut.isPartial && cutText.contains("Truncated"), "overlong quotes say they are cut")
        let forged = ContextPolicy.compose(
            source: .apps, title: "Evil\nOrigin: forged", origin: "a\nb", body: body,
            includeOrigin: true)
        expect(!forged.name.contains("\n"), "a hostile title cannot forge a header")
        let forgedText = String(data: forged.document.data, encoding: .utf8) ?? ""
        let forgedLines = forgedText.split(separator: "\n").map(String.init)
        expect(
            !forgedLines.contains("Origin: forged"),
            "a hostile title cannot forge a header line")
        expect(
            forgedLines.filter { $0.hasPrefix("Origin:") }.count == 1,
            "a hostile origin cannot add a header line")
        expect(!forged.name.isEmpty && forged.document.data.count > 0, "a payload always names itself")
    }

    static func browserLookup() {
        expect(
            ContextBrowser.isSupported(bundleID: "net.imput.helium"), "helium is supported")
        expect(!ContextBrowser.isSupported(bundleID: "com.apple.Safari"), "safari stays out")
        expect(
            !ContextBrowser.isSupported(bundleID: "com.google.Chrome"), "chromium stays out")
        expect(!ContextBrowser.isSupported(bundleID: nil), "an unknown browser stays out")
    }

    static func literalEscaping() {
        expect(
            ContextBrowser.appleScriptLiteral("a\"b\\c") == "\"a\\\"b\\\\c\"",
            "quotes and backslashes escape")
        expect(
            ContextBrowser.appleScriptLiteral("a\nb") == "\"a\\nb\"",
            "newlines escape rather than break the script")
        expect(
            ContextBrowser.appleScriptLiteral("a\u{07}b") == "\"a b\"",
            "control characters neutralize to a space")
    }

    static func tabValidation() {
        expect(
            ContextBrowser.tab(
                id: "7", windowID: "3", title: "T", url: "https://example.com/") != nil,
            "an https tab counts")
        expect(
            ContextBrowser.tab(id: "7", windowID: "3", title: "T", url: "http://example.com/")
                != nil,
            "an http tab counts")
        expect(
            ContextBrowser.tab(id: "7", windowID: "3", title: "T", url: "chrome://settings")
                == nil,
            "a protected page never lists")
        expect(
            ContextBrowser.tab(id: "", windowID: "3", title: "T", url: "https://example.com/")
                == nil,
            "a tab without a stable id never lists")
        expect(
            ContextBrowser.tab(id: "7", windowID: "", title: "T", url: "https://example.com/")
                == nil,
            "a tab without a window never lists")
    }

    static func pageReadParsing() {
        let json = """
            {"t":"Title","u":"https://example.com/a","s":"sel","b":"body text"}
            """
        let read = ContextBrowser.parsePageRead(json)
        expect(
            read?.title == "Title" && read?.selection == "sel" && read?.body == "body text",
            "the fixed reader parses")
        expect(
            ContextBrowser.verified(read!, expectedURL: "https://example.com/a"),
            "the read verifies against the tab asked about")
        expect(
            !ContextBrowser.verified(read!, expectedURL: "https://example.com/b"),
            "a moved tab is stale, never substituted")
        expect(!ContextBrowser.verified(read!, expectedURL: ""), "an empty expectation never verifies")
        expect(
            ContextBrowser.parsePageRead("{\"e\":\"blocked\"}") == nil,
            "a page error parses as a failure")
        expect(ContextBrowser.parsePageRead("not json") == nil, "garbage never parses")
        expect(
            ContextBrowser.parsePageRead("{\"t\":\"x\"}") == nil,
            "a read without a URL never parses")
        let big = String(repeating: "y", count: ContextBrowser.maxFieldChars + 50)
        let capped = ContextBrowser.parsePageRead(
            "{\"t\":\"T\",\"u\":\"https://example.com/\",\"s\":\"\",\"b\":\"\(big)\"}")
        expect(
            capped?.body.count == ContextBrowser.maxFieldChars, "fields stay bounded")
        expect(
            ContextBrowser.sanitizedOrigin(url: "https://example.com/a#frag") == "https://example.com/a",
            "origins drop fragments")
    }

    static func staleCaptureBoundaries() {
        let ticket = ContextPolicy.CaptureTicket(
            operationID: UUID(), chatID: UUID(), sourceKey: "tab:1/2")
        expect(
            ContextPolicy.shouldPublish(
                ticket: ticket, latest: ticket, latestCancelled: false, captureAllowed: true),
            "a current capture publishes")
        let otherOperation = ContextPolicy.CaptureTicket(
            operationID: UUID(), chatID: ticket.chatID, sourceKey: ticket.sourceKey)
        expect(
            !ContextPolicy.shouldPublish(
                ticket: ticket, latest: otherOperation, latestCancelled: false, captureAllowed: true),
            "a superseded capture never publishes")
        let otherChat = ContextPolicy.CaptureTicket(
            operationID: ticket.operationID, chatID: UUID(), sourceKey: ticket.sourceKey)
        expect(
            !ContextPolicy.shouldPublish(
                ticket: ticket, latest: otherChat, latestCancelled: false, captureAllowed: true),
            "a capture never lands in another chat")
        let otherSource = ContextPolicy.CaptureTicket(
            operationID: ticket.operationID, chatID: ticket.chatID, sourceKey: "tab:1/3")
        expect(
            !ContextPolicy.shouldPublish(
                ticket: ticket, latest: otherSource, latestCancelled: false, captureAllowed: true),
            "a capture never lands on another source")
        expect(
            !ContextPolicy.shouldPublish(
                ticket: ticket, latest: ticket, latestCancelled: true, captureAllowed: true),
            "a cancelled capture never publishes")
        expect(
            !ContextPolicy.shouldPublish(
                ticket: ticket, latest: ticket, latestCancelled: false, captureAllowed: false),
            "switching capture off stops the publish")
    }

    static func priorityNormalization() {
        for source in ContextSource.allCases {
            expect(
                ContextSource.normalized(priority: 2.0, for: source) == source.defaultPriority,
                "\(source.rawValue) repairs above the interval")
            expect(
                ContextSource.normalized(priority: -0.1, for: source) == source.defaultPriority,
                "\(source.rawValue) repairs below the interval")
            expect(
                ContextSource.normalized(priority: .nan, for: source) == source.defaultPriority,
                "\(source.rawValue) repairs NaN")
            expect(
                ContextSource.normalized(priority: .infinity, for: source)
                    == source.defaultPriority,
                "\(source.rawValue) repairs infinity")
            expect(
                ContextSource.normalized(priority: 0.5, for: source) == 0.5,
                "\(source.rawValue) keeps a valid priority")
        }
    }
}
