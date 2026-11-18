import Foundation

/// A selection and the surrounding sentences used to explain or translate it.
/// All ranges use the same UTF-16 offsets as NSTextView.
struct SelectionContext: Equatable, Sendable {
    let selectedText: String
    let context: String
    let focusedSentence: String
    let translationContext: String
    let selectedSentenceCount: Int
    let coversCompleteSentence: Bool

    var askAIPurpose: AIExplanationPurpose {
        if selectedSentenceCount > 1 || coversCompleteSentence { return .translation }

        let visibleCharacters = selectedText.filter { !$0.isWhitespace }.count
        let words = selectedText.split(whereSeparator: \.isWhitespace).count
        let hasCJK = selectedText.unicodeScalars.contains { scalar in
            (0x2E80...0x9FFF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
                || (0x3040...0x30FF).contains(scalar.value)
                || (0xAC00...0xD7AF).contains(scalar.value)
        }
        if hasCJK ? visibleCharacters >= 35 : (visibleCharacters >= 80 || words >= 12) {
            return .translation
        }
        return .lookup
    }

    /// Recover legacy card context only from its exact anchor, never a same-spelling search.
    static func focusedSentence(from text: String, scalarStart: Int, scalarEnd: Int,
                                expectedSelection: String, articleTitle: String? = nil) -> String? {
        let scalars = text.unicodeScalars
        guard scalarStart >= 0, scalarEnd > scalarStart, scalarEnd <= scalars.count else { return nil }
        let lower = scalars.index(scalars.startIndex, offsetBy: scalarStart)
        let upper = scalars.index(scalars.startIndex, offsetBy: scalarEnd)
        guard String(scalars[lower..<upper]) == expectedSelection,
              let lowerIndex = String.Index(lower, within: text),
              let upperIndex = String.Index(upper, within: text) else { return nil }
        return try? extract(from: text, range: NSRange(lowerIndex..<upperIndex, in: text),
                            articleTitle: articleTitle).focusedSentence
    }

    static func extract(from text: String, range: NSRange,
                        articleTitle: String? = nil) throws -> SelectionContext {
        let source = text as NSString
        guard range.location != NSNotFound, range.location >= 0, range.length > 0,
              range.location <= source.length, range.length <= source.length - range.location,
              Range(range, in: text) != nil,
              NSEqualRanges(source.rangeOfComposedCharacterSequences(for: range), range) else {
            throw SelectionContextError.invalidRange
        }
        let selectedText = source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        guard selectedText.contains(where: { $0.isLetter || $0.isNumber }) else {
            throw SelectionContextError.emptySelection
        }

        let sentences = sentenceRanges(in: text, articleTitle: articleTitle)
        let selectedIndices = sentences.indices.filter {
            NSIntersectionRange(sentences[$0], range).length > 0
        }
        guard let first = selectedIndices.first, let last = selectedIndices.last else {
            throw SelectionContextError.outsideBody
        }

        func joinedSentences(_ indices: ClosedRange<Int>) -> String {
            indices.map { source.substring(with: sentences[$0]) }.joined(separator: " ")
        }

        let previousSentence = first > 0 ? source.substring(with: sentences[first - 1]) : nil
        let nextSentence = last + 1 < sentences.count ? source.substring(with: sentences[last + 1]) : nil
        let selectionEnd = NSMaxRange(range)
        let coversCompleteSentence = selectedIndices.contains { index in
            let sentence = sentences[index]
            let beforeLength = max(0, min(range.location, NSMaxRange(sentence)) - sentence.location)
            let afterStart = min(selectionEnd, NSMaxRange(sentence))
            let afterLength = max(0, NSMaxRange(sentence) - afterStart)
            let before = source.substring(with: NSRange(location: sentence.location, length: beforeLength))
            let after = source.substring(with: NSRange(location: afterStart, length: afterLength))
            return before.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).contains($0) }
                && after.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).contains($0) }
        }

        return SelectionContext(
            selectedText: selectedText,
            context: joinedSentences(max(0, first - 1)...min(sentences.count - 1, last + 1)),
            focusedSentence: joinedSentences(first...last),
            translationContext: [previousSentence, nextSentence].compactMap { $0 }.joined(separator: " "),
            selectedSentenceCount: selectedIndices.count,
            coversCompleteSentence: coversCompleteSentence
        )
    }

    static func sentenceRanges(in text: String, articleTitle: String?) -> [NSRange] {
        let source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        let paragraphBreak = try! NSRegularExpression(pattern: "(?:\\r\\n|\\r|\\n)[\\t ]*(?:\\r\\n|\\r|\\n)+")
        let boundaries = paragraphBreak.matches(in: text, range: fullRange).map(\.range)
        var paragraphs: [NSRange] = []
        var start = 0
        for boundary in boundaries {
            paragraphs.append(NSRange(location: start, length: boundary.location - start))
            start = NSMaxRange(boundary)
        }
        paragraphs.append(NSRange(location: start, length: source.length - start))

        var result: [NSRange] = []
        var isFirstContentBlock = true
        for rawParagraph in paragraphs {
            var paragraphRange = trimmed(rawParagraph, in: source)
            guard paragraphRange.length > 0 else { continue }
            let paragraph = source.substring(with: paragraphRange)
            let isTitle = isFirstContentBlock && articleTitle.map {
                paragraph == $0.trimmingCharacters(in: .whitespacesAndNewlines)
            } == true
            isFirstContentBlock = false
            if isTitle || paragraph.range(of: "^#{1,6}\\s+", options: .regularExpression) != nil {
                continue
            }

            // IELTS passages use both separate "A" blocks and "A The …" prefixes.
            // Keep those paragraph labels out of the explanation sent to the service.
            if paragraph.range(of: "^[A-Z][.)]?$", options: .regularExpression) != nil { continue }
            if let label = paragraph.range(
                of: "^[A-Z](?:[.)])?(?:[\\t ]+(?=\\p{Lu})|[\\t ]*(?:\\r\\n|\\r|\\n))",
                options: .regularExpression
            ) {
                let labelLength = NSRange(label, in: paragraph).length
                paragraphRange = trimmed(NSRange(location: paragraphRange.location + labelLength,
                                                 length: paragraphRange.length - labelLength), in: source)
            }
            guard paragraphRange.length > 0 else { continue }
            let body = source.substring(with: paragraphRange)
            var paragraphSentences: [NSRange] = []
            body.enumerateSubstrings(in: body.startIndex..<body.endIndex, options: .bySentences) {
                _, substringRange, _, _ in
                let local = NSRange(substringRange, in: body)
                let sentence = trimmed(NSRange(location: paragraphRange.location + local.location,
                                                length: local.length), in: source)
                guard sentence.length > 0 else { return }
                if let previous = paragraphSentences.last,
                   shouldJoin(previous: source.substring(with: previous),
                              next: source.substring(with: sentence)) {
                    paragraphSentences[paragraphSentences.count - 1] = NSUnionRange(previous, sentence)
                } else {
                    paragraphSentences.append(sentence)
                }
            }
            result.append(contentsOf: paragraphSentences)
        }
        return result
    }

    /// Foundation can split titles and initials ("Dr. J. Smith") into separate
    /// sentences. Repair those boundaries while retaining the original offsets.
    private static func shouldJoin(previous: String, next: String) -> Bool {
        guard let nextCharacter = next.first(where: { $0.isLetter || $0.isNumber }) else { return false }
        if previous.range(
            of: "(?:^|\\s)(?:Mr|Mrs|Ms|Dr|Prof|Rev|Fr|Sr|Jr|St|Mt|Gen|Col|Lt|Capt|Sgt|Hon|Pres|Gov|Sen|Rep)\\.$",
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return true
        }
        if nextCharacter.isUppercase,
           previous.range(of: "(?:^|\\s)[A-Z]\\.$", options: .regularExpression) != nil {
            return true
        }
        if previous.range(of: "(?:^|\\s)(?:e\\.g|i\\.e|vs)\\.$",
                          options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        if nextCharacter.isLowercase,
           previous.range(of: "(?:(?:[A-Za-z]\\.){2,}|\\betc\\.)$",
                          options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        // A period separating numbers is a decimal point, not a sentence end.
        return nextCharacter.isNumber && previous.range(of: "[0-9]\\.$", options: .regularExpression) != nil
    }

    private static func trimmed(_ range: NSRange, in source: NSString) -> NSRange {
        let value = source.substring(with: range)
        guard let content = value.rangeOfCharacter(from: .whitespacesAndNewlines.inverted),
              let lastContent = value.rangeOfCharacter(from: .whitespacesAndNewlines.inverted,
                                                       options: .backwards) else {
            return NSRange(location: range.location, length: 0)
        }
        let local = NSRange(content.lowerBound..<lastContent.upperBound, in: value)
        return NSRange(location: range.location + local.location, length: local.length)
    }
}

enum SelectionContextError: LocalizedError {
    case invalidRange
    case emptySelection
    case outsideBody

    var errorDescription: String? {
        switch self {
        case .invalidRange:
            return L("选中的文字位置无效，请重新选择一个词或词组。", "The selection is invalid. Select a word or phrase again.")
        case .emptySelection:
            return L("请先选中一个词或词组。", "Select a word or phrase first.")
        case .outsideBody:
            return L("请选中文章正文中的词或词组。", "Select a word or phrase in the article body.")
        }
    }
}
