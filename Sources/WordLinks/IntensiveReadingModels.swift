import Foundation

struct IntensiveReadingSpan: Codable, Equatable, Sendable {
    let location: Int
    let length: Int

    var range: NSRange { NSRange(location: location, length: length) }

    func contains(_ index: Int) -> Bool {
        location <= index && index < location + length
    }

    func isValid(in text: String) -> Bool {
        location >= 0 && length > 0 && location <= (text as NSString).length &&
            length <= (text as NSString).length - location &&
            (text as NSString).rangeOfComposedCharacterSequences(for: range) == range
    }
}

struct IntensiveReadingAlignment: Codable, Equatable, Sendable {
    let sourceRanges: [IntensiveReadingSpan]
    let targetRanges: [IntensiveReadingSpan]

    func isValid(source: String, target: String) -> Bool {
        !sourceRanges.isEmpty && !targetRanges.isEmpty &&
            sourceRanges.allSatisfy { $0.isValid(in: source) } &&
            targetRanges.allSatisfy { $0.isValid(in: target) }
    }
}

enum IntensiveReadingHighlightRanges {
    static func mergingWhitespaceSeparated(_ ranges: [NSRange], in text: String) -> [NSRange] {
        let source = text as NSString
        let valid = ranges
            .filter { $0.location >= 0 && $0.length > 0 && NSMaxRange($0) <= source.length }
            .sorted { lhs, rhs in
                lhs.location == rhs.location ? lhs.length < rhs.length : lhs.location < rhs.location
            }

        var merged: [NSRange] = []
        for range in valid {
            guard let previous = merged.last else {
                merged.append(range)
                continue
            }

            let previousEnd = NSMaxRange(previous)
            if range.location <= previousEnd {
                merged[merged.count - 1] = NSUnionRange(previous, range)
                continue
            }

            let gap = source.substring(with: NSRange(location: previousEnd,
                                                     length: range.location - previousEnd))
            if gap.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) {
                merged[merged.count - 1] = NSUnionRange(previous, range)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}

struct IntensiveReadingTranslation: Codable, Equatable, Sendable {
    let sourceSentence: String
    let translation: String
    let alignments: [IntensiveReadingAlignment]
    let generatedAt: Date

    func isValid(for source: String) -> Bool {
        sourceSentence == source && !translation.isEmpty &&
            alignments.allSatisfy { $0.isValid(source: source, target: translation) }
    }
}

struct IntensiveReadingProgress: Equatable {
    let isGenerating: Bool
    let completedCount: Int
    let totalCount: Int
    let issue: String?

    var isComplete: Bool {
        !isGenerating && issue == nil && totalCount > 0 && completedCount >= totalCount
    }
}

enum IntensiveReadingToolbarState: Equatable {
    case inactive
    case loading
    case active

    init(isGenerating: Bool, isActivated: Bool) {
        if isGenerating {
            self = .loading
        } else {
            self = isActivated ? .active : .inactive
        }
    }
}

struct IntensiveReadingCacheEntry: Codable, Equatable, Sendable {
    let articleID: UUID
    let targetLanguage: StudyLanguage
    let result: IntensiveReadingTranslation
}

struct IntensiveReadingCacheFile: Codable, Equatable, Sendable {
    var version = 1
    var entries: [IntensiveReadingCacheEntry] = []
}

struct IntensiveReadingBatchInput: Encodable, Sendable {
    struct Word: Encodable, Sendable {
        let id: Int
        let text: String
    }

    let id: Int
    let source: String
    let words: [Word]
}

struct IntensiveReadingSuggestion: Decodable, Sendable {
    struct Link: Decodable, Sendable {
        let sourceWordIDs: [Int]
        let targetPhrases: [TargetPhrase]
    }

    struct TargetPhrase: Decodable, Equatable, Sendable {
        let text: String
        let occurrence: Int

        private enum CodingKeys: String, CodingKey {
            case text
            case occurrence
        }

        init(from decoder: Decoder) throws {
            if let value = try? decoder.singleValueContainer().decode(String.self) {
                text = value
                occurrence = 0
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            text = try container.decode(String.self, forKey: .text)
            occurrence = try container.decodeIfPresent(Int.self, forKey: .occurrence) ?? 0
        }
    }

    let id: Int
    let translation: String
    let links: [Link]
}

struct IntensiveReadingBatchResponse: Decodable, Sendable {
    let sentences: [IntensiveReadingSuggestion]

    static func decode(_ raw: String) throws -> IntensiveReadingBatchResponse {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: "^```(?:json)?\\s*|\\s*```$", with: "",
                                             options: .regularExpression)
        }
        guard let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first <= last else {
            throw AIError.invalidResponse
        }
        do {
            return try JSONDecoder().decode(Self.self, from: Data(text[first...last].utf8))
        } catch {
            throw AIError.invalidResponse
        }
    }
}

enum IntensiveReadingAlignmentBuilder {
    static func translation(source: String, suggestion: IntensiveReadingSuggestion) -> IntensiveReadingTranslation? {
        let translated = suggestion.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translated.isEmpty else { return nil }
        let sourceWords = wordRanges(in: source)
        let alignments = suggestion.links.compactMap { link -> IntensiveReadingAlignment? in
            let indexes = Array(Set(link.sourceWordIDs)).sorted()
            let sourceRanges = indexes.compactMap { index in
                sourceWords.indices.contains(index) ? sourceWords[index] : nil
            }
            let targetRanges = link.targetPhrases.compactMap { target -> IntensiveReadingSpan? in
                let phrase = target.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !phrase.isEmpty, target.occurrence >= 0 else { return nil }
                let occurrences = allRanges(of: phrase, in: translated)
                guard occurrences.indices.contains(target.occurrence) else { return nil }
                return occurrences[target.occurrence]
            }
            guard !sourceRanges.isEmpty, !targetRanges.isEmpty else { return nil }
            let result = IntensiveReadingAlignment(sourceRanges: sourceRanges, targetRanges: targetRanges)
            return result.isValid(source: source, target: translated) ? result : nil
        }
        return IntensiveReadingTranslation(sourceSentence: source, translation: translated,
                                           alignments: alignments, generatedAt: Date())
    }

    static func wordRanges(in text: String) -> [IntensiveReadingSpan] {
        var ranges: [IntensiveReadingSpan] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { _, range, _, _ in
            let value = NSRange(range, in: text)
            if value.length > 0 { ranges.append(IntensiveReadingSpan(location: value.location, length: value.length)) }
        }
        return ranges
    }

    private static func allRanges(of phrase: String, in text: String) -> [IntensiveReadingSpan] {
        guard !phrase.isEmpty else { return [] }
        let source = text as NSString
        var ranges: [IntensiveReadingSpan] = []
        var search = NSRange(location: 0, length: source.length)
        while search.length > 0 {
            let found = source.range(of: phrase, options: [], range: search)
            guard found.location != NSNotFound else { break }
            ranges.append(IntensiveReadingSpan(location: found.location, length: found.length))
            let next = found.location + max(1, found.length)
            search = NSRange(location: next, length: source.length - next)
        }
        return ranges
    }
}
