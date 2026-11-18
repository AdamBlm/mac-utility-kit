import CoreGraphics
import PDFKit

public struct PDFRedactionGeometry {
    public let displaySize: CGSize
    let physicalSize: CGSize
    let pageToDisplay: CGAffineTransform

    public init(_ page: PDFPage) throws {
        guard let reference = page.pageRef else { throw ToolError.invalid("Could not read this PDF page.") }
        let crop = reference.getBoxRect(.cropBox).intersection(reference.getBoxRect(.mediaBox))
        let quarterTurn = abs(reference.rotationAngle % 180) == 90
        let size = quarterTurn ? CGSize(width: crop.height, height: crop.width) : crop.size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw ToolError.invalid("This page has invalid display dimensions.")
        }
        var unit: CGPDFReal = 1
        if let dictionary = reference.dictionary {
            _ = CGPDFDictionaryGetNumber(dictionary, "UserUnit", &unit)
        }
        let physical = CGSize(width: size.width * unit, height: size.height * unit)
        guard unit.isFinite, unit > 0, physical.width.isFinite, physical.height.isFinite,
              physical.width > 0, physical.height > 0 else {
            throw ToolError.invalid("This page has invalid physical dimensions.")
        }
        displaySize = size
        physicalSize = physical
        pageToDisplay = reference.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size),
                                                      rotate: 0, preserveAspectRatio: true)
    }

    /// Normalized visible coordinates measured from the upper-left of the displayed page.
    public func normalized(_ pageRect: CGRect, padding: CGFloat = 0) -> CGRect? {
        guard Self.isRect(pageRect) else { return nil }
        let area = pageRect.insetBy(dx: -padding, dy: -padding).applying(pageToDisplay)
        let visible = CGRect(x: area.minX / displaySize.width, y: 1 - area.maxY / displaySize.height,
                             width: area.width / displaySize.width, height: area.height / displaySize.height)
            .intersection(Self.unit)
        return Self.isRect(visible) ? visible : nil
    }

    public func pageRect(_ normalized: CGRect) -> CGRect? {
        guard Self.isRect(normalized), Self.unit.contains(normalized) else { return nil }
        let display = CGRect(x: normalized.minX * displaySize.width, y: (1 - normalized.maxY) * displaySize.height,
                             width: normalized.width * displaySize.width, height: normalized.height * displaySize.height)
        return display.applying(pageToDisplay.inverted())
    }

    static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

    static func isRect(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }
}
