import AppKit

/// The byline lives in the title's existing separator, leaving every source
/// character offset intact for cards, search and intensive-reading alignment.
@MainActor
final class ReaderArticleByline {
    private let label: NSTextField = {
        let field = NSTextField(wrappingLabelWithString: "")
        field.isSelectable = true
        field.allowsEditingTextAttributes = true
        field.drawsBackground = false
        field.isBordered = false
        field.maximumNumberOfLines = 0
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        return field
    }()
    private var title: String?
    private var metadata = ArticleMetadata()
    private var readingStyle: ReadingViewStyle = .standard
    private var typography = ReadingViewStyle.standard.defaultTypography
    private var isLayingOut = false
    private var measuredWidth: CGFloat?
    private var measuredHeight: CGFloat = 0
    private(set) var measurementCount = 0

    func update(in textView: NSTextView, title: String?, metadata: ArticleMetadata,
                readingStyle: ReadingViewStyle, typography: ReadingTypography) {
        let contentChanged = self.metadata != metadata || self.readingStyle != readingStyle || self.typography != typography
        self.title = title
        self.metadata = metadata
        self.readingStyle = readingStyle
        self.typography = typography
        if label.superview !== textView { textView.addSubview(label) }
        if contentChanged {
            label.attributedStringValue = attributedByline()
            measuredWidth = nil
        }
        layout(in: textView)
    }

    func layout(in textView: NSTextView) {
        guard !isLayingOut else { return }
        isLayingOut = true
        defer { isLayingOut = false }
        let source = textView.string as NSString
        guard let title, !title.isEmpty, source.hasPrefix(title + "\n\n"),
              let storage = textView.textStorage, let manager = textView.layoutManager,
              let container = textView.textContainer else {
            label.isHidden = true
            return
        }
        let separator = NSRange(location: (title as NSString).length + 1, length: 1)
        guard separator.location < storage.length else {
            label.isHidden = true
            return
        }
        let baseHeight = typography.paragraphSpacing + (readingStyle == .magazine ? 14 : 8)
        let hasByline = label.attributedStringValue.length > 0
        let padding = container.lineFragmentPadding
        let width = max(1, min(container.containerSize.width,
                               textView.bounds.width - 2 * textView.textContainerInset.width) - 2 * padding)
        if measuredWidth.map({ abs($0 - width) > 0.5 }) ?? true {
            let measured = label.attributedStringValue.boundingRect(
                with: NSSize(width: max(1, width - 4), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading])
            measuredWidth = width
            measuredHeight = ceil(measured.height) + 4
            measurementCount += 1
        }
        let height = measuredHeight
        let top: CGFloat = readingStyle == .magazine ? 16 : 8
        let gap = hasByline ? max(baseHeight, top + height + 18) : baseHeight
        let paragraph = (storage.attribute(.paragraphStyle, at: separator.location,
                                           effectiveRange: nil) as? NSParagraphStyle)?
            .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        if paragraph.minimumLineHeight != gap || paragraph.maximumLineHeight != gap {
            paragraph.minimumLineHeight = gap
            paragraph.maximumLineHeight = gap
            storage.addAttribute(.paragraphStyle, value: paragraph, range: separator)
        }
        label.isHidden = !hasByline
        guard hasByline else { return }
        // The byline only depends on the title's separator. Requiring the whole
        // article to lay out here would repeat that work throughout a resize.
        manager.ensureLayout(forCharacterRange: separator)
        let glyph = manager.glyphIndexForCharacter(at: separator.location)
        let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        label.frame = NSRect(x: textView.textContainerOrigin.x + padding - 2,
                             y: textView.textContainerOrigin.y + line.minY + top,
                             width: width + 4, height: height)
    }

    private func attributedByline() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 3
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(12, min(15, typography.fontSize - 3))),
            .foregroundColor: readingStyle.readerForeground.withAlphaComponent(0.62),
            .paragraphStyle: paragraph
        ]
        let result = NSMutableAttributedString(string: "")
        func append(_ value: String?, link: URL? = nil) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
            if result.length > 0 { result.append(NSAttributedString(string: "  ·  ", attributes: attributes)) }
            var itemAttributes = attributes
            if let link, ["https", "http"].contains(link.scheme?.lowercased() ?? ""),
               let host = link.host, !host.isEmpty {
                itemAttributes[.link] = link
                itemAttributes[.foregroundColor] = readingStyle.readerAccent
            }
            result.append(NSAttributedString(string: value, attributes: itemAttributes))
        }
        append(metadata.author)
        append(metadata.date)
        append(metadata.source, link: metadata.sourceURL)
        return result
    }
}
