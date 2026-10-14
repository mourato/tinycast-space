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
        return PageRead(
            title: capped(object["t"]), url: url, selection: capped(object["s"]),
            body: capped(object["b"]))
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
        s:s.slice(0,8000),b:(b||"").slice(0,8000)});}\
        catch(e){return JSON.stringify({e:String(e).slice(0,200)});}})()
        """
}
