import AppKit
import SwiftUI

func readerLinkAttributes(readingStyle: ReadingViewStyle) -> [NSAttributedString.Key: Any] {
    [.foregroundColor: readingStyle.readerAccent,
     .underlineStyle: NSUnderlineStyle.single.rawValue]
}

/// Apply visual attributes only. All selection and card ranges stay in the
/// canonical article string, including when a span is both bold and italic.
func styleReaderInline(_ text: NSMutableAttributedString, styles: [ArticleInlineStyle],
                       readingStyle: ReadingViewStyle, typography: ReadingTypography) {
    for style in styles where style.range.location >= 0 && style.range.length > 0 && NSMaxRange(style.range) <= text.length {
        switch style.kind {
        case .strong, .emphasis:
            let trait: NSFontTraitMask = style.kind == .strong ? .boldFontMask : .italicFontMask
            var changes: [(NSRange, NSFont)] = []
            text.enumerateAttribute(.font, in: style.range) { value, range, _ in
                let font = value as? NSFont ?? readingStyle.readerFont(size: typography.fontSize)
                changes.append((range, NSFontManager.shared.convert(font, toHaveTrait: trait)))
            }
            for (range, font) in changes { text.addAttribute(.font, value: font, range: range) }
        case .code:
            text.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: max(12, typography.fontSize - 1), weight: .regular),
                                .backgroundColor: readingStyle.readerForeground.withAlphaComponent(0.055)],
                               range: style.range)
        case .link(let url):
            guard let host = url.host, !host.isEmpty,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            var attributes = readerLinkAttributes(readingStyle: readingStyle)
            attributes[.link] = url
            text.addAttributes(attributes, range: style.range)
        }
    }
}
