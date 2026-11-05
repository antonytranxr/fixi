import Foundation

/// A search for a listed item, never a claim that an individual product fits.
struct MendShoppingLink: Equatable {
    enum Kind: Equatable { case tool, part }

    let itemIndex: Int
    let title: String
    let kind: Kind
    let url: URL
}

enum MendShoppingLinks {
    /// Keep the same indices as the displayed tools + parts list. The plan schema
    /// allows at most twelve entries in each list; invalid extras get no links.
    static func make(tools: [String], parts: [String], confirmedProject: MendProjectDetails?) -> [MendShoppingLink] {
        let identity: [String] = confirmedProject.map { details in
            [("make", details.make), ("model", details.model)].compactMap { field, value in
                guard !details.suggestedFields.contains(field) else { return nil }
                return knownIdentity(value)
            }
        } ?? []

        let entries: [(Int, String, MendShoppingLink.Kind)] = tools.prefix(12).enumerated().map {
            ($0.offset, $0.element, .tool)
        } + parts.prefix(12).enumerated().map {
            (tools.count + $0.offset, $0.element, .part)
        }
        return entries.compactMap { index, rawTitle, kind in
            guard index < 24 else { return nil }
            let title = clean(rawTitle, limit: 160)
            guard !title.isEmpty, !isPlaceholder(title) else { return nil }
            var terms = [title]
            if kind == .part {
                for value in identity where !terms.contains(where: { containsPhrase($0, value) }) {
                    terms.append(value)
                }
            }
            var components = URLComponents()
            components.scheme = "https"
            components.host = "www.amazon.com"
            components.path = "/s"
            components.queryItems = [URLQueryItem(name: "k", value: terms.joined(separator: " "))]
            guard let url = components.url else { return nil }
            return MendShoppingLink(itemIndex: index, title: title, kind: kind, url: url)
        }
    }

    private static func knownIdentity(_ raw: String) -> String? {
        let value = clean(raw, limit: 160)
        return value.isEmpty || isPlaceholder(value) ? nil : value
    }

    private static func clean(_ raw: String, limit: Int) -> String {
        let printable = raw.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        return String(printable.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(limit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isPlaceholder(_ value: String) -> Bool {
        let normalized = value.lowercased().replacingOccurrences(of: "’", with: "'")
        return ["unknown", "n/a", "na", "none", "not needed", "not applicable", "not sure", "unsure", "unspecified",
                "unidentified", "generic", "other", "not known", "don't know", "i don't know", "i do not know"]
            .contains(normalized) || normalized.hasPrefix("unknown ") || normalized.hasPrefix("not known ")
    }

    private static func containsPhrase(_ text: String, _ phrase: String) -> Bool {
        let normalizedText = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let normalizedPhrase = phrase.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return (" " + normalizedText + " ").contains(" " + normalizedPhrase + " ")
    }
}
