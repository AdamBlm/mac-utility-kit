import CoreGraphics

/// Measures the unit square of each named page image in PDF points. Repeated uses
/// keep the largest placement so a thumbnail can't lower the quality of a larger use.
final class PDFImagePlacements {
    private(set) var sizes: [String: CGSize] = [:]
    private var transform = CGAffineTransform.identity
    private var stack: [CGAffineTransform] = []
    private var valid = true

    static func measure(_ page: CGPDFPage) -> [String: CGSize] {
        var unit: CGPDFReal = 1
        if let dictionary = page.dictionary,
           CGPDFDictionaryGetNumber(dictionary, "UserUnit", &unit), unit != 1 { return [:] }
        let stream = CGPDFContentStreamCreateWithPage(page)
        guard let operators = CGPDFOperatorTableCreate() else { return [:] }
        defer {
            CGPDFContentStreamRelease(stream)
            CGPDFOperatorTableRelease(operators)
        }
        let state = PDFImagePlacements()
        CGPDFOperatorTableSetCallback(operators, "q") { _, context in
            guard let context else { return }
            let state = Unmanaged<PDFImagePlacements>.fromOpaque(context).takeUnretainedValue()
            state.stack.append(state.transform)
        }
        CGPDFOperatorTableSetCallback(operators, "Q") { _, context in
            guard let context else { return }
            let state = Unmanaged<PDFImagePlacements>.fromOpaque(context).takeUnretainedValue()
            if let last = state.stack.popLast() { state.transform = last }
            else { state.valid = false }
        }
        CGPDFOperatorTableSetCallback(operators, "cm") { scanner, context in
            guard let context else { return }
            let state = Unmanaged<PDFImagePlacements>.fromOpaque(context).takeUnretainedValue()
            var values = [CGPDFReal](repeating: 0, count: 6)
            for offset in values.indices.reversed() {
                guard CGPDFScannerPopNumber(scanner, &values[offset]), values[offset].isFinite else {
                    state.valid = false
                    return
                }
            }
            state.transform = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3],
                                                tx: values[4], ty: values[5]).concatenating(state.transform)
        }
        CGPDFOperatorTableSetCallback(operators, "Do") { scanner, context in
            guard let context else { return }
            let state = Unmanaged<PDFImagePlacements>.fromOpaque(context).takeUnretainedValue()
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name else {
                state.valid = false
                return
            }
            let key = "/" + String(cString: name)
            let width = hypot(state.transform.a, state.transform.b)
            let height = hypot(state.transform.c, state.transform.d)
            guard width.isFinite, height.isFinite else {
                state.valid = false
                return
            }
            let current = state.sizes[key] ?? .zero
            state.sizes[key] = CGSize(width: max(current.width, width), height: max(current.height, height))
        }
        let scanner = CGPDFScannerCreate(stream, operators, Unmanaged.passUnretained(state).toOpaque())
        defer { CGPDFScannerRelease(scanner) }
        guard CGPDFScannerScan(scanner), state.valid else { return [:] }
        return state.sizes
    }

    static func image(named name: String, on page: CGPDFPage) -> CGPDFStreamRef? {
        let stream = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(stream) }
        return String(name.dropFirst()).withCString {
            guard let reference = CGPDFContentStreamGetResource(stream, "XObject", $0) else { return nil }
            var image: CGPDFStreamRef?
            return CGPDFObjectGetValue(reference, .stream, &image) ? image : nil
        }
    }
}
