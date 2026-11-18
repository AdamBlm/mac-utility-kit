import AppKit
import PDFKit
import SwiftUI
import UtilityCore

struct AskDocumentPreview: View {
    let index: AskDocument.Index
    let location: AskDocument.Location
    let quote: String?
    let initialPDFPassword: String

    @Environment(\.dismiss) private var dismiss
    @State private var reader = PDFReaderSession()
    @State private var password = ""
    @State private var issue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(index.source.lastPathComponent).font(.headline).lineLimit(1)
                    Text(location.label).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done", action: { dismiss() }).keyboardShortcut(.cancelAction)
            }
            if let quote {
                Text(quote).font(.callout).textSelection(.enabled)
            }
            if let issue {
                Text(issue).foregroundStyle(.red)
            } else if index.isPDF {
                pdf
            } else {
                textSections
            }
        }
        .padding(18)
        .frame(minWidth: 610, minHeight: 500)
        .onAppear {
            do {
                try index.validateSource()
                if index.isPDF {
                    reader.open(index.source)
                    if reader.document?.isLocked == true && !initialPDFPassword.isEmpty {
                        reader.unlock(initialPDFPassword)
                    }
                    navigate()
                }
            } catch {
                issue = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var pdf: some View {
        if reader.document?.isLocked == true {
            VStack(alignment: .leading, spacing: 10) {
                SecureField("PDF password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(unlock)
                Button("Unlock", action: unlock)
                if let error = reader.error { Text(error).foregroundStyle(.secondary) }
            }
        } else if let error = reader.error {
            Text(error).foregroundStyle(.secondary)
        } else {
            AskPDFCanvas(view: reader.view)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var textSections: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 17) {
                    ForEach(index.sections) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.location.label).font(.headline)
                            Text(section.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .id(section.location)
                    }
                }
                .padding(.vertical, 4)
            }
            .task { scroll.scrollTo(location, anchor: .top) }
        }
    }

    private func unlock() {
        reader.unlock(password)
        if reader.document?.isLocked == false {
            password = ""
            navigate()
        }
    }

    private func navigate() {
        guard case .page(let number) = location, let page = reader.document?.page(at: number - 1) else { return }
        reader.view.go(to: page)
        if let quote, let text = page.string {
            let range = (text as NSString).range(of: quote)
            if range.location != NSNotFound, let selection = page.selection(for: range) {
                selection.color = .systemYellow.withAlphaComponent(0.35)
                reader.view.highlightedSelections = [selection]
            }
        }
    }
}

private struct AskPDFCanvas: NSViewRepresentable {
    let view: PDFView

    func makeNSView(context: Context) -> PDFView { view }
    func updateNSView(_ view: PDFView, context: Context) {}
}
