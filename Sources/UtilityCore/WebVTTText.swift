import Foundation
import cmark_gfm

enum WebVTTText {
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func decode(_ text: Substring) -> String? {
        guard text.utf8.contains(38) else { return String(text) }
        let bytes = Array(text.utf8)
        var output = cmark_strbuf()
        cmark_strbuf_init(cmark_get_default_mem_allocator(), &output, 0)
        defer { cmark_strbuf_free(&output) }
        return bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return "" }
            var offset = 0
            while offset < bytes.count {
                let next = bytes[offset...].firstIndex(of: 38) ?? bytes.count
                cmark_strbuf_put(&output, base + offset, Int32(next - offset))
                guard next < bytes.count else { break }
                let consumed = houdini_unescape_ent(&output, base + next + 1, Int32(bytes.count - next - 1))
                if consumed > 0 {
                    offset = next + 1 + Int(consumed)
                } else {
                    let tail = bytes[(next + 1)...]
                    let name = tail.prefix { byte in
                        byte == 35 || (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                    }
                    if !name.isEmpty, name.endIndex < bytes.count, bytes[name.endIndex] == 59 { return nil }
                    cmark_strbuf_putc(&output, 38)
                    offset = next + 1
                }
            }
            return String(decoding: UnsafeBufferPointer(start: output.ptr, count: Int(output.size)), as: UTF8.self)
        }
    }
}
