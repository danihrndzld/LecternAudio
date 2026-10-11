import Foundation

/// Converts Audible's summary HTML (p, br, i/em, b/strong, lists, entities) to Markdown.
/// Avoids NSAttributedString's HTML importer, which runs WebKit out of process and faults under the sandbox.
public enum HTMLText {
    public static func markdown(_ html: String) -> String {
        var s = html
        let rules: [(String, String)] = [
            ("(?i)<br\\s*/?>", "\n"),
            ("(?i)</p>|</div>|</ul>|</ol>", "\n\n"),
            ("(?i)<li[^>]*>", "\n- "),
            ("(?i)</?(b|strong)>", "**"),
            ("(?i)</?(i|em)>", "*"),
            ("<[^>]+>", ""),
            ("[ \\t]+", " "),
            (" *\\n *", "\n"),
            ("\\n{3,}", "\n\n"),
            ("\\*\\* \\*\\*|\\* \\*", " "),
        ]
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " ",
                        "&aacute;": "á", "&eacute;": "é", "&iacute;": "í", "&oacute;": "ó", "&uacute;": "ú", "&ntilde;": "ñ"]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
