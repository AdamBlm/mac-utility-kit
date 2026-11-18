import Foundation
import Testing
import UtilityCore

struct PasswordGeneratorTests {
    @Test func passwordIncludesSelectedGroupsAndExcludesAmbiguousCharacters() throws {
        let groups = Set(PasswordGenerator.CharacterGroup.allCases)
        let output = try PasswordGenerator.password(length: 20, groups: groups, excludesAmbiguous: true)
        #expect(output.value.count == 20)
        #expect(output.value.contains(where: { $0.isUppercase }))
        #expect(output.value.contains(where: { $0.isLowercase }))
        #expect(output.value.contains(where: { $0.isNumber }))
        #expect(output.value.contains(where: { !$0.isLetter && !$0.isNumber }))
        #expect(Set(output.value).isDisjoint(with: Set("IilLoO01")))
        #expect(output.entropyBits > 100 && output.entropyBits.isFinite)
    }

    @Test func passphraseLoadsTheRealWordListAndUsesDistinctSeparator() throws {
        let output = try PasswordGenerator.passphrase(wordCount: 6, separator: .hyphen, capitalized: true)
        let words = output.value.split(separator: "-")
        #expect(words.count == 6)
        #expect(words.allSatisfy { $0.first?.isUppercase == true })
        #expect(output.entropyBits == 6 * log2(7772))
        let spaced = try PasswordGenerator.passphrase(wordCount: 4, separator: .space, capitalized: false)
        #expect(spaced.value.split(separator: " ").count == 4)
        #expect(spaced.entropyBits == 4 * log2(7776))
    }

    @Test func rejectsEmptyGroupsAndOutOfRangeLengths() {
        #expect(throws: ToolError.self) { try PasswordGenerator.password(length: 12, groups: []) }
        #expect(throws: ToolError.self) { try PasswordGenerator.passphrase(wordCount: 2, separator: .space, capitalized: false) }
    }
}
