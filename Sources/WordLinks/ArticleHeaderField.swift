import Foundation

/// The form importer and reader share the same optional header rules.
struct ArticleHeaderField {
    let key: String
    let value: String

    static func parse(_ line: String) -> ArticleHeaderField? {
        let pattern = #"(?i)^[ \t]*(author|authors|作者|date|日期|写作日期|发表日期|source|来源)[ \t]*[:：][ \t]*(.*?)[ \t]*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { return nil }
        let source = line as NSString
        let label = source.substring(with: match.range(at: 1)).lowercased()
        let key = ["author", "authors", "作者"].contains(label) ? "author"
            : (["source", "来源"].contains(label) ? "source" : "date")
        // Strip only the template's trailing optional hint. Parentheses in
        // names, dates, sources and article prose keep their original text.
        let value = source.substring(with: match.range(at: 2))
            .replacingOccurrences(of: #"(?i)[ \t]*(?:\(optional\)|（选填）)[ \t]*$"#,
                                  with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return ArticleHeaderField(key: key, value: value)
    }
}
