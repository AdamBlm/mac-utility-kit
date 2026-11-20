import Foundation
import Observation
import PDFKit
import WebKit

@MainActor
@Observable
public final class WebPagePDFBrowser: NSObject, WKNavigationDelegate {
    @ObservationIgnored public let webView: WKWebView
    private(set) public var currentURL: URL?
    private(set) public var lastLoadedURL: URL?
    private(set) public var failure: String?
    private(set) public var isLoading = false
    private(set) public var isExporting = false
    private(set) public var canGoBack = false
    private(set) public var canGoForward = false
    @ObservationIgnored private var navigation: WKNavigation?
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var pending: CheckedContinuation<Void, any Error>?
    @ObservationIgnored private var loadID: UUID?

    public override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 480), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    public func load(_ url: URL) async throws {
        guard WebPagePDF.permits(url) else { throw ToolError.invalid("Enter a complete HTTP or HTTPS webpage URL.") }
        guard !isExporting else { throw ToolError.invalid("Wait until the PDF export finishes.") }
        cancelPending()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                loadID = id
                pending = continuation
                begin()
                navigation = webView.load(URLRequest(url: url, timeoutInterval: 30))
                if navigation == nil { fail("WebKit could not start loading this page.") }
            }
        } onCancel: {
            Task { @MainActor in
                if self.loadID == id { self.cancelPending() }
            }
        }
    }

    public func stop() {
        if isLoading { fail("Page loading stopped.") }
    }

    public func goBack() {
        guard canGoBack, !isLoading, !isExporting else { return }
        begin()
        navigation = webView.goBack()
        if navigation == nil { fail("There is no previous page.") }
    }

    public func goForward() {
        guard canGoForward, !isLoading, !isExporting else { return }
        begin()
        navigation = webView.goForward()
        if navigation == nil { fail("There is no next page.") }
    }

    public func export(options: WebPagePDFOptions) async throws -> Data {
        guard !isLoading, !isExporting, currentURL != nil, failure == nil else {
            throw ToolError.invalid("Load a webpage before exporting it.")
        }
        isExporting = true
        defer { isExporting = false }
        switch options.layout {
        case .paginated:
            return try await WebKitPDFPrinting.paginated(webView, paper: options.paper.size,
                margin: options.margin.points, backgrounds: options.printBackgrounds)
        case .continuous:
            return try await exportContinuous()
        }
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard !isExporting, !isLoading || navigationAction.navigationType != .linkActivated else {
            decisionHandler(.cancel)
            return
        }
        let isMain = navigationAction.targetFrame?.isMainFrame ?? true
        if !isMain, navigationAction.request.url?.absoluteString == "about:blank" {
            decisionHandler(.allow)
            return
        }
        guard let url = navigationAction.request.url, WebPagePDF.permits(url) else {
            decisionHandler(.cancel)
            if isMain, isLoading { fail("This page redirected to an unsupported address.") }
            return
        }
        if navigationAction.targetFrame == nil {
            decisionHandler(.cancel)
            if navigationAction.navigationType == .linkActivated {
                begin()
                navigation = webView.load(navigationAction.request)
                if navigation == nil { fail("WebKit could not open this link.") }
            }
        } else {
            decisionHandler(.allow)
        }
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame {
            let response = navigationResponse.response as? HTTPURLResponse
            if let response, response.statusCode >= 400 {
                decisionHandler(.cancel)
                fail("The server returned HTTP \(response.statusCode).")
                return
            }
            let disposition = response?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
            if !navigationResponse.canShowMIMEType || disposition.hasPrefix("attachment") {
                decisionHandler(.cancel)
                fail("This address returned a download instead of a webpage.")
                return
            }
        }
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if self.navigation !== navigation {
            endPending(CancellationError())
            self.navigation = navigation
            begin()
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard self.navigation === navigation else { return }
        guard let url = webView.url, WebPagePDF.permits(url) else {
            fail("WebKit finished loading an unsupported address.")
            return
        }
        clearNavigation()
        currentURL = url
        lastLoadedURL = url
        failure = nil
        updateHistory()
        endPending(nil)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        if self.navigation === navigation { fail("Could not load this page. \(error.localizedDescription)") }
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        if self.navigation === navigation { fail("Could not load this page. \(error.localizedDescription)") }
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        fail("The webpage renderer stopped. Reload the page and try again.")
    }

    private func exportContinuous() async throws -> Data {
        try Task.checkCancellation()
        let dimensions = try await webView.callAsyncJavaScript("""
        return [Math.max(document.documentElement.scrollWidth, document.body?.scrollWidth ?? 0),
                Math.max(document.documentElement.scrollHeight, document.body?.scrollHeight ?? 0)];
        """, arguments: [:], in: nil, contentWorld: .defaultClient)
        guard let values = dimensions as? [Double], values.count == 2 else {
            throw ToolError.invalid("Could not measure this page for continuous PDF export. Try Paginated output.")
        }
        let size = try WebPagePDF.continuousSize(width: values[0], height: values[1])
        let config = WKPDFConfiguration()
        config.rect = CGRect(origin: .zero, size: size)
        let data = try await webView.pdf(configuration: config)
        try Task.checkCancellation()
        guard let pdf = PDFDocument(data: data), pdf.pageCount == 1,
              let page = pdf.page(at: 0), WebKitPDFPrinting.matches(page.bounds(for: .mediaBox).size, size) else {
            throw ToolError.invalid("WebKit could not export the full continuous page. Try Paginated output.")
        }
        return data
    }

    private func begin() {
        isLoading = true
        failure = nil
        currentURL = nil
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) }
            catch { return }
            self?.fail("The webpage did not finish loading within 30 seconds.")
        }
    }

    private func fail(_ message: String) {
        clearNavigation()
        webView.stopLoading()
        currentURL = nil
        failure = message
        updateHistory()
        endPending(ToolError.invalid(message))
    }

    private func cancelPending() {
        if isLoading {
            clearNavigation()
            webView.stopLoading()
        }
        endPending(CancellationError())
    }

    private func clearNavigation() {
        navigation = nil
        isLoading = false
        timeout?.cancel()
        timeout = nil
    }

    private func endPending(_ error: (any Error)?) {
        loadID = nil
        guard let pending else { return }
        self.pending = nil
        if let error { pending.resume(throwing: error) }
        else { pending.resume(returning: ()) }
    }

    private func updateHistory() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }
}
