import Foundation
import Markdown

/// All presentation ranges refer to the same selectable text used by cards.
struct ArticleInlineStyle: Equatable {
    enum Kind: Equatable {
        case strong
        case emphasis
        case code
        case link(URL)
    }
    let range: NSRange
    let kind: Kind
}

struct ArticleMarkdownDocument {
    let title: String
    let text: String
    let metadata: ArticleMetadata
    let blocks: [ArticleTextBlock]
    let inlineStyles: [ArticleInlineStyle]

    static func parse(_ markdown: String) throws -> ArticleMarkdownDocument {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalizingChineseHeadings(in: normalized.hasPrefix("\u{FEFF}") ? String(normalized.dropFirst()) : normalized)
            .components(separatedBy: "\n")
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        guard let first = lines.first,
              first.range(of: "^ {0,3}#{1,2}(?:[ \\t]+.*)?$", options: .regularExpression) != nil,
              let heading = Document(parsing: first).child(at: 0) as? Heading,
              heading.level <= 2 else {
            throw ReadingLibraryError.invalidMarkdown
        }
        var index = 1
        var metadata = ArticleMetadata()
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { index += 1; continue }
            guard let field = ArticleHeaderField.parse(line) else { break }
            let key = field.key
            let value = field.value
            if !value.isEmpty {
                if ["author", "authors", "作者"].contains(key) {
                    if metadata.author == nil { metadata.author = value }
                } else if ["source", "来源"].contains(key) {
                    if metadata.source == nil {
                        let pair = metadataSource(value)
                        metadata.source = pair.0
                        metadata.sourceURL = pair.1
                    }
                } else if metadata.date == nil { metadata.date = value }
            }
            index += 1
        }
        var builder = Builder()
        builder.appendBlock(heading, kind: .title)
        let title = builder.text
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReadingLibraryError.invalidMarkdown
        }
        let body = lines.dropFirst(index).joined(separator: "\n")
        let document = Document(parsing: body)
        let lastPosition = document.childCount - 1
        for (position, child) in document.children.enumerated() {
            if position == lastPosition, let paragraph = child as? Paragraph {
                builder.appendLicenseOrParagraph(paragraph)
            } else {
                builder.append(child, depth: 0, quoteKind: position == 0 ? .lead : .quote)
            }
        }
        builder.detectBareLinks()
        return ArticleMarkdownDocument(title: title, text: builder.text, metadata: metadata,
                                       blocks: builder.blocks, inlineStyles: builder.styles)
    }

    /// Accept the compact Chinese heading used by the localized template.
    /// Keep stored Markdown untouched and preserve code/HTML as literal input.
    static func normalizingChineseHeadings(in markdown: String) -> String {
        let pattern = #"(?m)^( {0,3}#{1,6})(?=\p{Han})"#
        guard markdown.range(of: pattern, options: .regularExpression) != nil else { return markdown }
        var protectedLines = Set<Int>()
        func protectLiterals(_ node: any Markup) {
            if node is CodeBlock || node is InlineCode || node is HTMLBlock {
                if let range = node.range {
                    let lastLine = range.upperBound.line - (range.upperBound.column == 1 ? 1 : 0)
                    if lastLine >= range.lowerBound.line {
                        protectedLines.formUnion(range.lowerBound.line...lastLine)
                    }
                }
            } else {
                for child in node.children { protectLiterals(child) }
            }
        }
        protectLiterals(Document(parsing: markdown))
        return markdown.components(separatedBy: "\n").enumerated().map { index, line in
            protectedLines.contains(index + 1) ? line
                : line.replacingOccurrences(of: pattern, with: "$1 ", options: .regularExpression)
        }.joined(separator: "\n")
    }

    private static func metadataSource(_ value: String) -> (String, URL?) {
        let document = Document(parsing: value)
        guard document.childCount == 1,
              let paragraph = document.child(at: 0) as? Paragraph,
              paragraph.childCount == 1,
              let link = paragraph.child(at: 0) as? Link else {
            return (value, nil)
        }
        var builder = Builder()
        for child in link.children { builder.appendInline(child) }
        let label = builder.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return (value, nil) }
        return (label, link.destination.flatMap(webURL))
    }

    private static func webURL(_ value: String) -> URL? {
        guard let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    private struct Builder {
        var text = ""
        var blocks: [ArticleTextBlock] = []
        var styles: [ArticleInlineStyle] = []

        var length: Int { text.utf16.count }

        mutating func append(_ node: any Markup, depth: Int, quoteKind: ArticleTextBlock.Kind = .quote) {
            switch node {
            case let heading as Heading:
                appendBlock(heading, kind: .heading(heading.level))
            case let paragraph as Paragraph:
                appendBlock(paragraph, kind: .paragraph)
            case let quote as BlockQuote:
                for child in quote.children {
                    if child is Paragraph { appendBlock(child, kind: quoteKind) }
                    else { append(child, depth: depth + 1, quoteKind: .quote) }
                }
            case let list as OrderedList:
                for (index, item) in list.children.enumerated() {
                    appendListItem(item, marker: "\(list.startIndex + UInt(index)).", depth: depth)
                }
            case let list as UnorderedList:
                for item in list.children { appendListItem(item, marker: "•", depth: depth) }
            case let code as CodeBlock:
                appendLiteral(code.format().trimmingCharacters(in: .newlines))
            case let html as HTMLBlock:
                appendLiteral(html.rawHTML.trimmingCharacters(in: .newlines))
            case is ThematicBreak:
                appendLiteral("— — —")
            default:
                // Images, tables and other unsupported structures stay inspectable
                // as text. This is deliberately not a hidden deletion/cleaning pass.
                appendLiteral(node.format().trimmingCharacters(in: .newlines))
            }
        }

        mutating func appendListItem(_ node: any Markup, marker: String, depth: Int) {
            var isFirstParagraph = true
            for child in node.children {
                if child is Paragraph {
                    appendBlock(child, kind: .listItem(depth: depth), prefix: isFirstParagraph ? marker + "\t" : "")
                    isFirstParagraph = false
                } else {
                    append(child, depth: depth + 1)
                }
            }
        }

        mutating func beginBlock() -> Int {
            if !text.isEmpty { text += "\n\n" }
            return length
        }

        mutating func appendLicenseOrParagraph(_ paragraph: Paragraph) {
            appendBlock(paragraph, kind: .paragraph)
            guard let last = blocks.last else { return }
            let blockText = (text as NSString).substring(with: last.range)
            if blockText.range(of: #"^(?i)license[ \t]*[:：]"#, options: .regularExpression) != nil {
                blocks[blocks.count - 1] = ArticleTextBlock(range: last.range, kind: .license)
            }
        }

        mutating func appendBlock(_ node: any Markup, kind: ArticleTextBlock.Kind, prefix: String = "") {
            let start = beginBlock()
            text += prefix
            for child in node.children { appendInline(child) }
            let range = NSRange(location: start, length: length - start)
            if range.length > 0 { blocks.append(ArticleTextBlock(range: range, kind: kind)) }
        }

        mutating func appendLiteral(_ value: String) {
            guard !value.isEmpty else { return }
            let start = beginBlock()
            text += value
            blocks.append(ArticleTextBlock(range: NSRange(location: start, length: length - start), kind: .literal))
        }

        mutating func appendInline(_ node: any Markup) {
            let start = length
            var kind: ArticleInlineStyle.Kind?
            switch node {
            case let value as Text: text += value.string
            case is SoftBreak: text += " "
            case is LineBreak: text += "\n"
            case let value as InlineCode:
                text += value.code
                kind = .code
            case let value as InlineHTML: text += value.rawHTML
            case is Strong:
                for child in node.children { appendInline(child) }
                kind = .strong
            case is Emphasis:
                for child in node.children { appendInline(child) }
                kind = .emphasis
            case let link as Link:
                for child in link.children { appendInline(child) }
                if let target = link.destination, let url = ArticleMarkdownDocument.webURL(target) { kind = .link(url) }
            case let image as Markdown.Image:
                for child in image.children { appendInline(child) }
            default:
                text += node.format()
            }
            if let kind, length > start {
                styles.append(ArticleInlineStyle(range: NSRange(location: start, length: length - start), kind: kind))
            }
        }

        mutating func detectBareLinks() {
            guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
            let excluded = blocks.filter { $0.kind == .literal }.map(\.range) + styles.compactMap { style -> NSRange? in
                switch style.kind { case .code, .link: return style.range; default: return nil }
            }
            for match in detector.matches(in: text, range: NSRange(location: 0, length: length)) {
                guard let target = match.url, let url = ArticleMarkdownDocument.webURL(target.absoluteString),
                      !excluded.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
                styles.append(ArticleInlineStyle(range: match.range, kind: .link(url)))
            }
        }
    }
}
