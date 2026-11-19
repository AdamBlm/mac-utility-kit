import AppKit
import SwiftUI
import UtilityCore
import WebKit

struct WebPagePDFDraft {
    var address = ""
    var options = WebPagePDFOptions()
}

struct WebPagePDFView: View {
    @Binding var draft: WebPagePDFDraft
    @State private var browser = WebPagePDFBrowser()
    @State private var loadTask: Task<Void, Never>?
    @State private var exportTask: Task<Void, Never>?
    @State private var exportError: String?
    @State private var renderedPreview: RenderedPDFPreview?

    var body: some View {
        InteractiveToolLayout(tool: .webPageToPDF) { palette in
            WorkspaceSection("Web Address", palette: palette) {
                HStack {
                    TextField("https://example.com", text: $draft.address)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Webpage URL")
                        .onSubmit(load)
                    Button("Load Page", systemImage: "arrow.right.circle", action: load)
                        .disabled(address == nil || browser.isExporting)
                }
                .disabled(browser.isExporting)
                if address == nil, !draft.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Use a complete HTTP or HTTPS URL.").font(.callout).foregroundStyle(.secondary)
                } else if let failure = browser.failure {
                    Text(failure).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
            }

            if loadTask != nil || browser.isLoading || browser.currentURL != nil {
                WorkspaceSection("Page Preview", palette: palette) {
                    HStack {
                        Button("Back", systemImage: "chevron.left", action: browser.goBack)
                            .labelStyle(.iconOnly).disabled(!browser.canGoBack || browser.isLoading || browser.isExporting)
                        Button("Forward", systemImage: "chevron.right", action: browser.goForward)
                            .labelStyle(.iconOnly).disabled(!browser.canGoForward || browser.isLoading || browser.isExporting)
                        if let url = browser.currentURL {
                            Text(url.absoluteString).font(.callout).foregroundStyle(.secondary)
                                .truncationMode(.middle).lineLimit(1)
                        }
                        Spacer()
                        if browser.isLoading {
                            ProgressView().controlSize(.small)
                            Button("Stop", action: browser.stop)
                        }
                    }
                    WebPageBrowserPreview(webView: browser.webView)
                        .allowsHitTesting(!browser.isExporting)
                        .frame(minHeight: 300, idealHeight: 430, maxHeight: 520)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("Webpage preview")
                }
            }

            WorkspaceSection("PDF Setup", palette: palette) {
                SettingRow("Layout") {
                    Picker("PDF layout", selection: $draft.options.layout) {
                        ForEach(WebPagePDFLayout.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                if draft.options.layout == .paginated {
                    SettingRow("Paper") {
                        Picker("Paper", selection: $draft.options.paper) {
                            ForEach(PDFPrintPaper.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                    }
                    SettingRow("Margins") {
                        Picker("Margins", selection: $draft.options.margin) {
                            ForEach(PDFPrintMargin.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                    }
                    Toggle("Print backgrounds", isOn: $draft.options.printBackgrounds)
                } else {
                    Text("Continuous output captures the full webpage on one page using its on-screen styles.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .disabled(exportTask != nil)

            HStack {
                Button("Preview PDF", systemImage: "doc.viewfinder") { render(showPreview: true) }
                    .disabled(!canRender)
                Button("Export PDF…", systemImage: "square.and.arrow.up") { render(showPreview: false) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canRender)
                if exportTask != nil {
                    ProgressView("Rendering PDF…").controlSize(.small)
                    Button("Cancel") { exportTask?.cancel() }
                }
            }
            if let exportError {
                Text(exportError).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .onDisappear {
            loadTask?.cancel()
            exportTask?.cancel()
        }
        .onChange(of: draft.options) { exportError = nil }
        .sheet(item: $renderedPreview) { preview in RenderedPDFPreviewSheet(preview: preview) }
    }

    private var canRender: Bool {
        browser.currentURL != nil && !browser.isLoading && browser.failure == nil && exportTask == nil
    }

    private var address: URL? { try? WebPagePDF.address(draft.address) }

    private func load() {
        guard let url = address, exportTask == nil else { return }
        loadTask?.cancel()
        exportError = nil
        // The browser owns navigation errors and invalidates prior callbacks on replacement.
        loadTask = Task {
            defer { if !Task.isCancelled { loadTask = nil } }
            _ = try? await browser.load(url)
        }
    }

    private func render(showPreview: Bool) {
        guard canRender, let url = browser.currentURL else { return }
        let options = draft.options
        exportError = nil
        exportTask = Task {
            defer { exportTask = nil }
            do {
                let data = try await browser.export(options: options)
                try Task.checkCancellation()
                let filename = (url.host() ?? "Webpage") + ".pdf"
                if showPreview {
                    renderedPreview = try RenderedPDFPreview(data: data, filename: filename)
                } else {
                    try DeveloperToolFiles.save(data, as: filename)
                }
            } catch is CancellationError {
                return
            } catch {
                exportError = error.localizedDescription
            }
        }
    }
}

private struct WebPageBrowserPreview: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
