import CoreGraphics
import Foundation
import Testing
@testable import UtilityCore

@Suite struct QRToolsTests {
    @Test func copiesOnlyChosenBarcodePayloadsInDisplayOrderAndConcealsMixedSecrets() throws {
        let first = QRDetection(type: "QR Code", payload: "café\n東京")
        let secret = QRDetection(type: "QR Code", payload: "WIFI:S:Example;T:WPA;P:fixture-only;;")
        let last = QRDetection(type: "Code 128", payload: "123")
        let items = [first, secret, last]
        let publicSelection = try #require(QRTools.selectedText(from: items, ids: [last.id, first.id]))
        #expect(publicSelection.text == "café\n東京\n123")
        #expect(!publicSelection.concealed)
        let privateSelection = try #require(QRTools.selectedText(from: items, ids: [last.id, secret.id]))
        #expect(privateSelection.text == secret.payload + "\n123")
        #expect(privateSelection.concealed)
        #expect(QRTools.selectedText(from: items, ids: [UUID()]) == nil)
    }

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

    @Test func detectsSmallRepeatedCodesAcrossOverlappingTiles() throws {
        let context = try #require(CGContext(data: nil, width: 16_000, height: 1_200, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 16_000, height: 1_200))
        var options = QRCodeOptions()
        options.size = 128
        let code = try QRTools.generate(.text("DETAIL-MARKER"), options: options)
        context.interpolationQuality = .none
        context.draw(code, in: CGRect(x: 840, y: 500, width: 128, height: 128))
        context.draw(code, in: CGRect(x: 12_350, y: 300, width: 128, height: 128))
        let panorama = try #require(context.makeImage())
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: file) }
        try QRTools.png(panorama).write(to: file)
        #expect(try QRTools.detect(in: file).map(\.payload) == ["DETAIL-MARKER", "DETAIL-MARKER"])
        #expect(try QRTools.detect(in: panorama).map(\.payload) == ["DETAIL-MARKER", "DETAIL-MARKER"])
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
