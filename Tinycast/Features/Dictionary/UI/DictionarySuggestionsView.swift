import SwiftUI

/// The spellings offered when a word has no definition.
struct DictionarySuggestionsView: View {
    @Environment(\.metrics) private var metrics
    let words: [String]
    let selection: Int
    let scroll: ScrollIntent
    let onActivate: (String) -> Void

    private var selectedWord: String? {
        words.indices.contains(selection) ? words[selection] : nil
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    SectionHeader(title: String(localized: "Suggestions"), isFirst: true)
                    ForEach(words, id: \.self) { word in
                        DictionarySuggestionRow(word: word, selected: word == selectedWord)
                            .selectionFrame(word == selectedWord)
                            .contentShape(Rectangle())
                            .onTapGesture { onActivate(word) }
                    }
                }
                .padding(.horizontal, metrics.spacing.md)
                .padding(.top, metrics.spacing.xs)
                .padding(.bottom, metrics.spacing.md)
                .hideNativeScrollers()
                .scrollOriginAnchor()
            }
            .edgeDissolve()
            .thinScrollbar()
            .scrollFollowsSelection(
                scroll, row: selectedWord, atOrigin: selection == 0, proxy: proxy)
        }
    }
}

private struct DictionarySuggestionRow: View {
    @Environment(\.metrics) private var metrics
    let word: String
    let selected: Bool
    @State private var hovered = false

    private var fill: Color {
        if selected { return Theme.Colors.selection }
        if hovered { return Theme.Colors.rowHover }
        return .clear
    }

    var body: some View {
        IconCache.observeStyle()
        return HStack(spacing: metrics.spacing.lg) {
            Image(nsImage: IconCache.symbolIcon(named: "book"))
                .resizable()
                .frame(width: metrics.size.resultRowIcon, height: metrics.size.resultRowIcon)
            Text(word)
                .font(metrics.typography.rowTitle)
                .lineLimit(1)
            Spacer(minLength: metrics.spacing.md)
        }
        .padding(.horizontal, metrics.spacing.md)
        .padding(.vertical, metrics.spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous).fill(fill)
        )
        .armedHover($hovered)
    }
}
