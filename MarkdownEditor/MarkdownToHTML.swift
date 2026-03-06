import Foundation

enum MarkdownToHTML {

    static func convert(_ markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var html = ""
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                i += 1
                continue
            }

            // Fenced code block
            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                if lang.lowercased() == "mermaid" {
                    let source = codeLines.joined(separator: "\n")
                    if let diagram = MermaidParser.parse(source) {
                        let svg = MermaidRenderer.renderToSVG(diagram)
                        html += "<div style=\"text-align:center;margin:1.2em 0\">\(svg)</div>\n"
                        continue
                    }
                }
                let escaped = codeLines.map { escapeHTML($0) }.joined(separator: "\n")
                let langAttr = lang.isEmpty ? "" : " class=\"language-\(escapeHTML(lang))\""
                html += "<pre><code\(langAttr)>\(escaped)</code></pre>\n"
                continue
            }

            // ATX heading
            if let match = trimmed.range(of: #"^(#{1,6})\s+(.+)$"#, options: .regularExpression) {
                let hashEnd = trimmed[match].firstIndex(of: " ")!
                let level = trimmed.distance(from: trimmed.startIndex, to: hashEnd)
                let text = String(trimmed[trimmed.index(after: hashEnd)...])
                    .trimmingCharacters(in: .whitespaces)
                html += "<h\(level)>\(processInline(text))</h\(level)>\n"
                i += 1
                continue
            }

            // Horizontal rule
            if trimmed.range(of: #"^([-*_]\s*){3,}$"#, options: .regularExpression) != nil {
                html += "<hr>\n"
                i += 1
                continue
            }

            // Blockquote
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if l.hasPrefix("> ") {
                        quoteLines.append(String(l.dropFirst(2)))
                    } else if l.hasPrefix(">") {
                        quoteLines.append(String(l.dropFirst(1)))
                    } else if l.isEmpty {
                        break
                    } else if !quoteLines.isEmpty {
                        quoteLines.append(l)
                    } else {
                        break
                    }
                    i += 1
                }
                html += "<blockquote>\(convert(quoteLines.joined(separator: "\n")))</blockquote>\n"
                continue
            }

            // Unordered list
            if trimmed.range(of: #"^[-*+]\s"#, options: .regularExpression) != nil {
                html += "<ul>\n"
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if l.range(of: #"^[-*+]\s"#, options: .regularExpression) != nil {
                        html += "<li>\(processInline(String(l.dropFirst(2))))</li>\n"
                        i += 1
                    } else if l.isEmpty {
                        break
                    } else {
                        break
                    }
                }
                html += "</ul>\n"
                continue
            }

            // Ordered list
            if trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
                html += "<ol>\n"
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if let r = l.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                        html += "<li>\(processInline(String(l[r.upperBound...])))</li>\n"
                        i += 1
                    } else if l.isEmpty {
                        break
                    } else {
                        break
                    }
                }
                html += "</ol>\n"
                continue
            }

            // Table
            if trimmed.contains("|"),
               i + 1 < lines.count,
               lines[i + 1].trimmingCharacters(in: .whitespaces)
                   .range(of: #"^[\s|:\-]+$"#, options: .regularExpression) != nil {
                let headers = parseTableRow(trimmed)
                let alignments = parseAlignments(lines[i + 1])
                i += 2

                html += "<table>\n<thead>\n<tr>\n"
                for (j, h) in headers.enumerated() {
                    let align = j < alignments.count ? alignments[j] : ""
                    let attr = align.isEmpty ? "" : " style=\"text-align:\(align)\""
                    html += "<th\(attr)>\(processInline(h))</th>\n"
                }
                html += "</tr>\n</thead>\n<tbody>\n"

                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    guard l.contains("|"), !l.isEmpty else { break }
                    let cells = parseTableRow(l)
                    html += "<tr>\n"
                    for (j, c) in cells.enumerated() {
                        let align = j < alignments.count ? alignments[j] : ""
                        let attr = align.isEmpty ? "" : " style=\"text-align:\(align)\""
                        html += "<td\(attr)>\(processInline(c))</td>\n"
                    }
                    html += "</tr>\n"
                    i += 1
                }
                html += "</tbody>\n</table>\n"
                continue
            }

            // Paragraph
            var paraLines: [String] = []
            while i < lines.count {
                let l = lines[i]
                let t = l.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty,
                      !t.hasPrefix("#"),
                      !t.hasPrefix("```"),
                      !t.hasPrefix(">"),
                      t.range(of: #"^[-*+]\s"#, options: .regularExpression) == nil,
                      t.range(of: #"^\d+\.\s"#, options: .regularExpression) == nil,
                      t.range(of: #"^([-*_]\s*){3,}$"#, options: .regularExpression) == nil
                else { break }
                paraLines.append(t)
                i += 1
            }
            if !paraLines.isEmpty {
                html += "<p>\(processInline(paraLines.joined(separator: " ")))</p>\n"
            }
        }

        return html
    }

    // MARK: - Inline Processing

    private static func processInline(_ text: String) -> String {
        var result = escapeHTML(text)

        // Inline code (protect from further processing)
        var codeSpans: [String] = []
        if let regex = try? NSRegularExpression(pattern: "`([^`]+)`") {
            let nsText = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsText.length))
            for match in matches.reversed() {
                let codeContent = nsText.substring(with: match.range(at: 1))
                codeSpans.insert(codeContent, at: 0)
                let placeholder = "\u{FFFC}CODE\(codeSpans.count - 1)\u{FFFC}"
                result = (result as NSString).replacingCharacters(in: match.range, with: placeholder)
            }
        }

        // Images (before links)
        result = regexReplace(result, pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#) { groups in
            "<img src=\"\(sanitizeURL(groups[2]))\" alt=\"\(groups[1])\">"
        }

        // Links
        result = regexReplace(result, pattern: #"\[([^\]]+)\]\(([^)]+)\)"#) { groups in
            "<a href=\"\(sanitizeURL(groups[2]))\">\(groups[1])</a>"
        }

        // Bare URLs
        result = regexReplace(result, pattern: #"(?<![=\"'])https?://[^\s<\"]+"#) { groups in
            let url = sanitizeURL(groups[0])
            return "<a href=\"\(url)\">\(groups[0])</a>"
        }

        // Bold + Italic
        result = regexReplace(result, pattern: #"\*{3}(.+?)\*{3}"#) { groups in
            "<strong><em>\(groups[1])</em></strong>"
        }

        // Bold
        result = regexReplace(result, pattern: #"\*{2}(.+?)\*{2}"#) { groups in
            "<strong>\(groups[1])</strong>"
        }

        // Italic
        result = regexReplace(result, pattern: #"\*(.+?)\*"#) { groups in
            "<em>\(groups[1])</em>"
        }

        // Strikethrough
        result = regexReplace(result, pattern: #"~~(.+?)~~"#) { groups in
            "<del>\(groups[1])</del>"
        }

        // Restore code spans
        for (index, code) in codeSpans.enumerated() {
            result = result.replacingOccurrences(of: "\u{FFFC}CODE\(index)\u{FFFC}", with: "<code>\(code)</code>")
        }

        return result
    }

    // MARK: - Helpers

    private static func regexReplace(
        _ string: String,
        pattern: String,
        replacement: ([String]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return string }
        let nsString = string as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        var result = string
        let matches = regex.matches(in: string, range: fullRange)

        for match in matches.reversed() {
            var groups: [String] = []
            for g in 0..<match.numberOfRanges {
                let range = match.range(at: g)
                groups.append(range.location != NSNotFound ? nsString.substring(with: range) : "")
            }
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement(groups))
        }
        return result
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func sanitizeURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()

        if lowered.hasPrefix("javascript:") || lowered.hasPrefix("data:") {
            return "#"
        }

        return trimmed
    }

    private static func parseTableRow(_ line: String) -> [String] {
        line.split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func parseAlignments(_ line: String) -> [String] {
        parseTableRow(line).map { cell in
            let t = cell.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(":") && t.hasSuffix(":") { return "center" }
            if t.hasSuffix(":") { return "right" }
            if t.hasPrefix(":") { return "left" }
            return ""
        }
    }
}
