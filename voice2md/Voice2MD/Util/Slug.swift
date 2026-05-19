import Foundation

enum Slug {
    static func make(_ title: String, maxLen: Int = 60) -> String {
        var folded = title.lowercased()
        folded = folded.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))

        var chars: [Character] = []
        chars.reserveCapacity(folded.count)
        for c in folded {
            if c.isASCII, c.isLetter || c.isNumber {
                chars.append(c)
            } else {
                chars.append("-")
            }
        }
        var s = String(chars)

        while s.contains("--") {
            s = s.replacingOccurrences(of: "--", with: "-")
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        if s.count > maxLen {
            s = String(s.prefix(maxLen))
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
        return s.isEmpty ? "untitled" : s
    }
}
