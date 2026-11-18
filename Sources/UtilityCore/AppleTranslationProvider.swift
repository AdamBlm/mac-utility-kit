import Foundation
@preconcurrency import Translation

public enum AppleTranslationProvider {
    public static func supportedLanguages() async -> [Locale.Language] {
        await LanguageAvailability().supportedLanguages
    }

    public static func translate(
        _ document: TranslationDocument, using session: TranslationSession,
        source: Locale.Language?, target: Locale.Language,
        progress: @Sendable (Double) async -> Void = { _ in }
    ) async throws -> String {
        let requests = document.requests
        let availability = LanguageAvailability()
        let status: LanguageAvailability.Status
        if let source {
            status = await availability.status(from: source, to: target)
        } else {
            status = try await availability.status(for: requests.prefix(6).joined(separator: " "), to: target)
        }
        try Task.checkCancellation()
        guard status != .unsupported else {
            throw ToolError.invalid("This language pair is unsupported. Choose a different source or target language.")
        }

        var translations: [String] = []
        for start in stride(from: 0, to: requests.count, by: 24) {
            try Task.checkCancellation()
            let end = min(start + 24, requests.count)
            let batch = requests[start..<end].enumerated().map { offset, line in
                TranslationSession.Request(sourceText: line, clientIdentifier: String(start + offset))
            }
            let expectedIDs = batch.map(\.clientIdentifier)
            let response = try await session.translations(from: batch)
            let ordered = response.sorted {
                (Int($0.clientIdentifier ?? "") ?? -1) < (Int($1.clientIdentifier ?? "") ?? -1)
            }
            guard ordered.map(\.clientIdentifier) == expectedIDs else {
                throw ToolError.invalid("The translation did not return all lines for this batch.")
            }
            translations.append(contentsOf: ordered.map(\.targetText))
            await progress(Double(end) / Double(requests.count))
        }
        try Task.checkCancellation()
        return try document.rendering(translations)
    }
}
