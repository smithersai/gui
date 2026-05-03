import Foundation

enum ChatContentText {
    static func decoded(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let entities: [(String, String)] = [
            ("&quot;", "\""),
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&apos;", "'"),
            ("&#39;", "'"),
            ("&#x27;", "'"),
            ("&#34;", "\""),
            ("&#x22;", "\""),
            ("&nbsp;", " "),
        ]

        var result = text
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }
}
