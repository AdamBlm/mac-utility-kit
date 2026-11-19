import Foundation

enum PlainTextDecoding {
    static func decode(_ data: Data) -> String? {
        let text: String?
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) || data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            guard data.count.isMultiple(of: 4) else { return nil }
            text = String(data: data, encoding: .utf32)
        } else if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            guard data.count.isMultiple(of: 2) else { return nil }
            text = String(data: data, encoding: .utf16)
        } else if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            text = String(data: data.dropFirst(3), encoding: .utf8)
        } else {
            text = String(data: data, encoding: .utf8)
        }
        guard let text, !text.unicodeScalars.contains(where: { $0.value == 0 }) else { return nil }
        return text
    }
}
