import AppKit
import PDFKit
import SwiftUI
import UtilityCore

struct PDFEditingSettings: View {
    let tool: Tool
    let input: URL?
    @Binding var options: ToolOptions
    @Binding var organizerHistory: PDFOrganizerHistory
    @Binding var ready: Bool
    let canEdit: Bool

    @State private var rasterReady = false
    @State private var document: PDFDocument?
    @State private var passwordError = false
    @State private var sourceIssue: String?

    var body: some View {
        Group {
            if reviewedSource != nil, input != nil {
                Button("Refresh Page Preview", systemImage: "arrow.clockwise", action: load)
            }
            if let document {
                if document.isLocked {
                    HStack {
                        SecureField("PDF password", text: password)
                        Button("Unlock") { unlock() }
                    }
                    if passwordError {
                        Text("Could not unlock this PDF. Check the password.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else if !hasPermission(document) {
                    Text("This PDF requires its owner password for this operation.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        SecureField("Owner password", text: password)
                        Button("Unlock editing") { unlock() }
                    }
                    if passwordError {
                        Text("That password did not grant the required permission.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    switch tool {
                    case .splitPDF:
                        if let input {
                            PDFSplitSettings(input: input, pageCount: document.pageCount, options: $options.pdfSplit)
                        }
                    case .organizePDF:
                        PDFOrganizerView(document: document, pages: $options.pdfOrganize.pages, history: $organizerHistory)
                        Toggle("Add page numbers", isOn: Binding(get: { options.pdfOrganize.pageNumbers != nil }, set: { enabled in
                            passwordError = false
                            options.pdfOrganize.pageNumbers = enabled ? PDFPageNumberOptions() : nil
                        }))
                        if let numbers = Binding($options.pdfOrganize.pageNumbers) {
                            if document.allowsCommenting {
                                PDFPageNumberControls(document: document, edits: options.pdfOrganize.pages, options: numbers)
                            } else {
                                Text("This PDF requires its owner password to add page numbers.")
                                    .font(.callout).foregroundStyle(.secondary)
                                HStack {
                                    SecureField("Owner password", text: password)
                                    Button("Unlock page numbering") { unlock() }
                                }
                                if passwordError {
                                    Text("That password did not grant permission to add page numbers.")
                                        .font(.callout).foregroundStyle(.secondary)
                                }
                            }
                        }
                    case .deletePDFPages:
                        PDFDeletionSettings(document: document, range: $options.pdfDelete.range)
                    case .extractPDFPages:
                        PDFExtractSettings(document: document, options: $options.pdfExtract)
                    case .pdfToImages:
                        if let input {
                            PDFToImagesSettings(input: input, document: document, options: $options.pdfToImages, valid: $rasterReady)
                        }
                    default:
                        EmptyView()
                    }
                    if tool != .pdfToImages {
                        Text("Page copies may omit document-level outlines, tags, and form structure.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if document.isEncrypted {
                        Label("Exported copies are not password protected.", systemImage: "lock.open")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if input != nil {
                Text(sourceIssue ?? "Could not open this PDF.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .disabled(!canEdit)
        .task(id: input) { load() }
        .onChange(of: canExport, initial: true) { _, valid in ready = valid }
    }

    private var canExport: Bool {
        guard let input, let document, !document.isLocked,
              hasPermission(document), document.pageCount > 0 else { return false }
        if let reviewedSource, reviewedSource.wrappedValue == nil { return false }
        switch tool {
        case .splitPDF:
            guard let groups = try? PDFPageEditing.splitGroups(pageCount: document.pageCount, options: options.pdfSplit)
            else { return false }
            return (try? PDFPageEditing.splitFilenames(input, groups: groups, pattern: options.pdfSplit.filenamePattern)) != nil
        case .organizePDF:
            guard options.pdfOrganize.pages?.isEmpty != true else { return false }
            guard let numbers = options.pdfOrganize.pageNumbers else { return true }
            let count = options.pdfOrganize.pages?.count ?? document.pageCount
            return document.allowsCommenting && (try? PDFPageNumbers.labels(pageCount: count, options: numbers)) != nil
        case .deletePDFPages:
            guard !options.pdfDelete.range.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let removed = try? PageSelection.indices(options.pdfDelete.range, pageCount: document.pageCount)
            else { return false }
            return !removed.isEmpty && removed.count < document.pageCount
        case .extractPDFPages:
            return (try? PDFPageEditing.extractPages(pageCount: document.pageCount, options: options.pdfExtract)) != nil
        case .pdfToImages:
            return rasterReady
        default:
            return false
        }
    }

    private func hasPermission(_ document: PDFDocument) -> Bool {
        tool == .pdfToImages ? document.allowsCopying : document.allowsDocumentAssembly
    }

    private var password: Binding<String> {
        switch tool {
        case .splitPDF: $options.pdfSplit.password
        case .organizePDF: $options.pdfOrganize.password
        case .extractPDFPages: $options.pdfExtract.password
        case .pdfToImages: $options.pdfToImages.password
        default: $options.pdfDelete.password
        }
    }

    private var reviewedSource: Binding<PDFSourceStamp?>? {
        switch tool {
        case .splitPDF: $options.pdfSplit.reviewedSource
        case .organizePDF: $options.pdfOrganize.reviewedSource
        case .deletePDFPages: $options.pdfDelete.reviewedSource
        case .extractPDFPages: $options.pdfExtract.reviewedSource
        case .pdfToImages: $options.pdfToImages.reviewedSource
        default: nil
        }
    }

    private func load() {
        passwordError = false
        sourceIssue = nil
        if let reviewedSource {
            let previous = reviewedSource.wrappedValue
            document = nil
            reviewedSource.wrappedValue = nil
            guard let input else { return }
            do {
                let source = try PDFSourceStamp.read(input)
                guard let opened = PDFDocument(url: source.resolved) else {
                    throw ToolError.invalid("Could not open this PDF.")
                }
                guard (try? PDFSourceStamp.read(input)) == source else {
                    throw ToolError.invalid("The source PDF changed while opening. Refresh the page preview.")
                }
                if let previous, previous != source { clearPageEdits() }
                document = opened
                reviewedSource.wrappedValue = source
            } catch {
                if previous != nil { clearPageEdits() }
                sourceIssue = error.localizedDescription
            }
        } else {
            document = input.flatMap { PDFDocument(url: $0) }
        }
        if let document, document.isEncrypted, !password.wrappedValue.isEmpty,
           document.isLocked || !hasPermission(document) { unlock() }
    }

    private func unlock() {
        guard let input else { return }
        let source = reviewedSource?.wrappedValue
        guard let unlocked = PDFDocument(url: source?.resolved ?? input),
              unlocked.unlock(withPassword: password.wrappedValue) else {
            passwordError = true
            return
        }
        if let source, (try? PDFSourceStamp.read(input)) != source {
            reviewedSource?.wrappedValue = nil
            clearPageEdits()
            document = nil
            sourceIssue = "The source PDF changed while unlocking. Refresh the page preview."
            return
        }
        passwordError = !hasPermission(unlocked)
            || (tool == .organizePDF && options.pdfOrganize.pageNumbers != nil && !unlocked.allowsCommenting)
        document = unlocked
    }

    private func clearPageEdits() {
        if tool == .organizePDF {
            options.pdfOrganize.pages = nil
            options.pdfOrganize.pageNumbers = nil
            organizerHistory = PDFOrganizerHistory()
        } else if tool == .deletePDFPages {
            options.pdfDelete.range = ""
        }
    }
}

private struct PDFSplitSettings: View {
    let input: URL
    let pageCount: Int
    @Binding var options: PDFSplitOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingRow("Split by") {
                Picker("Split by", selection: $options.mode) {
                    Text("Each page").tag(PDFSplitMode.eachPage)
                    Text("Every N pages").tag(PDFSplitMode.everyN)
                    Text("Custom ranges").tag(PDFSplitMode.custom)
                }
                .labelsHidden()
            }
            if options.mode == .everyN {
                SettingRow("Pages per file") {
                    TextField("Pages per file", value: $options.pagesPerFile, format: .number.grouping(.never))
                        .labelsHidden()
                }
            }
            if options.mode == .custom {
                VStack(alignment: .leading, spacing: 6) {
                    Text("One group per line. For example, Introduction: 1–3")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $options.customRanges)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 65)
                        .padding(4)
                        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary) }
                        .accessibilityLabel("Custom page ranges")
                }
            }
            SettingRow("Filename pattern") {
                TextField("Filename pattern", text: $options.filenamePattern)
                    .labelsHidden()
                    .help("Use {name}, {number}, or {group}")
            }
            groupPreview
        }
    }

    @ViewBuilder
    private var groupPreview: some View {
        switch preview {
        case .success(let groups):
            let repeated = PDFPageEditing.splitRepeatedPages(in: groups.map(\.group))
            DisclosureGroup("\(groups.count) files to export") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(groups, id: \.group.number) { item in
                            let pages = item.group.pageNumbers
                            let overlap = pages.filter(repeated.contains)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(item.filename).lineLimit(1).help(item.filename)
                                    Spacer()
                                    Text(pages.count == 1 ? "1 page" : "\(pages.count) pages")
                                        .foregroundStyle(.secondary)
                                }
                                Text("Pages " + pageDescription(pages))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                if !overlap.isEmpty {
                                    Text("Also in other files: " + pageDescription(overlap))
                                        .font(.caption).foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            .font(.callout)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 180)
            }
            if !repeated.isEmpty {
                DisclosureGroup("Pages repeated across files · \(repeated.count)") {
                    ScrollView {
                        Text(pageDescription(repeated.sorted()))
                            .font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 100)
                }
            }
        case .failure(let error):
            Text(error.localizedDescription).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var preview: Result<[(group: PDFSplitGroup, filename: String)], Error> {
        Result {
            let groups = try PDFPageEditing.splitGroups(pageCount: pageCount, options: options)
            let names = try PDFPageEditing.splitFilenames(input, groups: groups, pattern: options.filenamePattern)
            return Array(zip(groups, names))
        }
    }

    private func pageDescription(_ pages: [Int]) -> String {
        PageSelection.expression(for: pages.map { $0 - 1 })
    }
}

private struct PDFDeletionSettings: View {
    enum Filter: String, CaseIterable {
        case all = "All pages"
        case removal = "Marked"
        case kept = "Remaining"
    }

    let document: PDFDocument
    @Binding var range: String
    @State private var filter = Filter.all
    @State private var anchor: Int?

    var body: some View {
        let count = document.pageCount
        let marked = markedPages
        let pages = (0..<count).filter { index in
            switch filter {
            case .all: true
            case .removal: marked.contains(index)
            case .kept: !marked.contains(index)
            }
        }
        VStack(alignment: .leading, spacing: 10) {
            SettingRow("Remove pages") {
                HStack(spacing: 8) {
                    TextField("Pages to remove, e.g. 2, 4–6", text: Binding(get: { range }, set: {
                        range = $0
                        anchor = nil
                    }))
                    .labelsHidden()
                    Button("Clear", systemImage: "xmark.circle") {
                        range = ""
                        anchor = nil
                    }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("Clear pages marked for removal")
                        .disabled(range.isEmpty)
                }
            }
            if !range.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               (try? PageSelection.indices(range, pageCount: count)) == nil {
                Text("Enter valid page numbers from 1 to \(count).")
                    .font(.callout).foregroundStyle(.secondary)
            } else if marked.count == count, count > 0 {
                Text("Keep at least one page to export the PDF.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("\(marked.count) marked to remove · \(count - marked.count) remaining")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Picker("Visible pages", selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)
            if pages.isEmpty {
                Text("No pages in this view.").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(pages, id: \.self) { index in
                            Button {
                                let start = NSEvent.modifierFlags.contains(.shift) ? anchor : nil
                                let changed = PageSelection.updating(marked.sorted(), at: index, extendingFrom: start)
                                anchor = index
                                range = changed.isEmpty ? "" : PageSelection.expression(for: changed.sorted())
                            } label: {
                                VStack(spacing: 6) {
                                    PDFPageThumbnail(page: document.page(at: index), isDimmed: marked.contains(index))
                                    Label("Page \(index + 1)", systemImage: marked.contains(index) ? "minus.circle.fill" : "circle")
                                        .font(.caption)
                                }
                            }
                            .buttonStyle(PDFPageCardStyle(selected: marked.contains(index)))
                            .help("Shift-click to mark this page and the pages between it and the previous selection.")
                            .accessibilityAddTraits(marked.contains(index) ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .onChange(of: ObjectIdentifier(document)) { anchor = nil }
    }

    private var markedPages: Set<Int> {
        guard !range.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return Set((try? PageSelection.indices(range, pageCount: document.pageCount)) ?? [])
    }
}
