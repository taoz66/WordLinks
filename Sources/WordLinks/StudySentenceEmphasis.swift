import Foundation

/// Recover emphasis from the saved selection, independently of the edited expression.
enum StudySentenceEmphasis {
    static func ranges(in sentence: String, for card: StudyCard,
                       article: LibraryArticle? = nil) -> [Range<String.Index>] {
        let selection = card.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selection.isEmpty,
              let expression = try? NSRegularExpression(pattern: whitespaceFlexiblePattern(selection)) else {
            return []
        }
        let candidates = expression.matches(in: sentence, range: NSRange(sentence.startIndex..., in: sentence))
            .compactMap { Range($0.range, in: sentence) }
        guard !candidates.isEmpty else { return [] }

        // A valid source anchor distinguishes repeated occurrences in one sentence.
        if let article, let index = anchoredOccurrence(in: sentence, for: card, article: article,
                                                      selectionExpression: expression),
           candidates.indices.contains(index) {
            return [candidates[index]]
        }

        // Historical snapshots do not store the selection's relative offset. If their
        // source changed, emphasize only complete literal matches, never a word root.
        return candidates.filter { range in
            let startsInsideWord = selection.first.map(isWordCharacter) == true &&
                range.lowerBound > sentence.startIndex &&
                isWordCharacter(sentence[sentence.index(before: range.lowerBound)])
            let endsInsideWord = selection.last.map(isWordCharacter) == true &&
                range.upperBound < sentence.endIndex && isWordCharacter(sentence[range.upperBound])
            return !startsInsideWord && !endsInsideWord
        }
    }

    private static func anchoredOccurrence(in sentence: String, for card: StudyCard,
                                           article: LibraryArticle,
                                           selectionExpression: NSRegularExpression) -> Int? {
        let scalars = article.text.unicodeScalars
        guard card.isDetached != true, card.articleID == article.id,
              card.start >= 0, card.end > card.start, card.end <= scalars.count else { return nil }
        let lower = scalars.index(scalars.startIndex, offsetBy: card.start)
        let upper = scalars.index(scalars.startIndex, offsetBy: card.end)
        guard let start = String.Index(lower, within: article.text),
              let end = String.Index(upper, within: article.text),
              String(article.text[start..<end]) == card.selectedText else { return nil }
        let sourceSelection = card.selectedText as NSString
        let first = sourceSelection.rangeOfCharacter(from: .whitespacesAndNewlines.inverted)
        let last = sourceSelection.rangeOfCharacter(from: .whitespacesAndNewlines.inverted, options: .backwards)
        guard first.location != NSNotFound, last.location != NSNotFound,
              let sentenceExpression = try? NSRegularExpression(pattern: whitespaceFlexiblePattern(sentence)) else {
            return nil
        }
        let anchor = NSRange(location: NSRange(start..<end, in: article.text).location + first.location,
                             length: NSMaxRange(last) - first.location)
        for match in sentenceExpression.matches(in: article.text,
                                                range: NSRange(article.text.startIndex..., in: article.text))
            where match.range.location <= anchor.location && NSMaxRange(match.range) >= NSMaxRange(anchor) {
            let matches = selectionExpression.matches(in: article.text, range: match.range)
            if let index = matches.firstIndex(where: { NSEqualRanges($0.range, anchor) }) {
                return index
            }
        }
        return nil
    }

    private static func whitespaceFlexiblePattern(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "\\s+")
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}
