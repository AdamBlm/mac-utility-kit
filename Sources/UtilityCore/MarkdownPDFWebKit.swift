import AppKit
import WebKit

@MainActor
public final class MarkdownPDFWebPage: NSObject, WKNavigationDelegate {
    public let webView: WKWebView
    private var loading: CheckedContinuation<Void, any Error>?
    private var loadID: UUID?
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
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                loadID = id
                loading = continuation
                navigation = webView.loadHTMLString(document.html, baseURL: nil)
                if navigation == nil { finish(ToolError.invalid("WebKit could not load the Markdown preview.")) }
            }
        } onCancel: {
            Task { @MainActor in
                if self.loadID == id { self.cancelLoad() }
            }
        }
        try Task.checkCancellation()
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        let initial = navigationAction.navigationType == .other && url?.absoluteString == "about:blank"
        var components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let hasFragment = components?.fragment?.isEmpty == false
        components?.fragment = nil
        let headingLink = navigationAction.navigationType == .linkActivated && hasFragment
            && components?.string == "about:blank" && navigationAction.targetFrame?.isMainFrame == true
        decisionHandler(initial || headingLink ? .allow : .cancel)
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
        loadID = nil
        guard let loading else { return }
        self.loading = nil
        if let error { loading.resume(throwing: error) }
        else { loading.resume(returning: ()) }
    }
}

@MainActor
public enum MarkdownPDFPrint {
    public static func render(_ document: MarkdownPDFDocument) async throws -> Data {
        let page = MarkdownPDFWebPage()
        let size = document.options.paper.size
        let margin = document.options.margin.points
        page.webView.frame.size = CGSize(width: size.width - margin * 2, height: size.height - margin * 2)
        try await page.load(document)
        return try await WebKitPDFPrinting.paginated(page.webView, paper: size, margin: margin, backgrounds: true)
    }
}
