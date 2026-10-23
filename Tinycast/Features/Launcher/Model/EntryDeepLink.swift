import Foundation

/// tinycast-space: `tinycast://open?id=<entry id>` runs one launcher entry, and `tinycast://extensions/…`
/// (Raycast's own link shape) runs an extension command. The id is the entry's stable `AppEntry.id`;
/// it is only ever looked up among the entries the launcher already lists, never executed as content.
enum EntryDeepLink {
    static let scheme = "tinycast"
    static let host = "open"

    /// Everything but unreserved characters, so an id's `/`, `&`, `+` and `:` survive a round trip.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func url(forEntryID id: String) -> URL? {
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            return nil
        }
        return URL(string: "\(scheme)://\(host)?id=\(encoded)")
    }

    /// The entry id of an `open` link, or nil for any other URL.
    static func entryID(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host,
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            let id = items.first(where: { $0.name == "id" })?.value, !id.isEmpty
        else { return nil }
        return id
    }

    /// `owner` and `slug` are the manifest's store handle and name; a scoped name keeps its last part.
    static func extensionURL(owner: String, slug: String, command: String) -> URL? {
        let parts = [owner, slug.split(separator: "/").last.map(String.init) ?? slug, command]
        let encoded = parts.compactMap { $0.addingPercentEncoding(withAllowedCharacters: unreserved) }
        guard encoded.count == 3, !parts.contains(where: \.isEmpty) else { return nil }
        return URL(string: "\(scheme)://extensions/" + encoded.joined(separator: "/"))
    }

    /// Polls until `condition` holds or `timeout` passes; false on timeout, or when cancelled.
    @MainActor
    static func waitUntil(
        timeout: Duration, interval: Duration = .milliseconds(10), _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline,
                (try? await Task.sleep(for: interval)) != nil
            else { return false }
        }
        return !Task.isCancelled
    }
}
