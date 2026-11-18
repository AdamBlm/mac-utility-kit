import Foundation

enum GIFLoopMetadata {
    /// FFmpeg writes the Netscape application extension before the first image.
    /// ImageIO exposes normalized playback metadata rather than the raw repeat count.
    static func read(_ url: URL) throws -> Int {
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        guard bytes.count >= 13, bytes.starts(with: "GIF89a".utf8) || bytes.starts(with: "GIF87a".utf8) else {
            throw invalid()
        }
        let flags = bytes[10]
        let colorTableSize = flags & 0x80 == 0 ? 0 : 3 * (1 << (Int(flags & 7) + 1))
        var position = 13 + colorTableSize

        while position < bytes.count {
            switch bytes[position] {
            case 0x2C, 0x3B: return -1
            case 0x21: break
            default: throw invalid()
            }
            position += 1
            guard position < bytes.count else { throw invalid() }
            let label = bytes[position]
            position += 1
            if label == 0xFF, position + 16 < bytes.count, bytes[position] == 11,
               bytes[(position + 1)..<(position + 12)].elementsEqual("NETSCAPE2.0".utf8),
               bytes[position + 12] == 3, bytes[position + 13] == 1, bytes[position + 16] == 0 {
                return Int(bytes[position + 14]) | (Int(bytes[position + 15]) << 8)
            }
            while position < bytes.count {
                let count = Int(bytes[position])
                position += 1
                guard count > 0 else { break }
                position += count
                guard position < bytes.count else { throw invalid() }
            }
        }
        throw invalid()
    }

    private static func invalid() -> ToolError {
        ToolError.invalid("The GIF playback header could not be read.")
    }
}
