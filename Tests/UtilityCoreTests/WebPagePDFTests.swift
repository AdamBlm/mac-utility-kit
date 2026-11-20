import CoreGraphics
import Foundation
import Network
import PDFKit
import Testing
import UtilityCore

@Suite struct WebPagePDFTests {
    @Test func validatesURLsAndOnePageLimits() throws {
        #expect(try WebPagePDF.address(" https://example.test/page ").host() == "example.test")
        #expect(throws: ToolError.self) { try WebPagePDF.address("file:///tmp/private") }
        #expect(throws: ToolError.self) { try WebPagePDF.address("https://username:password@example.test") }
        #expect(throws: ToolError.self) { try WebPagePDF.address("example.test/page") }
        #expect(try WebPagePDF.continuousSize(width: 600.2, height: 2000.7) == CGSize(width: 601, height: 2001))
        #expect(throws: ToolError.self) { try WebPagePDF.continuousSize(width: 600, height: 20_000) }
        #expect(throws: ToolError.self) { try WebPagePDF.continuousSize(width: 3_000, height: 12_000) }
    }

    @MainActor
    @Test func rendersLocalPageWithPrintStylesAndBackgroundPreference() async throws {
        let server = try await WebPageFixture.start()
        defer { server.listener.cancel() }
        let browser = WebPagePDFBrowser()
        try await browser.load(server.url("/redirect"))
        #expect(browser.currentURL?.path == "/paper")
        var options = WebPagePDFOptions()
        options.paper = .letter
        options.margin = .compact

        let printed = try await browser.export(options: options)
        let pdf = try #require(PDFDocument(data: printed))
        #expect(pdf.pageCount > 1)
        let first = try #require(pdf.page(at: 0))
        #expect(first.bounds(for: .mediaBox).size == CGSize(width: 612, height: 792))
        let text = pdf.string ?? ""
        #expect(text.contains("PRINT VIEW") && !text.contains("SCREEN VIEW"))
        let firstMarker = try #require(text.range(of: "Paragraph 1 marker"))
        let lastMarker = try #require(text.range(of: "Paragraph 65 marker"))
        #expect(firstMarker.lowerBound < lastMarker.lowerBound)
        #expect(try redPixels(first) == 0)

        options.printBackgrounds = true
        let colorPDF = try await browser.export(options: options)
        let colorDocument = try #require(PDFDocument(data: colorPDF))
        let colorPage = try #require(colorDocument.page(at: 0))
        #expect(try redPixels(colorPage) > 10)
    }

    @MainActor
    @Test func capturesFullContinuousPageAndReportsFailureAndOversize() async throws {
        let server = try await WebPageFixture.start()
        defer { server.listener.cancel() }
        let browser = WebPagePDFBrowser()
        try await browser.load(server.url("/paper"))
        var options = WebPagePDFOptions()
        options.layout = .continuous
        let continuous = try await browser.export(options: options)
        let pdf = try #require(PDFDocument(data: continuous))
        #expect(pdf.pageCount == 1)
        #expect((pdf.page(at: 0)?.bounds(for: .mediaBox).height ?? 0) > 792)
        #expect(pdf.string?.contains("SCREEN VIEW") == true)
        #expect(pdf.string?.contains("Paragraph 65 marker") == true)

        try await browser.load(server.url("/oversize"))
        do {
            _ = try await browser.export(options: options)
            Issue.record("Expected continuous export to reject an oversized page.")
        } catch {
            #expect(error.localizedDescription.contains("Choose Paginated output"))
        }
        #expect(browser.currentURL?.path == "/oversize")
        await #expect(throws: ToolError.self) { try await browser.load(server.url("/missing")) }
        #expect(browser.failure?.contains("HTTP 404") == true)
        #expect(browser.currentURL == nil)
        let lastPage = try #require(browser.lastLoadedURL)
        #expect(lastPage.path == "/oversize")
        await #expect(throws: ToolError.self) { try await browser.load(server.url("/attachment")) }
        #expect(browser.failure?.contains("download instead of a webpage") == true)
        #expect(browser.lastLoadedURL == lastPage)
        await #expect(throws: ToolError.self) { _ = try await browser.export(options: options) }
        try await browser.load(lastPage)
        #expect(browser.currentURL == lastPage)
        #expect(browser.failure == nil)
    }

    private func redPixels(_ page: PDFPage) throws -> Int {
        let raw = try #require(page.pageRef)
        let width = 250
        let height = 320
        var data = [UInt8](repeating: 255, count: width * height * 4)
        return try data.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            let media = raw.getBoxRect(.mediaBox)
            context.scaleBy(x: CGFloat(width) / media.width, y: CGFloat(height) / media.height)
            context.drawPDFPage(raw)
            return stride(from: 0, to: bytes.count, by: 4).filter {
                bytes[$0] > 130 && Int(bytes[$0]) - Int(bytes[$0 + 1]) > 80
            }.count
        }
    }
}

private struct WebPageFixture {
    let listener: NWListener
    let port: UInt16

    func url(_ path: String) throws -> URL {
        try #require(URL(string: "http://127.0.0.1:\(port)\(path)"))
    }

    static func start() async throws -> WebPageFixture {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "MacUtilityKit.fixture-http")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            receive(connection)
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    if let port = listener.port?.rawValue { continuation.resume(returning: port) }
                    else { continuation.resume(throwing: ToolError.invalid("Test web server has no port.")) }
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return WebPageFixture(listener: listener, port: port)
    }

    private static func receive(_ connection: NWConnection, previous: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, complete, error in
            let request = previous + (data ?? Data())
            if let end = request.range(of: Data([13, 10, 13, 10])) {
                let first = String(decoding: request.prefix(upTo: end.lowerBound), as: UTF8.self)
                let path = first.split(separator: " ").dropFirst().first.map(String.init) ?? "/missing"
                let response = response(path)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            } else if complete || error != nil || request.count > 32_768 {
                connection.cancel()
            } else {
                receive(connection, previous: request)
            }
        }
    }

    private static func response(_ path: String) -> Data {
        let status: String
        let body: String
        var headers = "Content-Type: text/html; charset=UTF-8\r\n"
        switch path {
        case "/redirect":
            status = "302 Found"
            headers += "Location: /paper\r\n"
            body = ""
        case "/paper":
            status = "200 OK"
            body = """
            <!doctype html><meta charset=utf-8><style>
            body { margin:0; font:16px sans-serif; }
            .color { width:140px; height:95px; background:#d72128; }
            .print { display:none; }
            @media print { .screen { display:none; } .print { display:block; } }
            </style>
            <h1 class=screen>SCREEN VIEW</h1><h1 class=print>PRINT VIEW</h1><div class=color></div>
            """ + (1...65).map { "<p>Paragraph \($0) marker. This webpage is served on loopback.</p>" }.joined()
        case "/oversize":
            status = "200 OK"
            body = "<div style='height:18000px'>A very long webpage</div>"
        case "/attachment":
            status = "200 OK"
            headers += "Content-Disposition: attachment; filename=page.html\r\n"
            body = "The browser should not automatically download this."
        default:
            status = "404 Not Found"
            body = "Missing test page"
        }
        return Data(("HTTP/1.1 \(status)\r\n\(headers)Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body).utf8)
    }
}
