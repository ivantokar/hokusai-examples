import SwiftUI

/// A small, dependency-free Swift highlighter for the code panel. It colours what the generated
/// snippets contain (keywords, types, `.method(` calls, strings, numbers, comments), nothing more.
enum SwiftHighlighter {
    private static let keywords: Set<String> = [
        "import", "let", "var", "func", "try", "await", "async", "return", "if", "else", "guard", "for", "in",
        "struct", "class", "enum", "extension", "static", "private", "public", "nil", "true", "false", "self",
        "throws", "throw", "do", "catch", "some", "any", "get", "set",
    ]

    static func attributed(_ code: String) -> AttributedString {
        var result = AttributedString()
        func add(_ text: Substring, _ color: Color?) {
            var piece = AttributedString(String(text))
            if let color { piece.foregroundColor = color }
            result.append(piece)
        }

        let chars = Array(code)
        var i = 0
        func isIdentStart(_ c: Character) -> Bool { c.isLetter || c == "_" }
        func isIdent(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

        while i < chars.count {
            let c = chars[i]
            let start = i
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {          // line comment
                while i < chars.count, chars[i] != "\n" { i += 1 }
                add(Substring(String(chars[start..<i])), .comment)
            } else if c == "\"" {                                            // string, with escapes
                i += 1
                while i < chars.count, chars[i] != "\"", chars[i] != "\n" {
                    if chars[i] == "\\", i + 1 < chars.count { i += 1 }
                    i += 1
                }
                if i < chars.count, chars[i] == "\"" { i += 1 }
                add(Substring(String(chars[start..<i])), .string)
            } else if c.isNumber {                                           // number
                while i < chars.count, chars[i].isNumber || chars[i] == "." || chars[i] == "_" { i += 1 }
                add(Substring(String(chars[start..<i])), .number)
            } else if isIdentStart(c) {                                      // identifier
                while i < chars.count, isIdent(chars[i]) { i += 1 }
                let word = String(chars[start..<i])
                let afterDot = start > 0 && chars[start - 1] == "."
                let isCall = i < chars.count && chars[i] == "("
                let color: Color? =
                    keywords.contains(word) ? .keyword
                    : word.first!.isUppercase ? .type
                    : (afterDot && isCall) ? .call
                    : nil
                add(Substring(word), color)
            } else {
                i += 1
                add(Substring(String(c)), nil)
            }
        }
        return result
    }
}

private extension Color {
    // Adaptive system colours, so the code stays readable in light and dark mode.
    static let keyword = Color(nsColor: .systemPink)
    static let type = Color(nsColor: .systemPurple)
    static let call = Color(nsColor: .systemTeal)
    static let string = Color(nsColor: .systemRed)
    static let number = Color(nsColor: .systemOrange)
    static let comment = Color(nsColor: .secondaryLabelColor)
}
