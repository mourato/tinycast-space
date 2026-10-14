import Foundation

/// Helium's verifiable scripting surface: tab identities, one fixed reader, literal escaping. Pure.
enum ContextBrowser {
    static let heliumBundleID = "net.imput.helium"
    static let captureTimeoutSeconds = 8
    static let maxFieldChars = 8_000

    /// Only Helium ships a checked dictionary; other browsers stay out until theirs is verified.
    static func isSupported(bundleID: String?) -> Bool {
        bundleID == heliumBundleID
    }

    /// An AppleScript string literal: backslash and quote escaped, controls neutralized.
    static func appleScriptLiteral(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += " " } else { out.append(Character(scalar)) }
            }
        }
        out += "\""
        return out
    }

    /// One tab, as the list script reports it: stable ids first, human text after.
    struct BrowserTab: Equatable, Sendable, Identifiable {
        let id: String
        let windowID: String
        let title: String
        let url: String
        /// This window's selected tab, so the front window's pick is the active one.
        let isActive: Bool

        var identity: String { "\(id)" }
        var sourceKey: String { "tab:\(windowID)/\(id)" }
        var host: String? { URL(string: url)?.host }
    }

    /// A reported row counts only with stable ids and a readable page URL.
    static func tab(
        id: String, windowID: String, title: String, url: String, isActive: Bool = false
    ) -> BrowserTab? {
        guard !id.isEmpty, !windowID.isEmpty else { return nil }
        guard let scheme = URL(string: url)?.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else { return nil }
        return BrowserTab(id: id, windowID: windowID, title: title, url: url, isActive: isActive)
    }

    /// Listing rows into tabs: private windows never list, and short rows never count.
    static func tabs(from rows: [[String]]) -> [BrowserTab] {
        rows.compactMap { fields in
            guard fields.count >= 5 else { return nil }
            if fields.count >= 6, fields[5] == "incognito" { return nil }
            return tab(
                id: fields[0], windowID: fields[1], title: fields[3], url: fields[4],
                isActive: fields[2] == "1")
        }
    }

    /// True when the front window reported private, so auto-attach refuses rather than swapping.
    static func frontIsPrivate(rows: [[String]]) -> Bool {
        guard let first = rows.first, first.count >= 6 else { return false }
        return first[5] == "incognito"
    }

    /// Windows arrive front to back, so the first selected tab is the active one.
    static func activeTab(in tabs: [BrowserTab]) -> BrowserTab? {
        tabs.first { $0.isActive }
    }

    /// The page's own report: title, verified URL, selection and readable text, or its error.
    struct PageRead: Equatable, Sendable {
        let title: String
        let url: String
        let selection: String
        let body: String
        /// True when the fixed reader or the parser cut the text before staging saw it.
        let isTruncated: Bool
    }

    /// Parses the fixed reader's JSON; anything else is a restricted or failed page.
    static func parsePageRead(_ json: String) -> PageRead? {
        guard let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["e"] == nil,
            let url = object["u"] as? String, !url.isEmpty
        else { return nil }
        func capped(_ value: Any?) -> String {
            guard let text = value as? String else { return "" }
            return String(text.prefix(maxFieldChars))
        }
        func overlong(_ value: Any?) -> Bool {
            guard let text = value as? String else { return false }
            return text.count > maxFieldChars
        }
        let selection = capped(object["s"])
        let body = capped(object["b"])
        var cut = overlong(object["t"]) || overlong(object["s"]) || overlong(object["b"])
        if let reported = object["sl"] as? Int, reported > selection.count { cut = true }
        if let reported = object["bl"] as? Int, reported > body.count { cut = true }
        return PageRead(
            title: capped(object["t"]), url: url, selection: selection, body: body,
            isTruncated: cut)
    }

    /// The read counts only for the tab asked about; a moved tab is stale, never substituted.
    static func verified(_ read: PageRead, expectedURL: String) -> Bool {
        !expectedURL.isEmpty && read.url == expectedURL
    }

    /// What the composer may show for where the text came from; never credentials or fragments.
    static func sanitizedOrigin(url: String) -> String? {
        guard var components = URLComponents(string: url) else {
            return ContextPolicy.sanitizedOrigin(url)
        }
        components.fragment = nil
        components.user = nil
        components.password = nil
        components.query = nil
        guard let text = components.string, !text.isEmpty else {
            return ContextPolicy.sanitizedOrigin(url)
        }
        return ContextPolicy.sanitizedOrigin(text)
    }

    enum ReadFailure: Equatable, Sendable, Error {
        case automationDenied
        case timeout
        case noSource
        case loading
        case restrictedPage
        case staleTab
        case empty

        var message: String {
            switch self {
            case .automationDenied:
                return
                    "Allow Tinycast to control Helium in System Settings → Privacy & Security → Automation, then try again."
            case .timeout: return "Helium took too long to answer. Try again."
            case .noSource: return "There's no browser tab to attach right now."
            case .loading: return "That tab is still loading. Try again once it finishes."
            case .restrictedPage:
                return "That page doesn't allow reading (private window or protected page)."
            case .staleTab:
                return "That tab moved on — pick it again rather than sending the wrong page."
            case .empty: return "That tab has no readable text to attach."
            }
        }
    }

    /// The only JavaScript Tinycast runs in a page: title, URL, selection and readable text.
    static let readerJavaScript = """
        (function(){try{var s=window.getSelection?String(window.getSelection()):"";\
        var b=document.body?document.body.innerText:"";\
        return JSON.stringify({t:document.title,u:location.href,\
        s:s.slice(0,8000),b:(b||"").slice(0,8000),sl:s.length,bl:(b||"").length});}\
        catch(e){return JSON.stringify({e:String(e).slice(0,200)});}})()
        """
}
