import AppKit
import PDFKit
import WebKit

@MainActor
enum WebKitPDFPrinting {
    static func paginated(
        _ webView: WKWebView, paper: CGSize, margin: CGFloat, backgrounds: Bool
    ) async throws -> Data {
        try Task.checkCancellation()
        let manager = FileManager.default
        let scratch = manager.temporaryDirectory.appending(path: ".WebKitPDF-\(UUID().uuidString)", directoryHint: .isDirectory)
        try manager.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: scratch) }
        let output = scratch.appendingPathComponent("document.pdf")

        let printWindow: NSWindow
        let originalFrame = webView.frame
        let host: NSWindow?
        if let window = webView.window {
            printWindow = window
            host = nil
        } else {
            let frame = CGRect(x: 0, y: 0, width: paper.width - margin * 2, height: paper.height - margin * 2)
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
            window.contentView = webView
            webView.frame = frame
            printWindow = window
            host = window
        }
        defer {
            if let host {
                host.contentView = nil
                webView.frame = originalFrame
            }
        }

        let preferences = webView.configuration.preferences
        let originalBackgrounds = preferences.shouldPrintBackgrounds
        preferences.shouldPrintBackgrounds = backgrounds
        defer { preferences.shouldPrintBackgrounds = originalBackgrounds }

        let info = NSPrintInfo()
        info.paperSize = paper
        info.topMargin = margin
        info.rightMargin = margin
        info.bottomMargin = margin
        info.leftMargin = margin
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output

        let operation = webView.printOperation(with: info)
        // WebKit's internal print view can start with a zero-size frame.
        operation.view?.frame = webView.bounds
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        // WebKit computes print pages asynchronously on the main run loop.
        operation.canSpawnSeparateThread = true
        var completion: WebKitPrintCompletion?
        let succeeded: Bool = await withCheckedContinuation { continuation in
            completion = WebKitPrintCompletion(continuation: continuation)
            operation.runModal(for: printWindow, delegate: completion,
                didRun: #selector(WebKitPrintCompletion.finished(_:success:context:)), contextInfo: nil)
        }
        withExtendedLifetime(completion) {}

        try Task.checkCancellation()
        guard succeeded, let pdf = PDFDocument(url: output), pdf.pageCount > 0 else {
            throw ToolError.invalid("WebKit could not produce a printable PDF.")
        }
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index), matches(page.bounds(for: .mediaBox).size, paper) else {
                throw ToolError.invalid("A printed page did not match the selected paper size.")
            }
        }
        return try Data(contentsOf: output)
    }

    static func matches(_ actual: CGSize, _ requested: CGSize) -> Bool {
        abs(actual.width - requested.width) <= 2 && abs(actual.height - requested.height) <= 2
    }
}

private final class WebKitPrintCompletion: NSObject {
    private let continuation: CheckedContinuation<Bool, Never>

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    @objc func finished(_ operation: NSPrintOperation, success: Bool, context: UnsafeMutableRawPointer?) {
        continuation.resume(returning: success)
    }
}
