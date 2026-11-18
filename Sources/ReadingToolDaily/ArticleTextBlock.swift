import Foundation

/// Presentation metadata reconstructed from Markdown, never persisted in the archive.
struct ArticleTextBlock: Equatable {
    enum Kind: Equatable {
        case title
        case lead
        case heading(Int)
        case paragraph
        case list
        case listItem(depth: Int)
        case quote
        case literal
        case license
    }

    let range: NSRange
    let kind: Kind
}
