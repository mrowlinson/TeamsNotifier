/// HTML-to-plain-text for Teams message bodies. Shape mirrors ost
/// strip_html and agent-messenger stripTags: drop tags, decode entities.
public enum HTML {
    public static func strip(_ html: String) -> String {
        var out = String()
        out.reserveCapacity(html.count)
        var inTag = false
        for ch in html {
            switch ch {
            case "<": inTag = true
            case ">": inTag = false
            default:
                if !inTag { out.append(ch) }
            }
        }
        return decodeEntities(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// <br>, <p>, <div>, <li> boundaries become newlines before stripping,
    /// so multi-line messages keep their shape in the notification body.
    public static func stripPreservingBreaks(_ html: String) -> String {
        var s = html
        let breaks = ["<br", "<br/", "<p", "<div", "<li", "</p>", "</div>", "</li>", "<tr", "</tr>"]
        // Insert newlines at block boundaries (case-insensitive, attribute-tolerant).
        for tag in breaks {
            s = s.replacingOccurrences(of: tag, with: "\n\(tag)", options: .caseInsensitive)
        }
        let stripped = strip(s)
        // Squeeze newline runs (</p><p> etc. each emit one).
        var collapsed = stripped
        while collapsed.contains("\n\n") {
            collapsed = collapsed.replacingOccurrences(of: "\n\n", with: "\n")
        }
        return collapsed
    }

    private static func decodeEntities(_ s: String) -> String {
        var r = s
        // Named entities Teams emits.
        let named: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "),
        ]
        for (e, c) in named { r = r.replacingOccurrences(of: e, with: c) }
        // Numeric entities (&#123; and &#x1F;), best-effort single pass.
        r = decodeNumericEntities(r)
        return r
    }

    private static func decodeNumericEntities(_ s: String) -> String {
        var out = String()
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", s[i...].hasPrefix("&#") {
                if let semi = s[i...].firstIndex(of: ";") {
                    let body = s[s.index(i, offsetBy: 2)..<semi]
                    var value: UInt32?
                    if body.hasPrefix("x") || body.hasPrefix("X") {
                        value = UInt32(body.dropFirst(), radix: 16)
                    } else {
                        value = UInt32(body, radix: 10)
                    }
                    if let v = value, let scalar = Unicode.Scalar(v) {
                        out.append(Character(scalar))
                        i = s.index(after: semi)
                        continue
                    }
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }
}
