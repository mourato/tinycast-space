import Foundation

@main
struct EntryDeepLinkTest {
    static func main() {
        var failures = 0
        func check(_ description: String, _ condition: @autoclosure () -> Bool) {
            if condition() {
                print("PASS  \(description)")
            } else {
                print("FAIL  \(description)")
                failures += 1
            }
        }

        let ids = [
            "command:clipboard-history", "system-action:empty-trash",
            "window-command:left-half", "quicklink:4F2B0B9A-1111-2222-3333-444455556666",
            "/Applications/Visual Studio Code & Co+.app", "/System/Applications/Café ☕.app",
            "extension:raycast/spotify?x=1#frag",
        ]
        for id in ids {
            let url = EntryDeepLink.url(forEntryID: id)
            check("round-trips \(id)", url.flatMap(EntryDeepLink.entryID(from:)) == id)
            check("is one query item for \(id)", url?.absoluteString.filter { $0 == "?" }.count == 1)
        }
        check(
            "format",
            EntryDeepLink.url(forEntryID: "command:clipboard-history")?.absoluteString
                == "tinycast://open?id=command%3Aclipboard-history")
        check(
            "scheme and host are case-insensitive",
            EntryDeepLink.entryID(from: URL(string: "TinyCast://OPEN?id=command%3Asearch-emoji")!)
                == "command:search-emoji")
        check(
            "an empty id is no link",
            EntryDeepLink.entryID(from: URL(string: "tinycast://open?id=")!) == nil)
        check(
            "a missing id is no link",
            EntryDeepLink.entryID(from: URL(string: "tinycast://open")!) == nil)
        check(
            "another host is no link",
            EntryDeepLink.entryID(from: URL(string: "tinycast://quicklink?id=x")!) == nil)
        check(
            "another scheme is no link",
            EntryDeepLink.entryID(from: URL(string: "raycast://open?id=x")!) == nil)
        check(
            "extension link mirrors raycast's shape",
            EntryDeepLink.extensionURL(owner: "raycast", slug: "spotify-player", command: "search")?
                .absoluteString == "tinycast://extensions/raycast/spotify-player/search")
        check(
            "a scoped extension name keeps its last part",
            EntryDeepLink.extensionURL(owner: "o", slug: "o/ext", command: "c")?.absoluteString
                == "tinycast://extensions/o/ext/c")
        check(
            "an empty part builds no extension link",
            EntryDeepLink.extensionURL(owner: "", slug: "e", command: "c") == nil)

        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
