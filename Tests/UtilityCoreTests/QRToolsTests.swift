import Foundation
import Testing
import UtilityCore

@Suite struct QRToolsTests {
    @Test func coloredPNGScansUnicode() throws {
        let text = "Hello café 東京"
        var options = QRCodeOptions()
        options.size = 317
        options.correction = .quartile
        options.foreground = QRColor(red: 25, green: 25, blue: 80)
        let image = try QRTools.generate(.text(text), options: options)
        #expect(image.width == 317)
        #expect(image.height == 317)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        try QRTools.png(image).write(to: url)
        let observations = try QRTools.detect(in: url)
        #expect(observations.map(\.payload) == [text])
        #expect(observations.map(\.type) == ["QR Code"])
    }

    @Test func wiFiPayloadEscapesDelimitersAndOmitsOpenNetworkPassword() throws {
        let secured = QRPayload.wiFi(name: #"a;b:c,d\x"#, security: .wpa, password: #"p;:"z"#, hidden: true)
        #expect(try secured.encoded() == #"WIFI:T:WPA;S:a\;b\:c\,d\\x;P:p\;\:\"z;H:true;;"#)
        let open = QRPayload.wiFi(name: "Coffee", security: .open, password: "secret", hidden: false)
        #expect(try open.encoded() == "WIFI:T:nopass;S:Coffee;;")
    }

    @Test func rejectsIncompleteAndNonHTTPURLs() throws {
        #expect(throws: QRToolError.self) { try QRPayload.url("example.org").encoded() }
        #expect(throws: QRToolError.self) { try QRPayload.url("https://example.com/has space").encoded() }
        #expect(throws: QRToolError.self) { try QRPayload.url("file:///tmp/foo").encoded() }
        #expect(try QRPayload.url(" https://example.org/test ").encoded() == "https://example.org/test")
    }
}
