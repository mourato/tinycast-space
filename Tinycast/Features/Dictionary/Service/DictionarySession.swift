import Foundation

/// The dictionary screen's lookup: one term in flight, answered off the main actor.
@MainActor
@Observable
final class DictionarySession {
    struct Lookup: Equatable {
        let term: String
        /// Nil when no enabled dictionary knows the term.
        let entry: DictionaryEntry?
        /// Spellings to try instead, asked for only when `entry` is nil.
        let suggestions: [String]
    }

    /// The last answered lookup; it stays up while the next term resolves, so typing never blanks.
    private(set) var lookup: Lookup?
    @ObservationIgnored private var term = ""
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let findEntry: @Sendable (String) async -> DictionaryEntry?
    @ObservationIgnored private let findSuggestions: @MainActor (String) async -> [String]

    /// Coalesces a burst of keystrokes into the lookup for the word they settle on.
    private static let debounce = Duration.milliseconds(90)

    init(
        findEntry: @escaping @Sendable (String) async -> DictionaryEntry? = { term in
            await Task.detached(priority: .userInitiated) { DictionaryService.entry(for: term) }.value
        },
        findSuggestions: @escaping @MainActor (String) async -> [String] =
            DictionarySuggestionService.words
    ) {
        self.findEntry = findEntry
        self.findSuggestions = findSuggestions
    }

    func lookUp(_ query: String) {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term != self.term else { return }
        self.term = term
        task?.cancel()
        guard !term.isEmpty else {
            lookup = nil
            return
        }
        let findEntry = findEntry
        let findSuggestions = findSuggestions
        task = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            let entry = await findEntry(term)
            guard !Task.isCancelled else { return }
            let suggestions = entry == nil ? await findSuggestions(term) : []
            guard !Task.isCancelled, let self, self.term == term else { return }
            lookup = Lookup(term: term, entry: entry, suggestions: suggestions)
        }
    }

    func reset() {
        task?.cancel()
        task = nil
        term = ""
        lookup = nil
    }
}
