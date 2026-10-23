import Foundation

@MainActor
private final class LookupProbe {
    var calls: [String] = []

    func entry(_ term: String) async -> DictionaryEntry? {
        calls.append(term)
        return term == "mango" ? DictionaryEntry(term: term, plainText: "a fruit") : nil
    }
}

@main
@MainActor
struct DictionarySessionTests {
    static var failures = 0

    static func expect(_ condition: Bool, _ message: String) {
        if !condition { failures += 1; print("FAIL: \(message)") }
    }

    static func wait(until condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        expect(condition(), "asynchronous operation finishes")
    }

    static func main() async {
        expect(!DictionarySuggestions.accepts("a"), "single letters get no suggestions")
        expect(!DictionarySuggestions.accepts(String(repeating: "a", count: 129)), "bounded request")
        expect(!DictionarySuggestions.accepts("two words"), "phrases get no suggestions")
        expect(!DictionarySuggestions.accepts("123"), "numbers get no suggestions")
        expect(DictionarySuggestions.accepts("café"), "Unicode words are supported")
        expect(DictionarySuggestions.accepts("can't"), "apostrophes are supported")
        expect(
            DictionarySuggestions.words(
                from: [" Reconize ", " Recognize \n", "recognize", "", "recognise", "two words"],
                for: "reconize") == ["Recognize", "recognise"],
            "echoes, duplicates, blanks and phrases drop out; the checker's order stays")
        expect(
            DictionarySuggestions.words(from: (0..<20).map { "word\($0)" }, for: "query").count == 8,
            "the list is bounded")

        let probe = LookupProbe()
        var suggestionQueries: [String] = []
        let session = DictionarySession(
            findEntry: { await probe.entry($0) },
            findSuggestions: { term in
                suggestionQueries.append(term)
                return ["recognize", "recognise"]
            })
        session.lookUp("r")
        session.lookUp(" reconize \n")
        await wait { session.lookup?.term == "reconize" }
        expect(probe.calls == ["reconize"], "typing is debounced and trimmed")
        expect(session.lookup?.suggestions == ["recognize", "recognise"], "a miss publishes suggestions")
        session.lookUp("mango")
        await wait { session.lookup?.term == "mango" }
        expect(session.lookup?.entry?.term == "mango", "a hit shows its definition")
        expect(session.lookup?.suggestions == [], "a hit carries no suggestions")
        expect(suggestionQueries == ["reconize"], "a hit never reaches the spell checker")

        session.lookUp("zzzxqv")
        session.reset()
        try? await Task.sleep(for: .milliseconds(150))
        expect(session.lookup == nil, "reset prevents late publication")

        let empty = DictionarySession(findEntry: { _ in nil }, findSuggestions: { _ in [] })
        empty.lookUp("zzzxqv")
        await wait { empty.lookup?.term == "zzzxqv" }
        expect(
            empty.lookup?.entry == nil && empty.lookup?.suggestions == [],
            "no definition and no candidates leave a completed empty result")

        print("Dictionary session tests: \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
