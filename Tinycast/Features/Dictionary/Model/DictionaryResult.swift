import Foundation

/// What the dictionary screen lists: the one entry, or the spellings offered when there is none.
enum DictionaryResult: Identifiable, Sendable {
    case definition(DictionaryEntry)
    case suggestion(String)

    var id: String {
        switch self {
        case .definition(let entry): entry.term
        case .suggestion(let word): word
        }
    }
}

enum DictionarySuggestions {
    static let limit = 8

    /// Single words only: a phrase or a number has no spelling to correct.
    static func accepts(_ term: String) -> Bool {
        (2...128).contains(term.utf16.count)
            && !term.contains(where: \.isWhitespace)
            && term.unicodeScalars.contains(where: CharacterSet.letters.contains)
    }

    /// The checker's order is its ranking, so this only drops echoes, duplicates and phrases.
    static func words(from candidates: [String], for term: String) -> [String] {
        var seen: Set<String> = [term.lowercased()]
        var words: [String] = []
        for candidate in candidates {
            let word = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard accepts(word), seen.insert(word.lowercased()).inserted else { continue }
            words.append(word)
            if words.count == limit { break }
        }
        return words
    }
}
