import Foundation

enum PDFFormExport {
    struct Field: Encodable, Sendable {
        let name: String
        let text: String?
        let checked: Bool?
    }

    static func write(_ document: Data, alternate: Data?, expected: [Field], pageCount: Int,
                      mode: PDFFormMode, python: URL) async throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }

        let input = directory.appendingPathComponent("input.pdf")
        let output = directory.appendingPathComponent("output.pdf")
        let fields = directory.appendingPathComponent("fields.json")
        let helper = directory.appendingPathComponent("forms.py")
        let alternateInput = directory.appendingPathComponent("alternate.pdf")
        try document.write(to: input)
        try alternate?.write(to: alternateInput)
        try JSONEncoder().encode(expected).write(to: fields)
        try Data(script.utf8).write(to: helper)
        try await ExternalTool.run(python, name: "Python with pypdf",
                                   arguments: ["-I", helper.path, input.path, output.path, fields.path,
                                               alternate == nil ? "" : alternateInput.path,
                                               String(pageCount), mode == .flattened ? "flatten" : "editable"],
                                   directory: directory)
        return try Data(contentsOf: output)
    }

    // Uses pypdf's public PDF reader/writer and validates the canonical form tree as
    // well as page widgets. A PDFKit-only write can yield an orphan widget or a
    // stale AcroForm after flattening.
    private static let script = #"""
    import json
    import sys

    try:
        from pypdf import PdfReader, PdfWriter
        from pypdf.generic import ArrayObject, DictionaryObject, IndirectObject, NameObject, StreamObject
    except ImportError:
        sys.exit("Install pypdf in the selected Python environment to export PDF forms.")

    source, destination, expectations, alternate, page_count, mode = sys.argv[1:]
    with open(expectations, encoding="utf-8") as f:
        expected = json.load(f)

    def name(value):
        return NameObject(value)

    def object_key(ref):
        if isinstance(ref, IndirectObject):
            return (ref.idnum, ref.generation)
        return (-1, id(ref))

    def widgets(document):
        for page in document.pages:
            for ref in page.get("/Annots", []) or []:
                obj = ref.get_object()
                if obj.get("/Subtype") == "/Widget":
                    yield ref, obj

    def ancestry(widget):
        seen = set()
        while widget is not None:
            marker = id(widget)
            if marker in seen:
                raise ValueError("The PDF form field hierarchy contains a cycle.")
            seen.add(marker)
            yield widget
            ref = widget.get("/Parent")
            widget = ref.get_object() if ref is not None else None

    def widget_name(widget):
        return ".".join(reversed([str(field["/T"]) for field in ancestry(widget) if "/T" in field]))

    def value(widget):
        for field in ancestry(widget):
            if "/V" in field:
                return str(field["/V"])
        return ""

    def field_members(root):
        form = root.get("/AcroForm")
        if form is None:
            return set(), set()
        pending = list(form.get_object().get("/Fields", []) or [])
        seen = set()
        names = set()
        while pending:
            ref = pending.pop()
            marker = object_key(ref)
            if marker in seen:
                raise ValueError("The PDF form field tree contains an ambiguous repeated reference.")
            seen.add(marker)
            obj = ref.get_object()
            if "/T" in obj:
                names.add(widget_name(obj))
            pending.extend(obj.get("/Kids", []) or [])
        return seen, names

    def canonicalize(writer):
        root = writer.root_object
        membership, names = field_members(root)
        missing = []
        for ref, widget in widgets(writer):
            if object_key(ref) in membership:
                continue
            key = widget_name(widget)
            if not key or key in names or "/Parent" in widget or "/FT" not in widget:
                raise ValueError("The PDF has orphan widgets with ambiguous field ownership.")
            missing.append(ref)
            names.add(key)
        if not missing:
            return
        if "/AcroForm" not in root:
            root[name("/AcroForm")] = DictionaryObject()
        form = root["/AcroForm"]
        if "/Fields" not in form:
            form[name("/Fields")] = ArrayObject()
        form["/Fields"].extend(missing)

    def normal_appearance(widget):
        ap = widget.get("/AP")
        normal = ap.get_object().get("/N") if ap is not None else None
        return normal.get_object() if normal is not None else None

    def repair_checkboxes(writer):
        if not alternate:
            return
        specs = {spec["name"]: spec for spec in expected if "checked" in spec}
        flipped = {widget_name(widget): widget for _, widget in widgets(PdfReader(alternate))}
        for _, widget in widgets(writer):
            key = widget_name(widget)
            if key not in specs:
                continue
            is_on = specs[key]["checked"]
            other = flipped.get(key)
            normal = normal_appearance(widget)
            # Some PDFKit documents serialize a button as a single appearance
            # stream with a string /V. Restore a normal state dictionary.
            if isinstance(normal, StreamObject):
                if other is None:
                    raise ValueError("Could not find both checkbox appearances for " + repr(key) + ".")
                other_normal = normal_appearance(other)
                on_widget = widget if is_on else other
                on = name("/" + value(on_widget).lstrip("/"))
                off = name("/Off")
                desired, opposite = (on, off) if is_on else (off, on)
                if on == off or on == "/":
                    raise ValueError("Could not identify the selected checkbox state for " + repr(key) + ".")
                if isinstance(other_normal, DictionaryObject) and not isinstance(other_normal, StreamObject):
                    other_normal = other_normal.get(opposite)
                    other_normal = other_normal.get_object() if other_normal is not None else None
                if not isinstance(other_normal, StreamObject):
                    raise ValueError("Could not recover the alternate checkbox appearance for " + repr(key) + ".")
                copied = other_normal.clone(writer)
                widget["/AP"][name("/N")] = DictionaryObject({
                    desired: normal.indirect_reference,
                    opposite: copied.indirect_reference,
                })
                widget[name("/AS")] = desired
                widget[name("/V")] = desired

    def verify(reader):
        if len(reader.pages) != int(page_count):
            raise ValueError("The resulting PDF page count did not match the source.")
        root = reader.trailer["/Root"]
        page_widgets = list(widgets(reader))
        if mode == "flatten":
            if page_widgets or "/AcroForm" in root:
                raise ValueError("The flattened PDF still contains form fields.")
            return
        membership, _ = field_members(root)
        if any(object_key(ref) not in membership for ref, _ in page_widgets):
            raise ValueError("The resulting PDF contains a widget outside the canonical form tree.")
        fields = reader.get_fields() or {}
        by_name = {}
        for _, widget in page_widgets:
            by_name.setdefault(widget_name(widget), []).append(widget)
        for spec in expected:
            key = spec["name"]
            if key not in fields or len(by_name.get(key, [])) != 1:
                raise ValueError("Could not verify the field named " + repr(key) + ".")
            field, widget = fields[key], by_name[key][0]
            displayed = value(widget)
            if str(field.get("/V", "")) != displayed:
                raise ValueError("Field and widget data do not match for " + repr(key) + ".")
            normal = normal_appearance(widget)
            if "text" in spec:
                ok = displayed == spec["text"]
            else:
                state = str(widget.get("/AS", "/Off"))
                ok = (state != "/Off") == spec["checked"] and (displayed not in ("", "/Off")) == spec["checked"]
                if isinstance(normal, DictionaryObject) and not isinstance(normal, StreamObject):
                    selected = normal.get(state)
                    normal = selected.get_object() if selected is not None else None
            if not ok or not isinstance(normal, StreamObject) or not normal.get_data():
                raise ValueError("Could not verify the value and appearance of " + repr(key) + ".")

    try:
        writer = PdfWriter(clone_from=PdfReader(source))
        if mode == "flatten":
            writer.root_object.pop(name("/AcroForm"), None)
        else:
            canonicalize(writer)
            repair_checkboxes(writer)
        writer.write(destination)
        verify(PdfReader(destination))
    except Exception as error:
        sys.exit(str(error))
    """#
}
