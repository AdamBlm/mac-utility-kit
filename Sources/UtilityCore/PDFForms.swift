import AppKit
import PDFKit
import Vision

public enum PDFFormMode: String, CaseIterable, Identifiable, Sendable {
    case editable = "Editable PDF"
    case flattened = "Flattened PDF"
    public var id: Self { self }
}

@MainActor
public final class PDFForms {
    public enum Kind: String, CaseIterable, Identifiable, Sendable {
        case text = "Text Field"
        case checkbox = "Checkbox"
        case freeText = "Free Text"
        case unsupported = "Unsupported Widget"

        public var id: Self { self }
        public static let addable: [Self] = [.text, .checkbox, .freeText]
    }

    public struct Field: Identifiable {
        public let id: UUID
        public let kind: Kind
        public let name: String
        public let value: String
        public let checked: Bool
        public let bounds: CGRect
        public let isReadOnly: Bool
    }

    public struct Candidate: Identifiable, Sendable {
        public let id = UUID()
        public let bounds: CGRect
        public let kind: Kind
    }

    public let document: PDFDocument
    public let source: URL
    private var fieldsByID: [UUID: PDFAnnotation] = [:]
    private var idsByField: [ObjectIdentifier: UUID] = [:]

    public init(source: URL) throws {
        guard source.isFileURL, let document = PDFDocument(url: source), document.pageCount > 0 else {
            throw ToolError.invalid("Could not open this PDF.")
        }
        guard !document.isEncrypted, document.allowsFormFieldEntry else {
            throw ToolError.invalid("Remove password protection before editing or exporting this form.")
        }
        if let catalog = CGPDFDocument(source as CFURL)?.catalog {
            var acroForm: CGPDFDictionaryRef?
            var xfa: CGPDFObjectRef?
            if CGPDFDictionaryGetDictionary(catalog, "AcroForm", &acroForm), let acroForm,
               CGPDFDictionaryGetObject(acroForm, "XFA", &xfa) {
                throw ToolError.invalid("Dynamic XFA PDF forms are unsupported.")
            }
        }
        for index in 0..<document.pageCount where document.page(at: index)?.annotations.contains(where: {
            $0.widgetFieldType == .signature
        }) == true {
            throw ToolError.invalid("This PDF contains a signature field. Exporting a rewritten copy could invalidate its signature.")
        }
        self.source = source
        self.document = document
    }

    public func fields(on pageIndex: Int) -> [Field] {
        guard let page = document.page(at: pageIndex) else { return [] }
        let nameCounts = Dictionary(grouping: widgets(), by: { $0.fieldName ?? "" }).mapValues(\.count)
        return page.annotations.filter { $0.type == "Widget" || $0.type == "FreeText" }.map { annotation in
            let identity = ObjectIdentifier(annotation)
            let id = idsByField[identity] ?? UUID()
            idsByField[identity] = id
            fieldsByID[id] = annotation
            let kind = fieldKind(annotation)
            let name = (kind == .freeText ? annotation.userName : annotation.fieldName) ?? ""
            let grouped = kind != .freeText && (nameCounts[name] ?? 0) > 1
            return Field(id: id, kind: kind, name: name,
                         value: (kind == .freeText ? annotation.contents : annotation.widgetStringValue) ?? "",
                         checked: annotation.buttonWidgetState == .onState, bounds: annotation.bounds,
                         isReadOnly: (kind == .unsupported || annotation.isReadOnly || grouped))
        }
    }

    public func add(_ kind: Kind, on pageIndex: Int, bounds: CGRect, name: String) throws -> UUID {
        guard Kind.addable.contains(kind), let page = document.page(at: pageIndex) else {
            throw ToolError.invalid("Select a page and a supported field type.")
        }
        let label = try validatedName(name, kind: kind)
        try validate(bounds, in: page)
        let annotation = PDFAnnotation(bounds: bounds, forType: kind == .freeText ? .freeText : .widget, withProperties: nil)
        let fontSize = min(14, bounds.height * 0.6)
        annotation.font = NSFont.systemFont(ofSize: fontSize)
        annotation.fontColor = .black
        annotation.shouldPrint = true
        switch kind {
        case .text:
            annotation.widgetFieldType = .text
            annotation.fieldName = label
            annotation.widgetStringValue = ""
            annotation.backgroundColor = .white
        case .checkbox:
            annotation.widgetFieldType = .button
            annotation.widgetControlType = .checkBoxControl
            annotation.fieldName = label
            annotation.buttonWidgetState = .offState
            annotation.backgroundColor = .white
        case .freeText:
            annotation.userName = label
            annotation.color = .clear
            annotation.contents = ""
        case .unsupported: break
        }
        page.addAnnotation(annotation)
        let id = UUID()
        fieldsByID[id] = annotation
        idsByField[ObjectIdentifier(annotation)] = id
        return id
    }

    public func update(_ id: UUID, name: String, value: String, checked: Bool, bounds: CGRect) throws {
        guard let annotation = fieldsByID[id], let page = annotation.page,
              let field = fields(on: document.index(for: page)).first(where: { $0.id == id }), !field.isReadOnly else {
            throw ToolError.invalid("This widget cannot be edited.")
        }
        let label = try validatedName(name, kind: field.kind, excluding: annotation)
        try validate(bounds, in: page)
        guard value.utf8.count <= 4_096 else { throw ToolError.invalid("Enter up to 4,096 bytes in a field.") }
        if field.kind == .text, annotation.maximumLength > 0,
           annotation.maximumLength < Int.max, value.count > annotation.maximumLength {
            throw ToolError.invalid("This field accepts up to \(annotation.maximumLength) characters.")
        }
        annotation.bounds = bounds
        switch field.kind {
        case .text:
            annotation.fieldName = label
            annotation.widgetStringValue = value
        case .checkbox:
            annotation.fieldName = label
            annotation.buttonWidgetState = checked ? .onState : .offState
        case .freeText:
            annotation.userName = label
            annotation.contents = value
        case .unsupported: break
        }
    }

    public func remove(_ id: UUID) throws {
        guard let annotation = fieldsByID[id], let page = annotation.page,
              let field = fields(on: document.index(for: page)).first(where: { $0.id == id }), !field.isReadOnly else {
            throw ToolError.invalid("This widget cannot be removed.")
        }
        page.removeAnnotation(annotation)
        fieldsByID.removeValue(forKey: id)
        idsByField.removeValue(forKey: ObjectIdentifier(annotation))
    }

    public func candidates(on pageIndex: Int) throws -> [Candidate] {
        guard let page = document.page(at: pageIndex), page.rotation == 0 else {
            throw ToolError.invalid("Candidate detection supports unrotated pages. Fields can still be placed manually.")
        }
        let bounds = page.bounds(for: .cropBox)
        let size = CGSize(width: bounds.width * min(2, 1_600 / max(bounds.width, bounds.height)),
                          height: bounds.height * min(2, 1_600 / max(bounds.width, bounds.height)))
        let thumbnail = page.thumbnail(of: size, for: .cropBox)
        guard let image = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let request = VNDetectRectanglesRequest()
        request.minimumSize = 0.012
        request.minimumAspectRatio = 0.12
        request.minimumConfidence = 0.55
        request.maximumObservations = 36
        try VNImageRequestHandler(cgImage: image).perform([request])
        let existing = fields(on: pageIndex).map(\.bounds)
        return (request.results ?? []).compactMap { observation in
            let rect = observation.boundingBox
            let fieldBounds = CGRect(x: bounds.minX + rect.minX * bounds.width, y: bounds.minY + rect.minY * bounds.height,
                                     width: rect.width * bounds.width, height: rect.height * bounds.height)
            guard fieldBounds.width >= 8, fieldBounds.height >= 8, fieldBounds.height <= 44,
                  fieldBounds.width <= bounds.width * 0.82, !existing.contains(where: { $0.intersects(fieldBounds) }) else { return nil }
            let aspect = fieldBounds.width / fieldBounds.height
            return Candidate(bounds: fieldBounds, kind: (0.75...1.35).contains(aspect) ? .checkbox : .text)
        }.sorted { $0.bounds.midY > $1.bounds.midY }
    }

    public func export(_ mode: PDFFormMode, python: URL) async throws -> Data {
        let pageCount = document.pageCount
        let expected = (0..<pageCount).flatMap { fields(on: $0) }.compactMap { field -> PDFFormExport.Field? in
            guard field.kind == .text || field.kind == .checkbox, !field.isReadOnly else { return nil }
            return PDFFormExport.Field(name: field.name, text: field.kind == .text ? field.value : nil,
                                       checked: field.kind == .checkbox ? field.checked : nil)
        }
        let options: [AnyHashable: Any] = [PDFDocumentWriteOption.burnInAnnotationsOption: mode == .flattened]
        guard let data = document.dataRepresentation(options: options) else {
            throw ToolError.invalid("Could not write this PDF.")
        }
        let checkboxNames = Set(expected.filter { $0.checked != nil }.map(\.name))
        let alternate = mode == .editable ? try alternateCheckboxAppearances(named: checkboxNames) : nil
        return try await PDFFormExport.write(data, alternate: alternate, expected: expected,
                                             pageCount: pageCount, mode: mode, python: python)
    }

    private func alternateCheckboxAppearances(named checkboxNames: Set<String>) throws -> Data? {
        let available = widgets().filter { annotation in
            guard let name = annotation.fieldName, checkboxNames.contains(name), fieldKind(annotation) == .checkbox else {
                return false
            }
            return true
        }
        guard !available.isEmpty else { return nil }
        let states = available.map { ($0, $0.buttonWidgetState) }
        for (widget, state) in states { widget.buttonWidgetState = state == .onState ? .offState : .onState }
        defer { for (widget, state) in states { widget.buttonWidgetState = state } }
        guard let data = document.dataRepresentation() else {
            throw ToolError.invalid("Could not generate the checkbox appearances.")
        }
        return data
    }

    private func widgets() -> [PDFAnnotation] {
        (0..<document.pageCount).flatMap { page in
            document.page(at: page)?.annotations.filter { $0.type == "Widget" } ?? []
        }
    }

    private func fieldKind(_ annotation: PDFAnnotation) -> Kind {
        if annotation.type == "FreeText" { return .freeText }
        if annotation.widgetFieldType == .text { return .text }
        if annotation.widgetFieldType == .button, annotation.widgetControlType == .checkBoxControl { return .checkbox }
        return .unsupported
    }

    private func validatedName(_ name: String, kind: Kind, excluding annotation: PDFAnnotation? = nil) throws -> String {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.utf8.count <= 200, !label.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw ToolError.invalid("Enter a field label of 1 to 200 bytes.")
        }
        if kind != .freeText {
            guard !widgets().contains(where: { $0 !== annotation && $0.fieldName == label }) else {
                throw ToolError.invalid("A widget with this field name already exists.")
            }
        }
        return label
    }

    private func validate(_ bounds: CGRect, in page: PDFPage) throws {
        guard [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy(\.isFinite),
              bounds.width >= 6, bounds.height >= 6, page.bounds(for: .cropBox).contains(bounds) else {
            throw ToolError.invalid("Place the entire field inside the page and make it at least 6 points wide and tall.")
        }
    }
}
