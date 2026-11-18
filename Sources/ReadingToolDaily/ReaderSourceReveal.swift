import AppKit

/// A new request identifies an intentional source jump, separately from restoring reading progress.
struct ReaderSourceReveal: Equatable {
    let id = UUID()
    let articleID: UUID
    let start: Int
    let end: Int
    let selectedText: String
    private let isDetached: Bool

    init(card: StudyCard) {
        articleID = card.articleID
        start = card.start
        end = card.end
        selectedText = card.selectedText
        isDetached = card.isDetached == true
    }

    func range(in article: LibraryArticle) -> NSRange? {
        let scalars = article.text.unicodeScalars
        guard articleID == article.id, !isDetached,
              start >= 0, end > start, end <= scalars.count else { return nil }
        let lower = scalars.index(scalars.startIndex, offsetBy: start)
        let upper = scalars.index(scalars.startIndex, offsetBy: end)
        guard String(scalars[lower..<upper]) == selectedText else { return nil }
        return NSRange(lower..<upper, in: article.text)
    }

    static func lineRects(for range: NSRange, layoutManager: NSLayoutManager,
                          textContainer: NSTextContainer, origin: NSPoint) -> [NSRect] {
        guard range.location != NSNotFound, range.location >= 0, range.length > 0,
              let textLength = layoutManager.textStorage?.length,
              range.location <= textLength, range.length <= textLength - range.location else { return [] }
        layoutManager.ensureLayout(for: textContainer)
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return [] }
        var rects: [NSRect] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, _, _ in
            let rect = lineRect.offsetBy(dx: origin.x, dy: origin.y)
            if !rects.contains(where: { abs($0.minY - rect.minY) < 0.5 }) {
                rects.append(rect)
            }
        }
        return rects
    }

    static func centeredScrollY(lineRects: [NSRect], documentHeight: CGFloat,
                                viewportHeight: CGFloat) -> CGFloat {
        let maximumY = max(0, documentHeight - viewportHeight)
        guard let first = lineRects.first else { return 0 }
        let selectionTop = lineRects.map(\.minY).min() ?? first.minY
        let selectionBottom = lineRects.map(\.maxY).max() ?? first.maxY
        let targetY: CGFloat
        if selectionBottom - selectionTop <= viewportHeight {
            targetY = (selectionTop + selectionBottom) / 2 - viewportHeight / 2
        } else {
            targetY = first.midY - viewportHeight / 2
        }
        return min(maximumY, max(0, targetY))
    }
}
