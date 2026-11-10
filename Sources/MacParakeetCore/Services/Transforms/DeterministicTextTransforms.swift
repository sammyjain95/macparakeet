import Foundation

/// Tier 1 Command Mode transforms: deterministic, instant, no LLM, no hallucination risk.
/// Each transform operates on the selected text and returns the transformed text.
public enum DeterministicTextTransform: String, CaseIterable, Sendable, Codable {
    case bulletPoints
    case numberedList
    case uppercase
    case lowercase
    case titleCase
    case removeDuplicateLines
    case sortLines
    case normalizeWhitespace
    case markdownTableFromCSV

    public var displayName: String {
        switch self {
        case .bulletPoints: return "Convert to bullet points"
        case .numberedList: return "Convert to numbered list"
        case .uppercase: return "Uppercase"
        case .lowercase: return "Lowercase"
        case .titleCase: return "Title case"
        case .removeDuplicateLines: return "Remove duplicate lines"
        case .sortLines: return "Sort lines"
        case .normalizeWhitespace: return "Remove extra whitespace"
        case .markdownTableFromCSV: return "Make a Markdown table"
        }
    }

    public var triggerPhrases: [String] {
        switch self {
        case .bulletPoints:
            return ["bullet points", "bullets", "bullet list", "make bullets", "convert to bullets", "turn into bullets"]
        case .numberedList:
            return ["numbered list", "number list", "numbers", "make a numbered list", "convert to numbered list"]
        case .uppercase:
            return ["uppercase", "all caps", "make uppercase", "convert to uppercase", "capitalize all"]
        case .lowercase:
            return ["lowercase", "all lowercase", "make lowercase", "convert to lowercase"]
        case .titleCase:
            return ["title case", "capitalize words", "make title case", "titlecase"]
        case .removeDuplicateLines:
            return ["remove duplicate lines", "remove duplicates", "deduplicate lines", "unique lines"]
        case .sortLines:
            return ["sort lines", "sort", "alphabetize", "alphabetical order"]
        case .normalizeWhitespace:
            return ["remove extra whitespace", "fix whitespace", "clean whitespace", "fix line breaks", "normalize whitespace", "remove extra spaces"]
        case .markdownTableFromCSV:
            return ["markdown table", "make a table", "csv to table", "convert to table", "table from comma separated"]
        }
    }

    /// Match a spoken command transcript to a deterministic transform.
    /// Returns the best match if the command clearly requests a deterministic operation.
    public static func match(command: String) -> DeterministicTextTransform? {
        let normalized = command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)

        // Prefer longer/more specific phrases first
        let candidates = allCases.flatMap { transform in
            transform.triggerPhrases.map { (transform, $0) }
        }.sorted { $0.1.count > $1.1.count }

        for (transform, phrase) in candidates {
            if normalized.contains(phrase) {
                return transform
            }
        }
        return nil
    }
}

public enum DeterministicTextTransformer: Sendable {
    public static func apply(_ transform: DeterministicTextTransform, to text: String) -> String {
        switch transform {
        case .bulletPoints:
            return toBulletPoints(text)
        case .numberedList:
            return toNumberedList(text)
        case .uppercase:
            return text.uppercased()
        case .lowercase:
            return text.lowercased()
        case .titleCase:
            return toTitleCase(text)
        case .removeDuplicateLines:
            return removeDuplicateLines(text)
        case .sortLines:
            return sortLines(text)
        case .normalizeWhitespace:
            return normalizeWhitespace(text)
        case .markdownTableFromCSV:
            return markdownTableFromCSV(text)
        }
    }

    private static func nonEmptyLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func allLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
    }

    private static func stripListPrefix(_ line: String) -> String {
        var s = line
        // Strip common bullet prefixes
        let bulletPrefixes = ["- ", "* ", "• ", "· ", "– ", "— "]
        for prefix in bulletPrefixes where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
            return s.trimmingCharacters(in: .whitespaces)
        }
        // Strip numbered prefixes like "1. ", "1) ", "(1) "
        if let range = s.range(of: #"^\s*(?:\(\d+\)|\d+[.)])\s+"#, options: .regularExpression) {
            s.removeSubrange(range)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func toBulletPoints(_ text: String) -> String {
        let lines = nonEmptyLines(text)
        guard !lines.isEmpty else { return text }
        return lines.map { "- \(stripListPrefix($0))" }.joined(separator: "\n")
    }

    private static func toNumberedList(_ text: String) -> String {
        let lines = nonEmptyLines(text)
        guard !lines.isEmpty else { return text }
        return lines.enumerated().map { index, line in
            "\(index + 1). \(stripListPrefix(line))"
        }.joined(separator: "\n")
    }

    private static func toTitleCase(_ text: String) -> String {
        // Simple title case: capitalize first letter of each word, preserve existing all-caps words (acronyms)
        let words = text.components(separatedBy: .whitespacesAndNewlines)
        return words.map { word in
            guard !word.isEmpty else { return word }
            // Preserve acronyms (all uppercase, length > 1)
            if word.count > 1, word == word.uppercased(), word.rangeOfCharacter(from: .letters) != nil {
                return word
            }
            let lower = word.lowercased()
            guard let first = lower.first else { return word }
            return String(first).uppercased() + lower.dropFirst()
        }.joined(separator: " ")
    }

    private static func removeDuplicateLines(_ text: String) -> String {
        var seen = Set<String>()
        var result: [String] = []
        for line in allLines(text) {
            let key = line.trimmingCharacters(in: .whitespaces)
            if key.isEmpty {
                result.append(line)
                continue
            }
            if seen.insert(key).inserted {
                result.append(line)
            }
        }
        // Trim trailing empty lines produced by dedup
        while result.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            result.removeLast()
        }
        return result.joined(separator: "\n")
    }

    private static func sortLines(_ text: String) -> String {
        let lines = nonEmptyLines(text)
        guard !lines.isEmpty else { return text }
        return lines.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .joined(separator: "\n")
    }

    private static func normalizeWhitespace(_ text: String) -> String {
        // Collapse multiple spaces/tabs to single space, normalize line breaks
        var result = text.replacingOccurrences(of: "\r\n", with: "\n")
        result = result.replacingOccurrences(of: "\r", with: "\n")
        // Collapse runs of spaces/tabs within lines
        result = result.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        // Collapse 3+ newlines to 2
        result = result.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        // Trim trailing whitespace on each line
        result = result.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func markdownTableFromCSV(_ text: String) -> String {
        let lines = nonEmptyLines(text)
        guard !lines.isEmpty else { return text }

        let rows = lines.map { parseCSVLine($0) }
        guard let headerCount = rows.first?.count, headerCount > 0 else { return text }

        // Normalize all rows to header column count
        let normalizedRows = rows.map { row -> [String] in
            if row.count == headerCount { return row }
            if row.count < headerCount { return row + Array(repeating: "", count: headerCount - row.count) }
            return Array(row.prefix(headerCount))
        }

        let header = normalizedRows[0]
        let separator = Array(repeating: "---", count: headerCount)
        let body = Array(normalizedRows.dropFirst())

        func formatRow(_ cells: [String]) -> String {
            "| " + cells.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " | ") + " |"
        }

        var output = [formatRow(header), formatRow(separator)]
        output += body.map(formatRow)
        return output.joined(separator: "\n")
    }

    private static func parseCSVLine(_ line: String) -> [String] {
        // Simple CSV parser: split on commas, respect basic quoted fields
        var result: [String] = []
        var current = ""
        var inQuotes = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if inQuotes, i + 1 < chars.count, chars[i + 1] == "\"" {
                    current.append("\"")
                    i += 2
                    continue
                }
                inQuotes.toggle()
            } else if c == "," && !inQuotes {
                result.append(current)
                current = ""
            } else if c == "\t" && !inQuotes {
                // Also accept tab-separated
                result.append(current)
                current = ""
            } else {
                current.append(c)
            }
            i += 1
        }
        result.append(current)
        // If no commas found, try tab or multiple spaces as delimiter
        if result.count == 1, !line.contains(",") {
            if line.contains("\t") {
                return line.components(separatedBy: "\t")
            }
            // Try splitting on 2+ spaces for loosely formatted data
            let spaceSplit = line.components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if spaceSplit.count > 1 { return spaceSplit }
        }
        return result
    }
}
