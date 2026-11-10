import AppKit

enum Clipboard {
    static func copy(text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func copy(pngData: Data) {
        let pb = NSPasteboard.general
        pb.clearContents()

        var types: [NSPasteboard.PasteboardType] = [.png]
        var tiff: Data?
        if let image = NSImage(data: pngData), let data = image.tiffRepresentation {
            tiff = data
            types.append(.tiff)
        }
        pb.declareTypes(types, owner: nil)
        pb.setData(pngData, forType: .png)
        if let tiff {
            pb.setData(tiff, forType: .tiff)
        }
    }
}

enum LatexCleaner {
    /// Environments that exist only to align/split a display equation. Their
    /// wrapper is dropped and the body is flattened by `compact`.
    private static let displayEnvironments = [
        "align*", "align", "aligned", "alignat*", "alignat",
        "gather*", "gather", "gathered",
        "eqnarray*", "eqnarray", "split", "multline*", "multline",
        "equation*", "equation", "displaymath"
    ]

    /// Turns a multi-line aligned block into one compact expression:
    ///   \begin{align*} x_{1} &= x = x_{4} \end{align*}  ->  x_{1} = x = x_{4}
    ///   \begin{align*} a &= 1 \\ b &= 2 \end{align*}     ->  a = 1, b = 2
    /// Nested environments (pmatrix, cases, ...) are left untouched.
    static func compact(_ input: String) -> String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return s }

        // Unwrap a whole-string display environment, possibly nested.
        var unwrapped = true
        while unwrapped {
            unwrapped = false
            for env in displayEnvironments {
                let begin = "\\begin{\(env)}"
                let end = "\\end{\(env)}"
                guard s.hasPrefix(begin), s.hasSuffix(end),
                      s.count > begin.count + end.count else { continue }
                s = String(s.dropFirst(begin.count).dropLast(end.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                unwrapped = true
                break
            }
        }

        // Flatten alignment markers and row breaks, but only outside nested
        // environments so matrices/cases keep their structure.
        var out = ""
        var depth = 0
        var index = s.startIndex
        while index < s.endIndex {
            let rest = s[index...]
            if rest.hasPrefix("\\begin{") {
                depth += 1
                out += "\\begin{"
                index = s.index(index, offsetBy: 7)
            } else if rest.hasPrefix("\\end{") {
                depth = max(0, depth - 1)
                out += "\\end{"
                index = s.index(index, offsetBy: 5)
            } else if rest.hasPrefix("\\\\") && depth == 0 {
                out += ", "
                var next = s.index(index, offsetBy: 2)
                if next < s.endIndex, s[next] == "[", let close = s[next...].firstIndex(of: "]") {
                    next = s.index(after: close)
                }
                index = next
            } else if s[index] == "&" && depth == 0 {
                index = s.index(after: index)
            } else {
                out.append(s[index])
                index = s.index(after: index)
            }
        }

        out = out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: " ,", with: ",")
        out = out.replacingOccurrences(of: ", ,", with: ",")
        out = out.replacingOccurrences(of: ",,", with: ",")
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func clean(_ raw: String, compact compactOutput: Bool = true) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip markdown fences (```latex ... ```)
        if s.hasPrefix("```") {
            if let newline = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: newline)...])
            } else {
                s = ""
            }
            if let end = s.range(of: "```", options: .backwards) {
                s = String(s[..<end.lowerBound])
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Remove a leading "latex" / "tex" language hint
        for hint in ["latex\n", "tex\n"] where s.lowercased().hasPrefix(hint) {
            s = String(s.dropFirst(hint.count))
        }

        // Unwrap math delimiters, repeatedly.
        var changed = true
        while changed {
            changed = false
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            let pairs: [(String, String)] = [("$$", "$$"), ("\\[", "\\]"), ("\\(", "\\)")]
            for (open, close) in pairs
            where t.hasPrefix(open) && t.hasSuffix(close) && t.count > open.count + close.count {
                s = String(t.dropFirst(open.count).dropLast(close.count))
                changed = true
                break
            }
            if !changed {
                if t.hasPrefix("$") && t.hasSuffix("$") && t.count > 2 && !t.hasPrefix("$$") {
                    s = String(t.dropFirst().dropLast())
                    changed = true
                }
            }
        }

        let result = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return compactOutput ? compact(result) : result
    }
}
