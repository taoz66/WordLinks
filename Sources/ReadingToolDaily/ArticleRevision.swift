import Foundation

/// Keeps scalar-based reading positions and card anchors when article text changes.
enum ArticleRevision {
    static func replace(_ article: LibraryArticle, markdown: String, title: String, text: String,
                        cards: [StudyCard]) -> (article: LibraryArticle, cards: [StudyCard]) {
        if article.text == text {
            // Header/formatting edits do not move positions or alter detached cards.
            let revised = LibraryArticle(id: article.id, title: title, sourceName: article.sourceName,
                                         sourceURL: article.sourceURL, markdown: markdown, text: text,
                                         folderID: article.folderID, readOffset: article.readOffset,
                                         createdAt: article.createdAt, sourceFilePath: article.sourceFilePath)
            return (revised, cards)
        }
        let oldScalars = Array(article.text.unicodeScalars)
        let newScalars = Array(text.unicodeScalars)
        let positions = scalarPositions(from: oldScalars, to: newScalars)

        var revised = LibraryArticle(id: article.id, title: title, sourceName: article.sourceName,
                                     sourceURL: article.sourceURL, markdown: markdown, text: text,
                                     folderID: article.folderID,
                                     readOffset: readingOffset(article.readOffset, positions: positions,
                                                               newCount: newScalars.count),
                                     createdAt: article.createdAt)
        revised.sourceFilePath = article.sourceFilePath

        // Reserve surviving anchors first, so a recovered card cannot displace one.
        var candidates: [Anchor] = []
        for (index, card) in cards.enumerated() where card.articleID == article.id {
            if card.isDetached != true,
               let range = survivingRange(for: card, oldScalars: oldScalars, positions: positions) {
                candidates.append(Anchor(index: index, range: range, recovered: false))
            } else if let range = uniqueRange(of: card.selectedText, in: newScalars) {
                candidates.append(Anchor(index: index, range: range, recovered: true))
            }
        }
        candidates.sort {
            if $0.recovered != $1.recovered { return !$0.recovered }
            return $0.index < $1.index
        }
        var accepted: [Int: Range<Int>] = [:]
        var occupied: [Range<Int>] = []
        for candidate in candidates where !occupied.contains(where: { $0.overlaps(candidate.range) }) {
            accepted[candidate.index] = candidate.range
            occupied.append(candidate.range)
        }

        let revisedCards = cards.enumerated().map { index, card -> StudyCard in
            guard card.articleID == article.id else { return card }
            var preserved = card
            // Capture recoverable legacy context before replacing the source text.
            // This happens during the existing write, with no separate migration.
            if preserved.originalSentence == nil, card.isDetached != true {
                preserved.originalSentence = SelectionContext.focusedSentence(from: article.text,
                    scalarStart: card.start, scalarEnd: card.end, expectedSelection: card.selectedText,
                    articleTitle: article.title)
            }
            guard let range = accepted[index] else {
                var detached = preserved
                detached.isDetached = true
                return detached
            }
            var anchored = StudyCard(id: card.id, articleID: card.articleID,
                                     start: range.lowerBound, end: range.upperBound,
                                     selectedText: scalarString(newScalars[range]),
                                     expression: card.expression, meaning: card.meaning,
                                     createdAt: card.createdAt, updatedAt: card.updatedAt,
                                     originalSentence: preserved.originalSentence)
            anchored.isDetached = card.isDetached == true ? nil : card.isDetached
            return anchored
        }
        return (revised, revisedCards)
    }

    private struct Anchor {
        let index: Int
        let range: Range<Int>
        let recovered: Bool
    }

    /// Each retained old scalar maps to its exact location in the new text.
    private static func scalarPositions(from old: [Unicode.Scalar],
                                        to new: [Unicode.Scalar]) -> [Int?] {
        // Case-only ASCII edits must not turn an otherwise intact title into a
        // deletion/insertion, especially when the same word occurs in its body.
        if old.count == new.count, zip(old, new).allSatisfy({ pair in
            if pair.0 == pair.1 { return true }
            let a = pair.0.value
            let b = pair.1.value
            let lowerA = (65...90).contains(a) ? a + 32 : a
            let lowerB = (65...90).contains(b) ? b + 32 : b
            return a < 128 && b < 128 && lowerA == lowerB
        }) {
            return old.indices.map { Optional($0) }
        }

        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var positions = [Int?](repeating: nil, count: old.count)
        var next = 0
        for index in old.indices where !removed.contains(index) {
            while inserted.contains(next) { next += 1 }
            if next < new.count { positions[index] = next }
            next += 1
        }
        return positions
    }

    private static func survivingRange(for card: StudyCard, oldScalars: [Unicode.Scalar],
                                       positions: [Int?]) -> Range<Int>? {
        guard card.start >= 0, card.end > card.start, card.end <= oldScalars.count,
              scalarString(oldScalars[card.start..<card.end]) == card.selectedText,
              let start = positions[card.start] else { return nil }
        // Every scalar must survive consecutively. Insertions inside a phrase or
        // partial deletions detach it rather than silently changing its meaning.
        for index in card.start..<card.end {
            guard positions[index] == start + index - card.start else { return nil }
        }
        return start..<(start + card.end - card.start)
    }

    /// Search all scalar positions, including overlapping occurrences. Ambiguous
    /// repeated expressions cannot be recovered from their spelling alone.
    private static func uniqueRange(of selection: String, in text: [Unicode.Scalar]) -> Range<Int>? {
        let needle = Array(selection.unicodeScalars)
        guard !needle.isEmpty, needle.count <= text.count else { return nil }
        var found: Range<Int>?
        for start in 0...(text.count - needle.count) where text[start] == needle[0] {
            let range = start..<(start + needle.count)
            if text[range].elementsEqual(needle) {
                guard found == nil else { return nil }
                found = range
            }
        }
        return found
    }

    private static func readingOffset(_ offset: Int, positions: [Int?], newCount: Int) -> Int {
        guard !positions.isEmpty else { return 0 }
        let oldOffset = min(max(offset, 0), positions.count)
        if oldOffset == positions.count { return newCount }
        for index in oldOffset..<positions.count {
            if let position = positions[index] { return min(position, newCount) }
        }
        if oldOffset > 0 {
            for index in (0..<oldOffset).reversed() {
                if let position = positions[index] { return min(position + 1, newCount) }
            }
        }
        return min(oldOffset, newCount)
    }

    private static func scalarString(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        String(String.UnicodeScalarView(scalars))
    }
}
