import Foundation

public enum VideoTimecode {
    /// Parses decimal seconds, MM:SS, or HH:MM:SS with optional fractional seconds.
    public static func seconds(from text: String) -> Double? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = text.replacingOccurrences(of: ",", with: ".").split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(fields.count), let tail = fields.last else { return nil }
        let decimal = tail.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(decimal.count), decimal.allSatisfy(isDigits),
              let seconds = Double(tail), seconds.isFinite else { return nil }
        if fields.count == 1 { return seconds }
        guard seconds < 60 else { return nil }
        let wholeFields = fields.dropLast()
        guard wholeFields.allSatisfy(isDigits) else { return nil }
        let minutes: Double
        let hours: Double
        if fields.count == 2 {
            guard let value = Double(fields[0]) else { return nil }
            minutes = value
            hours = 0
        } else {
            guard let minuteValue = Double(fields[1]), minuteValue < 60,
                  let hourValue = Double(fields[0]) else { return nil }
            minutes = minuteValue
            hours = hourValue
        }
        let result = hours * 3600 + minutes * 60 + seconds
        return result.isFinite ? result : nil
    }

    private static func isDigits(_ text: Substring) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { (48...57).contains($0) }
    }
}
