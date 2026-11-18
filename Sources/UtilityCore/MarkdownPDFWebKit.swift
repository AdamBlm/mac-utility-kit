import AppKit
import PDFKit
import WebKit

@MainActor
public final class MarkdownPDFWebPage: NSObject, WKNavigationDelegate {
    public let webView: WKWebView
    private var loading: CheckedContinuation<Void, any Error>?
    private var navigation: WKNavigation?

    public override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 540, height: 720), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    public func show(_ document: MarkdownPDFDocument) {
        cancelLoad()
        navigation = webView.loadHTMLString(document.html, baseURL: nil)
    }

    public func load(_ document: MarkdownPDFDocument) async throws {
        cancelLoad()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                loading = continuation
                navigation = webView.loadHTMLString(document.html, baseURL: nil)
                if navigation == nil { finish(ToolError.invalid("WebKit could not load the Markdown preview.")) }
            }
        } onCancel: {
            Task { @MainActor in self.cancelLoad() }
        }
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let initial = navigationAction.navigationType == .other && navigationAction.request.url?.absoluteString == "about:blank"
        decisionHandler(initial ? .allow : .cancel)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if self.navigation === navigation { finish(nil) }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        if self.navigation === navigation { finish(error) }
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        if self.navigation === navigation { finish(error) }
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(ToolError.invalid("The Markdown renderer stopped. Please try again."))
    }

    private func cancelLoad() {
        if navigation != nil {
            navigation = nil
            webView.stopLoading()
        }
        finish(CancellationError())
    }

    private func finish(_ error: (any Error)?) {
        navigation = nil
        guard let loading else { return }
        self.loading = nil
        if let error { loading.resume(throwing: error) }
        else { loading.resume(returning: ()) }
    }
}

@MainActor
public enum MarkdownPDFPrint {
    public static func render(_ document: MarkdownPDFDocument) async throws -> Data {
        try Task.checkCancellation()
        let manager = FileManager.default
        let scratch = manager.temporaryDirectory.appending(path: ".MarkdownPDF-\(UUID().uuidString)", directoryHint: .isDirectory)
        try manager.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: scratch) }
        let output = scratch.appendingPathComponent("document.pdf")
        let size = document.options.paper.size
        let margin = document.options.margin.points
        let frame = CGRect(x: 0, y: 0, width: size.width - margin * 2, height: size.height - margin * 2)
        let page = MarkdownPDFWebPage()
        let host = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
        host.contentView = page.webView
        page.webView.frame = frame
        defer { host.contentView = nil }
        try await page.load(document)
        try Task.checkCancellation()

        let info = NSPrintInfo()
        info.paperSize = size
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
        let operation = page.webView.printOperation(with: info)
        // WebKit's private printing view can start with a zero-size frame.
        operation.view?.frame = page.webView.bounds
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        // WebKit computes print pages asynchronously on the main run loop. The
        // AppKit worker leaves that run loop available instead of using preview pagination.
        operation.canSpawnSeparateThread = true
        var completion: MarkdownPrintCompletion?
        let succeeded: Bool = await withCheckedContinuation { continuation in
            completion = MarkdownPrintCompletion(continuation: continuation)
            operation.runModal(for: host, delegate: completion,
                               didRun: #selector(MarkdownPrintCompletion.finished(_:success:context:)), contextInfo: nil)
        }
        withExtendedLifetime(completion) {}
        guard succeeded, let pdf = PDFDocument(url: output), pdf.pageCount > 0 else {
            throw ToolError.invalid("WebKit could not print the Markdown document to PDF.")
        }
        try Task.checkCancellation()
        return try Data(contentsOf: output)
    }
}


private final class MarkdownPrintCompletion: NSObject {
    private let continuation: CheckedContinuation<Bool, Never>

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    @objc func finished(_ operation: NSPrintOperation, success: Bool, context: UnsafeMutableRawPointer?) {
        continuation.resume(returning: success)
    }
}
