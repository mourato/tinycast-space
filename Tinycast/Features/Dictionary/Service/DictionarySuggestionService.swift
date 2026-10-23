import AppKit

/// Spelling candidates for a term the dictionaries lack. The checker is first touched here, on a
/// miss, so a launch or a lookup that succeeds never loads it.
@MainActor
enum DictionarySuggestionService {
    static func words(for term: String) async -> [String] {
        guard DictionarySuggestions.accepts(term), !Task.isCancelled else { return [] }
        let tag = NSSpellChecker.uniqueSpellDocumentTag()
        let range = NSRange(location: 0, length: term.utf16.count)
        let stream = AsyncStream<[String]>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.onTermination = { @Sendable _ in
                Task { @MainActor in NSSpellChecker.shared.closeSpellDocument(withTag: tag) }
            }
            // AppKit calls back off-main, so the completion must not inherit main-actor isolation.
            NSSpellChecker.shared.requestCandidates(
                forSelectedRange: range, in: term,
                types: NSTextCheckingResult.CheckingType.correction.rawValue,
                options: nil, inSpellDocumentWithTag: tag
            ) { @Sendable _, candidates in
                let words = candidates.compactMap { candidate in
                    candidate.range == range ? candidate.replacementString : nil
                }
                continuation.yield(DictionarySuggestions.words(from: words, for: term))
                continuation.finish()
            }
        }
        for await words in stream {
            return Task.isCancelled ? [] : words
        }
        return []
    }
}
