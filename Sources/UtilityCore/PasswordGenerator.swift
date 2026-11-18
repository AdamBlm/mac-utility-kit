import Foundation

public enum PasswordGenerator {
    public enum CharacterGroup: String, CaseIterable, Identifiable, Sendable {
        case lowercase = "Lowercase"
        case uppercase = "Uppercase"
        case digits = "Numbers"
        case symbols = "Symbols"

        public var id: Self { self }

        fileprivate var characters: String {
            switch self {
            case .lowercase: "abcdefghijklmnopqrstuvwxyz"
            case .uppercase: "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
            case .digits: "0123456789"
            case .symbols: "!@#$%^&*()-_=+[]{}:,.?"
            }
        }
    }

    public enum Separator: String, CaseIterable, Identifiable, Sendable {
        case hyphen = "-"
        case space = " "
        case underscore = "_"
        case period = "."

        public var id: Self { self }

        public var title: String {
            switch self {
            case .hyphen: "Hyphen"
            case .space: "Space"
            case .underscore: "Underscore"
            case .period: "Period"
            }
        }
    }

    public struct Generated: Sendable {
        public let value: String
        public let entropyBits: Double
    }

    public static func password(
        length: Int, groups: Set<CharacterGroup>, requiresEachGroup: Bool = true,
        excludesAmbiguous: Bool = false
    ) throws -> Generated {
        guard (4...128).contains(length), !groups.isEmpty else {
            throw ToolError.invalid("Choose 4 to 128 characters and at least one character group.")
        }
        let ambiguity = Set("IilLoO01")
        let pools = CharacterGroup.allCases.filter { groups.contains($0) }.map { group in
            Array(group.characters).filter { !excludesAmbiguous || !ambiguity.contains($0) }
        }
        let alphabet = pools.enumerated().flatMap { index, pool in pool.map { (character: $0, group: index) } }
        let allGroups = (1 << pools.count) - 1
        let entropy = requiresEachGroup
            ? groupedEntropy(length: length, poolSizes: pools.map(\.count))
            : Double(length) * log2(Double(alphabet.count))

        var random = SystemRandomNumberGenerator()
        // Rejection keeps every string satisfying the chosen constraints equally likely.
        for _ in 0..<20_000 {
            var present = 0
            var characters: [Character] = []
            for _ in 0..<length {
                let choice = alphabet[Int.random(in: alphabet.indices, using: &random)]
                present |= 1 << choice.group
                characters.append(choice.character)
            }
            if !requiresEachGroup || present == allGroups {
                return Generated(value: String(characters), entropyBits: entropy)
            }
        }
        throw ToolError.invalid("Could not generate a password with these constraints. Try a longer password.")
    }

    public static func passphrase(wordCount: Int, separator: Separator, capitalized: Bool) throws -> Generated {
        guard (3...16).contains(wordCount) else {
            throw ToolError.invalid("Choose 3 to 16 words.")
        }
        let source = try words.get()
        let wordlist = separator == .hyphen ? source.filter { !$0.contains("-") } : source
        var random = SystemRandomNumberGenerator()
        let selected = (0..<wordCount).map { _ in
            let word = wordlist[Int.random(in: wordlist.indices, using: &random)]
            return capitalized ? word.prefix(1).uppercased() + word.dropFirst() : word
        }
        return Generated(value: selected.joined(separator: separator.rawValue),
                         entropyBits: Double(wordCount) * log2(Double(wordlist.count)))
    }

    private static let words: Result<[String], ToolError> = {
        let name = "eff_large_wordlist"
        guard let source = Bundle.main.url(forResource: name, withExtension: "txt")
                ?? Bundle.module.url(forResource: name, withExtension: "txt"),
              let text = try? String(contentsOf: source, encoding: .utf8) else {
            return .failure(.invalid("The EFF word list is unavailable."))
        }
        let words = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let columns = line.split(separator: "\t")
            guard columns.count == 2, columns[1].utf8.allSatisfy({ (97...122).contains($0) || $0 == 45 }) else { return nil }
            return String(columns[1])
        }
        guard words.count == 7_776, Set(words).count == words.count else {
            return .failure(.invalid("The EFF word list could not be validated."))
        }
        return .success(words)
    }()

    private static func groupedEntropy(length: Int, poolSizes: [Int]) -> Double {
        let count = 1 << poolSizes.count
        var ways = Array(repeating: 0.0, count: count)
        ways[0] = 1
        for _ in 0..<length {
            var next = Array(repeating: 0.0, count: count)
            for mask in ways.indices where ways[mask] > 0 {
                for (group, size) in poolSizes.enumerated() {
                    next[mask | (1 << group)] += ways[mask] * Double(size)
                }
            }
            ways = next
        }
        return log2(ways[count - 1])
    }
}
