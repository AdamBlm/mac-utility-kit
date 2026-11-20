import Foundation
import NaturalLanguage

enum SpeechLanguageSelection {
    static func installedLanguage(
        for text: String, currentLanguage: String, available: [String],
        identify: (String) -> [String: Double] = hypotheses
    ) -> String? {
        let sample = String(text.prefix(2_000))
        let letters = sample.unicodeScalars.lazy.filter { CharacterSet.letters.contains($0) }
        guard !available.isEmpty, letters.prefix(24).count == 24 else { return nil }

        let ranked = identify(sample).sorted { $0.value > $1.value }
        guard let match = ranked.first, match.value >= 0.65,
              match.value - (ranked.dropFirst().first?.value ?? 0) >= 0.35 else { return nil }

        let detected = Locale.Language(identifier: match.key)
        guard let language = detected.languageCode else { return nil }
        let matching = available.filter {
            let voice = Locale.Language(identifier: $0)
            return voice.languageCode == language && voice.script == detected.script
        }
        return matching.first { $0.caseInsensitiveCompare(currentLanguage) == .orderedSame }
            ?? matching.first { Locale.Language(identifier: $0).region == detected.region }
            ?? matching.sorted().first
    }

    private static func hypotheses(_ text: String) -> [String: Double] {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return Dictionary(uniqueKeysWithValues: recognizer.languageHypotheses(withMaximum: 2).map {
            ($0.key.rawValue, $0.value)
        })
    }
}
